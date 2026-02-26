import Foundation

public struct MutationSchedulerCostModel: Sendable {
    public let executionCostBySource: [String: Double]
    public let baselineCostByScope: [String: Double]
    public let defaultExecutionCost: Double
    public let defaultBaselineCost: Double

    public init(
        executionCostBySource: [String: Double] = [:],
        baselineCostByScope: [String: Double] = [:],
        defaultExecutionCost: Double = 1.0,
        defaultBaselineCost: Double = 0.0
    ) {
        self.executionCostBySource = executionCostBySource
        self.baselineCostByScope = baselineCostByScope
        self.defaultExecutionCost = defaultExecutionCost
        self.defaultBaselineCost = defaultBaselineCost
    }

    public func executionCost(for workload: MutationWorkload) -> Double {
        max(0, executionCostBySource[workload.sourceFile] ?? defaultExecutionCost)
    }

    public func baselineCost(for scopeKey: String) -> Double {
        max(0, baselineCostByScope[scopeKey] ?? defaultBaselineCost)
    }
}

public struct MutationSchedulerSimulationMetrics: Sendable, Codable {
    public let makespan: Double
    public let workerTimes: [Double]
    public let baselineExecutions: Int
    public let scheduledWorkloads: Int
    public let queueSteals: Int

    public init(
        makespan: Double,
        workerTimes: [Double],
        baselineExecutions: Int,
        scheduledWorkloads: Int,
        queueSteals: Int
    ) {
        self.makespan = makespan
        self.workerTimes = workerTimes
        self.baselineExecutions = baselineExecutions
        self.scheduledWorkloads = scheduledWorkloads
        self.queueSteals = queueSteals
    }
}

public struct MutationSchedulerBenchmarkComparison: Sendable, Codable {
    public let staticMetrics: MutationSchedulerSimulationMetrics
    public let dynamicMetrics: MutationSchedulerSimulationMetrics

    public init(
        staticMetrics: MutationSchedulerSimulationMetrics,
        dynamicMetrics: MutationSchedulerSimulationMetrics
    ) {
        self.staticMetrics = staticMetrics
        self.dynamicMetrics = dynamicMetrics
    }

    public var speedup: Double {
        guard dynamicMetrics.makespan > 0 else { return 0 }
        return staticMetrics.makespan / dynamicMetrics.makespan
    }

    public var makespanDelta: Double {
        staticMetrics.makespan - dynamicMetrics.makespan
    }
}

public enum MutationSchedulerBenchmark {
    public static func compare(
        plan: MutationStrategyPlan,
        costModel: MutationSchedulerCostModel
    ) async -> MutationSchedulerBenchmarkComparison {
        let staticMetrics = simulateStatic(plan: plan, costModel: costModel)
        let dynamicMetrics = await simulateDynamic(plan: plan, costModel: costModel)
        return MutationSchedulerBenchmarkComparison(
            staticMetrics: staticMetrics,
            dynamicMetrics: dynamicMetrics
        )
    }

    private static func simulateStatic(
        plan: MutationStrategyPlan,
        costModel: MutationSchedulerCostModel
    ) -> MutationSchedulerSimulationMetrics {
        let workerCount = max(1, plan.jobsPlanned)
        var workerTimes = Array(repeating: 0.0, count: workerCount)
        var baselineExecutions = 0
        var scheduledWorkloads = 0

        for bucket in plan.buckets where bucket.workerIndex < workerCount {
            var warmedScopes = Set<String>()
            var time = 0.0

            for workload in bucket.workloads where workload.candidateMutations > 0 {
                let scopeKey = workload.scopeKey
                if !warmedScopes.contains(scopeKey) {
                    time += costModel.baselineCost(for: scopeKey)
                    warmedScopes.insert(scopeKey)
                    baselineExecutions += 1
                }
                time += costModel.executionCost(for: workload)
                scheduledWorkloads += 1
            }

            workerTimes[bucket.workerIndex] = time
        }

        return MutationSchedulerSimulationMetrics(
            makespan: workerTimes.max() ?? 0,
            workerTimes: workerTimes,
            baselineExecutions: baselineExecutions,
            scheduledWorkloads: scheduledWorkloads,
            queueSteals: 0
        )
    }

    private static func simulateDynamic(
        plan: MutationStrategyPlan,
        costModel: MutationSchedulerCostModel
    ) async -> MutationSchedulerSimulationMetrics {
        struct WorkerState {
            var availableAt: Double = 0
            var warmedScopes: Set<String> = []
        }

        let workerCount = max(1, plan.jobsPlanned)
        let queue = MutationWorkQueue(plan: plan)
        var workers = Array(repeating: WorkerState(), count: workerCount)
        var baselineExecutions = 0
        var scheduledWorkloads = 0

        while true {
            let queueMetrics = await queue.metrics()
            if queueMetrics.remainingWorkloads == 0 {
                break
            }

            guard let workerIndex = workers.indices.min(by: { lhs, rhs in
                if workers[lhs].availableAt == workers[rhs].availableAt {
                    return lhs < rhs
                }
                return workers[lhs].availableAt < workers[rhs].availableAt
            }) else {
                break
            }

            guard let workload = await queue.next(
                for: workerIndex,
                warmedScopes: workers[workerIndex].warmedScopes
            ) else {
                break
            }

            let scopeKey = workload.scopeKey
            var duration = costModel.executionCost(for: workload)
            if !workers[workerIndex].warmedScopes.contains(scopeKey) {
                duration += costModel.baselineCost(for: scopeKey)
                workers[workerIndex].warmedScopes.insert(scopeKey)
                baselineExecutions += 1
            }

            workers[workerIndex].availableAt += duration
            scheduledWorkloads += 1
        }

        let queueMetrics = await queue.metrics()
        let workerTimes = workers.map(\.availableAt)
        return MutationSchedulerSimulationMetrics(
            makespan: workerTimes.max() ?? 0,
            workerTimes: workerTimes,
            baselineExecutions: baselineExecutions,
            scheduledWorkloads: scheduledWorkloads,
            queueSteals: queueMetrics.stolenWorkloads
        )
    }
}
