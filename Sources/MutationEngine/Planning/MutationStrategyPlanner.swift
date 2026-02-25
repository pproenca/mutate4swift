import Foundation

public struct MutationWorkload: Sendable, Codable {
    public let sourceFile: String
    public let scopeFilter: String?
    public let potentialMutations: Int
    public let candidateMutations: Int

    public init(
        sourceFile: String,
        scopeFilter: String?,
        potentialMutations: Int,
        candidateMutations: Int
    ) {
        self.sourceFile = sourceFile
        self.scopeFilter = scopeFilter
        self.potentialMutations = potentialMutations
        self.candidateMutations = candidateMutations
    }

    public var scopeKey: String {
        scopeFilter ?? "__all_tests__"
    }

    public var isUncovered: Bool {
        potentialMutations > 0 && candidateMutations == 0
    }
}

public struct MutationExecutionBucket: Sendable, Codable {
    public let workerIndex: Int
    public let workloads: [MutationWorkload]
    public let totalWeight: Int

    public init(workerIndex: Int, workloads: [MutationWorkload], totalWeight: Int) {
        self.workerIndex = workerIndex
        self.workloads = workloads
        self.totalWeight = totalWeight
    }
}

public struct MutationStrategyPlan: Sendable, Codable {
    public let jobsRequested: Int
    public let jobsPlanned: Int
    public let workloads: [MutationWorkload]
    public let buckets: [MutationExecutionBucket]
    public let scopeWeights: [String: Int]

    public init(
        jobsRequested: Int,
        jobsPlanned: Int,
        workloads: [MutationWorkload],
        buckets: [MutationExecutionBucket],
        scopeWeights: [String: Int]
    ) {
        self.jobsRequested = jobsRequested
        self.jobsPlanned = jobsPlanned
        self.workloads = workloads
        self.buckets = buckets
        self.scopeWeights = scopeWeights
    }

    public var analyzedFiles: Int {
        workloads.count
    }

    public var filesWithCandidateMutations: Int {
        workloads.filter { $0.candidateMutations > 0 }.count
    }

    public var uncoveredFiles: [String] {
        workloads
            .filter(\.isUncovered)
            .map(\.sourceFile)
            .sorted()
    }

    public var totalPotentialMutations: Int {
        workloads.reduce(0) { $0 + $1.potentialMutations }
    }

    public var totalCandidateMutations: Int {
        workloads.reduce(0) { $0 + $1.candidateMutations }
    }

    public var serialWeight: Int {
        totalCandidateMutations
    }

    public var maxBucketWeight: Int {
        buckets.map(\.totalWeight).max() ?? 0
    }

    public var maxSingleWorkloadWeight: Int {
        workloads.map(\.candidateMutations).max() ?? 0
    }

    public var theoreticalLowerBound: Int {
        guard jobsPlanned > 0 else { return 0 }
        let averageBound = Int(ceil(Double(serialWeight) / Double(jobsPlanned)))
        return max(maxSingleWorkloadWeight, averageBound)
    }

    public var estimatedSpeedupUpperBound: Double {
        guard maxBucketWeight > 0 else { return 1.0 }
        return Double(serialWeight) / Double(maxBucketWeight)
    }
}

public struct MutationStrategyPlanner: Sendable {
    private let coverageProvider: CoverageProvider?
    private let testFileMapper: TestFileMapper

    public init(
        coverageProvider: CoverageProvider? = nil,
        testFileMapper: TestFileMapper = TestFileMapper()
    ) {
        self.coverageProvider = coverageProvider
        self.testFileMapper = testFileMapper
    }

    public func buildPlan(
        sourceFiles: [String],
        packagePath: String,
        testFilterOverride: String? = nil,
        jobs: Int
    ) async throws -> MutationStrategyPlan {
        precondition(jobs > 0, "jobs must be >= 1")

        var workloads: [MutationWorkload] = []
        workloads.reserveCapacity(sourceFiles.count)

        for sourceFile in sourceFiles.sorted() {
            let source = try String(contentsOfFile: sourceFile, encoding: .utf8)
            let discoverer = MutationDiscoverer(source: source, fileName: sourceFile)
            var sites = discoverer.discoverSites()
            sites = EquivalentMutationFilter().filter(sites, source: source)
            let potentialMutations = sites.count

            if let coverageProvider {
                // Conservative fallback: if coverage cannot be loaded, do not drop mutations.
                if let covered = try? coverageProvider.coveredLines(
                    forFile: sourceFile,
                    packagePath: packagePath
                ) {
                    sites = sites.filter { covered.contains($0.line) }
                }
            }

            let candidateMutations = sites.count
            let filter = if let testFilterOverride {
                testFilterOverride
            } else {
                await testFileMapper.testFilterAsync(forSourceFile: sourceFile)
            }

            workloads.append(
                MutationWorkload(
                    sourceFile: sourceFile,
                    scopeFilter: filter,
                    potentialMutations: potentialMutations,
                    candidateMutations: candidateMutations
                )
            )
        }

        let scopeWeights = workloads.reduce(into: [String: Int]()) { partial, workload in
            partial[workload.scopeKey, default: 0] += workload.candidateMutations
        }

        let candidateWorkloads = workloads.filter { $0.candidateMutations > 0 }
        guard !candidateWorkloads.isEmpty else {
            return MutationStrategyPlan(
                jobsRequested: jobs,
                jobsPlanned: 1,
                workloads: workloads,
                buckets: [MutationExecutionBucket(workerIndex: 0, workloads: [], totalWeight: 0)],
                scopeWeights: scopeWeights
            )
        }

        let jobsPlanned = min(jobs, candidateWorkloads.count)
        var bucketQueue = MinBucketQueue(
            elements: (0..<jobsPlanned).map {
                MutableBucket(workerIndex: $0, workloads: [], totalWeight: 0, scopeKeys: [])
            }
        )

        let sortedWorkloads = candidateWorkloads.sorted {
            if $0.candidateMutations == $1.candidateMutations {
                return $0.sourceFile < $1.sourceFile
            }
            return $0.candidateMutations > $1.candidateMutations
        }

        let totalCandidateWeight = candidateWorkloads.reduce(0) { $0 + $1.candidateMutations }
        let targetBucketWeight = max(
            1,
            Int(ceil(Double(totalCandidateWeight) / Double(jobsPlanned)))
        )
        var primaryWorkerByScope: [String: Int] = [:]

        // LPT schedule with scope affinity:
        // keep each scope anchored to one worker unless weight skew exceeds a threshold.
        for workload in sortedWorkloads {
            guard let lightestWorkerIndex = bucketQueue.lightestWorkerIndex(),
                  let lightestBucket = bucketQueue.bucket(workerIndex: lightestWorkerIndex) else {
                continue
            }

            let scopeKey = workload.scopeKey
            var selectedWorkerIndex = lightestWorkerIndex

            if let primaryWorkerIndex = primaryWorkerByScope[scopeKey],
               let primaryBucket = bucketQueue.bucket(workerIndex: primaryWorkerIndex) {
                let scopeWeight = scopeWeights[scopeKey, default: workload.candidateMutations]
                let expectedScopeShare = max(
                    1,
                    Int(ceil(Double(scopeWeight) / Double(jobsPlanned)))
                )
                let splitThreshold = max(
                    expectedScopeShare * 2,
                    min(targetBucketWeight, workload.candidateMutations * 2)
                )

                if primaryBucket.totalWeight <= lightestBucket.totalWeight + splitThreshold {
                    selectedWorkerIndex = primaryWorkerIndex
                }
            } else {
                primaryWorkerByScope[scopeKey] = lightestWorkerIndex
            }

            bucketQueue.updateBucket(workerIndex: selectedWorkerIndex) { bucket in
                bucket.workloads.append(workload)
                bucket.totalWeight += workload.candidateMutations
                bucket.scopeKeys.insert(scopeKey)
            }
        }

        let buckets = bucketQueue.snapshotSortedByWorkerIndex().map {
            MutationExecutionBucket(
                workerIndex: $0.workerIndex,
                workloads: $0.workloads,
                totalWeight: $0.totalWeight
            )
        }

        return MutationStrategyPlan(
            jobsRequested: jobs,
            jobsPlanned: jobsPlanned,
            workloads: workloads,
            buckets: buckets,
            scopeWeights: scopeWeights
        )
    }

    private struct MutableBucket {
        let workerIndex: Int
        var workloads: [MutationWorkload]
        var totalWeight: Int
        var scopeKeys: Set<String>
    }

    private struct BucketState {
        var bucket: MutableBucket
        var generation: Int
    }

    private struct BucketSnapshot {
        let workerIndex: Int
        let totalWeight: Int
        let generation: Int
    }

    /// Maintains the least-loaded worker at the root for O(log jobs) updates.
    private struct MinBucketQueue {
        private var states: [Int: BucketState]
        private var heap: [BucketSnapshot]

        init(elements: [MutableBucket]) {
            self.states = [:]
            self.heap = []
            self.states.reserveCapacity(elements.count)
            self.heap.reserveCapacity(elements.count)

            for bucket in elements {
                let state = BucketState(bucket: bucket, generation: 0)
                states[bucket.workerIndex] = state
                heap.append(
                    BucketSnapshot(
                        workerIndex: bucket.workerIndex,
                        totalWeight: bucket.totalWeight,
                        generation: 0
                    )
                )
            }

            if heap.count > 1 {
                for index in stride(from: (heap.count / 2) - 1, through: 0, by: -1) {
                    siftDown(from: index)
                }
            }
        }

        mutating func lightestWorkerIndex() -> Int? {
            pruneStaleRoot()
            return heap.first?.workerIndex
        }

        mutating func bucket(workerIndex: Int) -> MutableBucket? {
            states[workerIndex]?.bucket
        }

        mutating func updateBucket(
            workerIndex: Int,
            _ update: (inout MutableBucket) -> Void
        ) {
            guard var state = states[workerIndex] else {
                return
            }

            update(&state.bucket)
            state.generation += 1
            states[workerIndex] = state
            pushSnapshot(
                BucketSnapshot(
                    workerIndex: workerIndex,
                    totalWeight: state.bucket.totalWeight,
                    generation: state.generation
                )
            )
        }

        func snapshotSortedByWorkerIndex() -> [MutableBucket] {
            states.values.map(\.bucket).sorted { lhs, rhs in
                lhs.workerIndex < rhs.workerIndex
            }
        }

        private mutating func pruneStaleRoot() {
            while let root = heap.first, isStale(root) {
                popRoot()
            }
        }

        private func isStale(_ snapshot: BucketSnapshot) -> Bool {
            guard let state = states[snapshot.workerIndex] else {
                return true
            }

            return state.generation != snapshot.generation
                || state.bucket.totalWeight != snapshot.totalWeight
        }

        private mutating func pushSnapshot(_ snapshot: BucketSnapshot) {
            heap.append(snapshot)
            siftUp(from: heap.count - 1)
        }

        @discardableResult
        private mutating func popRoot() -> BucketSnapshot? {
            guard !heap.isEmpty else {
                return nil
            }

            let minimum = heap[0]
            if heap.count == 1 {
                heap.removeLast()
                return minimum
            }

            heap[0] = heap.removeLast()
            siftDown(from: 0)
            return minimum
        }

        private mutating func siftUp(from index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard isHigherPriority(heap[child], than: heap[parent]) else {
                    return
                }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from index: Int) {
            var parent = index
            while true {
                let left = (2 * parent) + 1
                let right = left + 1
                var smallest = parent

                if left < heap.count,
                   isHigherPriority(heap[left], than: heap[smallest]) {
                    smallest = left
                }
                if right < heap.count,
                   isHigherPriority(heap[right], than: heap[smallest]) {
                    smallest = right
                }

                guard smallest != parent else {
                    return
                }

                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }

        private func isHigherPriority(_ lhs: BucketSnapshot, than rhs: BucketSnapshot) -> Bool {
            if lhs.totalWeight == rhs.totalWeight {
                return lhs.workerIndex < rhs.workerIndex
            }
            return lhs.totalWeight < rhs.totalWeight
        }
    }
}
