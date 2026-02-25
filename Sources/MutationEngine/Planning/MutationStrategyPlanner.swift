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
    ) throws -> MutationStrategyPlan {
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
            let filter = testFilterOverride ?? testFileMapper.testFilter(forSourceFile: sourceFile)

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
        var mutableBuckets = (0..<jobsPlanned).map {
            MutableBucket(workerIndex: $0, workloads: [], totalWeight: 0)
        }

        let sortedWorkloads = candidateWorkloads.sorted {
            if $0.candidateMutations == $1.candidateMutations {
                return $0.sourceFile < $1.sourceFile
            }
            return $0.candidateMutations > $1.candidateMutations
        }

        // LPT schedule (Longest Processing Time first): CLRS-style list scheduling.
        for workload in sortedWorkloads {
            let targetIndex = mutableBuckets.indices.min {
                let lhs = mutableBuckets[$0]
                let rhs = mutableBuckets[$1]
                if lhs.totalWeight == rhs.totalWeight {
                    return lhs.workerIndex < rhs.workerIndex
                }
                return lhs.totalWeight < rhs.totalWeight
            } ?? 0

            mutableBuckets[targetIndex].workloads.append(workload)
            mutableBuckets[targetIndex].totalWeight += workload.candidateMutations
        }

        let buckets = mutableBuckets.map {
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
    }
}
