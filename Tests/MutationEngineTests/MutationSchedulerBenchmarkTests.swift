import XCTest
@testable import MutationEngine

final class MutationSchedulerBenchmarkTests: XCTestCase {
    func testCompareIsDeterministicAcrossRuns() async {
        let workloads = makeUniformScopeWorkloads(count: 18, scope: "FixtureTests")
        let plan = MutationStrategyPlanner().plan(workloads: workloads, jobs: 4)
        let model = MutationSchedulerCostModel(
            executionCostBySource: executionCosts(for: workloads, multiplier: 5),
            baselineCostByScope: ["FixtureTests": 12]
        )

        let baseline = await MutationSchedulerBenchmark.compare(plan: plan, costModel: model)

        for _ in 0..<5 {
            let comparison = await MutationSchedulerBenchmark.compare(plan: plan, costModel: model)
            XCTAssertEqual(comparison.staticMetrics.makespan, baseline.staticMetrics.makespan)
            XCTAssertEqual(comparison.dynamicMetrics.makespan, baseline.dynamicMetrics.makespan)
            XCTAssertEqual(comparison.dynamicMetrics.queueSteals, baseline.dynamicMetrics.queueSteals)
            XCTAssertEqual(comparison.staticMetrics.baselineExecutions, baseline.staticMetrics.baselineExecutions)
            XCTAssertEqual(comparison.dynamicMetrics.baselineExecutions, baseline.dynamicMetrics.baselineExecutions)
        }
    }

    func testDynamicSchedulerImprovesScopeAffinityBottleneck() async {
        let workloads = makeUniformScopeWorkloads(count: 24, scope: "FixtureTests")
        let plan = MutationStrategyPlanner().plan(workloads: workloads, jobs: 4)
        let costModel = MutationSchedulerCostModel(
            executionCostBySource: executionCosts(for: workloads, multiplier: 8),
            baselineCostByScope: ["FixtureTests": 10]
        )

        let comparison = await MutationSchedulerBenchmark.compare(
            plan: plan,
            costModel: costModel
        )

        XCTAssertLessThan(comparison.dynamicMetrics.makespan, comparison.staticMetrics.makespan)
        XCTAssertGreaterThan(comparison.speedup, 1.2)
        XCTAssertGreaterThan(comparison.dynamicMetrics.queueSteals, 0)
        XCTAssertEqual(
            comparison.dynamicMetrics.scheduledWorkloads,
            workloads.count
        )
    }

    private func makeUniformScopeWorkloads(count: Int, scope: String) -> [MutationWorkload] {
        (1...count).map { index in
            let weight = 8 + (index % 5)
            return MutationWorkload(
                sourceFile: "/tmp/benchmark/File\(index).swift",
                scopeFilter: scope,
                potentialMutations: weight,
                candidateMutations: weight
            )
        }
    }

    private func executionCosts(
        for workloads: [MutationWorkload],
        multiplier: Int
    ) -> [String: Double] {
        workloads.reduce(into: [String: Double]()) { partial, workload in
            partial[workload.sourceFile] = Double(workload.candidateMutations * multiplier)
        }
    }
}
