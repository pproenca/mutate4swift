import Foundation

public struct MutationWorkQueueMetrics: Sendable, Codable {
    public let dispatchedWorkloads: Int
    public let stolenWorkloads: Int
    public let remainingWorkloads: Int
    public let remainingWeight: Int

    public init(
        dispatchedWorkloads: Int,
        stolenWorkloads: Int,
        remainingWorkloads: Int,
        remainingWeight: Int
    ) {
        self.dispatchedWorkloads = dispatchedWorkloads
        self.stolenWorkloads = stolenWorkloads
        self.remainingWorkloads = remainingWorkloads
        self.remainingWeight = remainingWeight
    }
}

/// Dynamic work queue for repository mutation execution.
///
/// Strategy:
/// 1. Seed each worker with planner buckets (LPT + scope affinity).
/// 2. Always let workers drain their own queue first.
/// 3. When idle, steal from the heaviest remaining worker queue.
/// 4. Prefer steals that preserve baseline locality (warm scopes).
public actor MutationWorkQueue {
    private struct WorkerQueueState {
        var workloads: [MutationWorkload]
        var remainingWeight: Int
        var scopeCounts: [String: Int]
    }

    private var workers: [Int: WorkerQueueState]
    private let scopeOwnerByScope: [String: Int]

    private var dispatchedWorkloads = 0
    private var stolenWorkloads = 0
    private var remainingWorkloads = 0
    private var remainingWeight = 0

    public init(plan: MutationStrategyPlan) {
        let workerCount = max(1, plan.jobsPlanned)
        var states: [Int: WorkerQueueState] = [:]
        states.reserveCapacity(workerCount)
        for workerIndex in 0..<workerCount {
            states[workerIndex] = WorkerQueueState(
                workloads: [],
                remainingWeight: 0,
                scopeCounts: [:]
            )
        }

        var totalWorkloads = 0
        var totalWeight = 0
        for bucket in plan.buckets {
            let sortedWorkloads = Self.prioritizedCandidates(from: bucket.workloads)
            let bucketWeight = sortedWorkloads.reduce(0) { $0 + $1.candidateMutations }
            let scopeCounts = sortedWorkloads.reduce(into: [String: Int]()) { partial, workload in
                partial[workload.scopeKey, default: 0] += 1
            }

            states[bucket.workerIndex] = WorkerQueueState(
                workloads: sortedWorkloads,
                remainingWeight: bucketWeight,
                scopeCounts: scopeCounts
            )
            totalWorkloads += sortedWorkloads.count
            totalWeight += bucketWeight
        }

        self.workers = states
        self.scopeOwnerByScope = Self.resolveScopeOwners(from: plan.buckets)
        self.remainingWorkloads = totalWorkloads
        self.remainingWeight = totalWeight
    }

    public func next(for workerIndex: Int, warmedScopes: Set<String> = []) -> MutationWorkload? {
        guard remainingWorkloads > 0, workers[workerIndex] != nil else {
            return nil
        }

        if let workload = dequeueOwnWork(workerIndex: workerIndex, warmedScopes: warmedScopes) {
            dispatchedWorkloads += 1
            return workload
        }

        guard let donorIndex = heaviestDonor(excluding: workerIndex),
              let workload = dequeueStolenWork(
                  workerIndex: workerIndex,
                  donorIndex: donorIndex,
                  warmedScopes: warmedScopes
              ) else {
            return nil
        }

        dispatchedWorkloads += 1
        stolenWorkloads += 1
        return workload
    }

    public func metrics() -> MutationWorkQueueMetrics {
        MutationWorkQueueMetrics(
            dispatchedWorkloads: dispatchedWorkloads,
            stolenWorkloads: stolenWorkloads,
            remainingWorkloads: remainingWorkloads,
            remainingWeight: remainingWeight
        )
    }

    private func dequeueOwnWork(workerIndex: Int, warmedScopes: Set<String>) -> MutationWorkload? {
        guard var state = workers[workerIndex], !state.workloads.isEmpty else {
            return nil
        }

        var bestIndex = 0
        var bestTier = ownQueueTier(for: state.workloads[0], workerIndex: workerIndex, warmedScopes: warmedScopes)

        if state.workloads.count > 1 {
            for index in 1..<state.workloads.count {
                let candidate = state.workloads[index]
                let tier = ownQueueTier(for: candidate, workerIndex: workerIndex, warmedScopes: warmedScopes)
                if tier > bestTier
                    || (tier == bestTier && Self.compareWorkloadPriority(candidate, state.workloads[bestIndex])) {
                    bestIndex = index
                    bestTier = tier
                }
            }
        }

        let workload = state.workloads.remove(at: bestIndex)
        state.remainingWeight -= workload.candidateMutations
        decrementScopeCount(for: workload.scopeKey, state: &state)
        workers[workerIndex] = state
        remainingWorkloads -= 1
        remainingWeight -= workload.candidateMutations
        return workload
    }

    private func dequeueStolenWork(
        workerIndex: Int,
        donorIndex: Int,
        warmedScopes: Set<String>
    ) -> MutationWorkload? {
        guard var donorState = workers[donorIndex], !donorState.workloads.isEmpty else {
            return nil
        }

        var bestIndex = 0
        var bestTier = stealTier(
            for: donorState.workloads[0],
            thiefIndex: workerIndex,
            donorIndex: donorIndex,
            donorScopeCounts: donorState.scopeCounts,
            warmedScopes: warmedScopes
        )

        if donorState.workloads.count > 1 {
            for index in 1..<donorState.workloads.count {
                let candidate = donorState.workloads[index]
                let tier = stealTier(
                    for: candidate,
                    thiefIndex: workerIndex,
                    donorIndex: donorIndex,
                    donorScopeCounts: donorState.scopeCounts,
                    warmedScopes: warmedScopes
                )
                if tier > bestTier
                    || (tier == bestTier && Self.compareWorkloadPriority(candidate, donorState.workloads[bestIndex])) {
                    bestIndex = index
                    bestTier = tier
                }
            }
        }

        let workload = donorState.workloads.remove(at: bestIndex)
        donorState.remainingWeight -= workload.candidateMutations
        decrementScopeCount(for: workload.scopeKey, state: &donorState)
        workers[donorIndex] = donorState
        remainingWorkloads -= 1
        remainingWeight -= workload.candidateMutations
        return workload
    }

    private func ownQueueTier(
        for workload: MutationWorkload,
        workerIndex: Int,
        warmedScopes: Set<String>
    ) -> Int {
        let scopeKey = workload.scopeKey
        if warmedScopes.contains(scopeKey) {
            return 3
        }
        if scopeOwnerByScope[scopeKey] == workerIndex {
            return 2
        }
        return 1
    }

    private func stealTier(
        for workload: MutationWorkload,
        thiefIndex: Int,
        donorIndex: Int,
        donorScopeCounts: [String: Int],
        warmedScopes: Set<String>
    ) -> Int {
        let scopeKey = workload.scopeKey
        if warmedScopes.contains(scopeKey) {
            return 5
        }
        if scopeOwnerByScope[scopeKey] == thiefIndex {
            return 4
        }
        if scopeOwnerByScope[scopeKey] != donorIndex {
            return 3
        }
        if donorScopeCounts[scopeKey, default: 0] > 1 {
            return 2
        }
        return 1
    }

    private func heaviestDonor(excluding workerIndex: Int) -> Int? {
        var selected: (workerIndex: Int, weight: Int, count: Int)? = nil

        for (index, state) in workers {
            if index == workerIndex || state.workloads.isEmpty {
                continue
            }

            let candidate: (workerIndex: Int, weight: Int, count: Int) = (
                workerIndex: index,
                weight: state.remainingWeight,
                count: state.workloads.count
            )
            if let current = selected {
                if Self.isHigherPriorityDonor(candidate, than: current) {
                    selected = candidate
                }
            } else {
                selected = candidate
            }
        }

        return selected?.workerIndex
    }

    private func decrementScopeCount(for scopeKey: String, state: inout WorkerQueueState) {
        guard let currentCount = state.scopeCounts[scopeKey] else {
            return
        }

        if currentCount <= 1 {
            state.scopeCounts.removeValue(forKey: scopeKey)
        } else {
            state.scopeCounts[scopeKey] = currentCount - 1
        }
    }

    private static func resolveScopeOwners(
        from buckets: [MutationExecutionBucket]
    ) -> [String: Int] {
        var scopeWorkerWeights: [String: [Int: Int]] = [:]
        for bucket in buckets {
            for workload in bucket.workloads where workload.candidateMutations > 0 {
                scopeWorkerWeights[workload.scopeKey, default: [:]][bucket.workerIndex, default: 0] +=
                    workload.candidateMutations
            }
        }

        var owners: [String: Int] = [:]
        owners.reserveCapacity(scopeWorkerWeights.count)
        for (scopeKey, workers) in scopeWorkerWeights {
            let owner = workers.max { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key > rhs.key
                }
                return lhs.value < rhs.value
            }?.key

            if let owner {
                owners[scopeKey] = owner
            }
        }
        return owners
    }

    private static func prioritizedCandidates(from workloads: [MutationWorkload]) -> [MutationWorkload] {
        workloads
            .filter { $0.candidateMutations > 0 }
            .sorted(by: compareWorkloadPriority)
    }

    private static func isHigherPriorityDonor(
        _ lhs: (workerIndex: Int, weight: Int, count: Int),
        than rhs: (workerIndex: Int, weight: Int, count: Int)
    ) -> Bool {
        if lhs.weight != rhs.weight {
            return lhs.weight > rhs.weight
        }
        if lhs.count != rhs.count {
            return lhs.count > rhs.count
        }
        return lhs.workerIndex < rhs.workerIndex
    }

    private static func compareWorkloadPriority(_ lhs: MutationWorkload, _ rhs: MutationWorkload) -> Bool {
        if lhs.candidateMutations == rhs.candidateMutations {
            return lhs.sourceFile < rhs.sourceFile
        }
        return lhs.candidateMutations > rhs.candidateMutations
    }
}
