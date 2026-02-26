import XCTest
@testable import MutationEngine

final class MutationWorkQueueTests: XCTestCase {
    func testQueueConsumesSeededWorkBeforeStealing() async {
        let fileA = workload(path: "/tmp/A.swift", scope: "ScopeA", weight: 6)
        let fileB = workload(path: "/tmp/B.swift", scope: "ScopeB", weight: 4)
        let plan = makePlan(
            jobs: 2,
            buckets: [
                [fileA],
                [fileB],
            ]
        )
        let queue = MutationWorkQueue(plan: plan)

        let first = await queue.next(for: 0)
        let second = await queue.next(for: 0)
        let metrics = await queue.metrics()

        XCTAssertEqual(first?.sourceFile, fileA.sourceFile)
        XCTAssertEqual(second?.sourceFile, fileB.sourceFile)
        XCTAssertEqual(metrics.dispatchedWorkloads, 2)
        XCTAssertEqual(metrics.stolenWorkloads, 1)
    }

    func testQueueStealsFromHeaviestDonor() async {
        let heavy = workload(path: "/tmp/Heavy.swift", scope: "ScopeHeavy", weight: 10)
        let light = workload(path: "/tmp/Light.swift", scope: "ScopeLight", weight: 3)
        let plan = makePlan(
            jobs: 3,
            buckets: [
                [heavy],
                [light],
                [],
            ]
        )
        let queue = MutationWorkQueue(plan: plan)

        let stolen = await queue.next(for: 2)
        let metrics = await queue.metrics()

        XCTAssertEqual(stolen?.sourceFile, heavy.sourceFile)
        XCTAssertEqual(metrics.stolenWorkloads, 1)
    }

    func testQueueStealPrefersWarmScopeToReuseBaseline() async {
        let scopeOneHeavy = workload(path: "/tmp/ScopeOneHeavy.swift", scope: "ScopeOne", weight: 6)
        let scopeTwoHeavier = workload(path: "/tmp/ScopeTwoHeavier.swift", scope: "ScopeTwo", weight: 9)
        let warmScopeSeed = workload(path: "/tmp/WarmScopeSeed.swift", scope: "ScopeOne", weight: 4)
        let plan = makePlan(
            jobs: 2,
            buckets: [
                [scopeTwoHeavier, scopeOneHeavy],
                [warmScopeSeed],
            ]
        )
        let queue = MutationWorkQueue(plan: plan)

        _ = await queue.next(for: 1)
        let stolen = await queue.next(for: 1, warmedScopes: ["ScopeOne"])

        XCTAssertEqual(stolen?.sourceFile, scopeOneHeavy.sourceFile)
    }

    private func makePlan(
        jobs: Int,
        buckets: [[MutationWorkload]]
    ) -> MutationStrategyPlan {
        let strategyBuckets = buckets.enumerated().map { index, workloads in
            MutationExecutionBucket(
                workerIndex: index,
                workloads: workloads,
                totalWeight: workloads.reduce(0) { $0 + $1.candidateMutations }
            )
        }
        let workloads = buckets.flatMap { $0 }
        let scopeWeights = workloads.reduce(into: [String: Int]()) { partial, workload in
            partial[workload.scopeKey, default: 0] += workload.candidateMutations
        }

        return MutationStrategyPlan(
            jobsRequested: jobs,
            jobsPlanned: jobs,
            workloads: workloads,
            buckets: strategyBuckets,
            scopeWeights: scopeWeights
        )
    }

    private func workload(path: String, scope: String, weight: Int) -> MutationWorkload {
        MutationWorkload(
            sourceFile: path,
            scopeFilter: scope,
            potentialMutations: weight,
            candidateMutations: weight
        )
    }
}
