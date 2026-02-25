import Foundation
import XCTest
@testable import MutationEngine

final class MutationStrategyPlannerTests: XCTestCase {
    func testBuildPlanDistributesWorkloadsAcrossBuckets() async throws {
        try await withTemporaryPackage { packageRoot in
            let fileA = packageRoot.appendingPathComponent("Sources/MyLib/A.swift")
            let fileB = packageRoot.appendingPathComponent("Sources/MyLib/B.swift")
            let fileC = packageRoot.appendingPathComponent("Sources/MyLib/C.swift")

            try write("let value = true\n", to: fileA)
            try write("let a = true\nlet b = false\n", to: fileB)
            try write("let a = true\nlet b = false\nlet c = true\n", to: fileC)

            let planner = MutationStrategyPlanner()
            let plan = try await planner.buildPlan(
                sourceFiles: [fileA.path, fileB.path, fileC.path],
                packagePath: packageRoot.path,
                testFilterOverride: "MyLibTests",
                jobs: 2
            )

            XCTAssertEqual(plan.jobsPlanned, 2)
            XCTAssertEqual(plan.workloads.count, 3)
            XCTAssertTrue(plan.totalCandidateMutations > 0)
            XCTAssertEqual(
                plan.buckets.reduce(0) { $0 + $1.totalWeight },
                plan.totalCandidateMutations
            )

            let plannedFiles = Set(
                plan.buckets.flatMap(\.workloads).map(\.sourceFile)
            )
            XCTAssertEqual(plannedFiles, Set([fileA.path, fileB.path, fileC.path]))
        }
    }

    func testBuildPlanMarksUncoveredFilesWhenCoverageEliminatesAllSites() async throws {
        try await withTemporaryPackage { packageRoot in
            let coveredFile = packageRoot.appendingPathComponent("Sources/MyLib/Covered.swift")
            let uncoveredFile = packageRoot.appendingPathComponent("Sources/MyLib/Uncovered.swift")

            try write("let value = true\n", to: coveredFile)
            try write("let value = false\n", to: uncoveredFile)

            let coverage = StubCoverageProvider(linesByFile: [
                coveredFile.path: [1],
                uncoveredFile.path: [],
            ])
            let planner = MutationStrategyPlanner(coverageProvider: coverage)

            let plan = try await planner.buildPlan(
                sourceFiles: [coveredFile.path, uncoveredFile.path],
                packagePath: packageRoot.path,
                testFilterOverride: "MyLibTests",
                jobs: 2
            )

            XCTAssertTrue(plan.uncoveredFiles.contains(uncoveredFile.path))
            XCTAssertFalse(plan.uncoveredFiles.contains(coveredFile.path))
        }
    }

    func testBuildPlanCapsJobsToCandidateWorkloads() async throws {
        try await withTemporaryPackage { packageRoot in
            let file = packageRoot.appendingPathComponent("Sources/MyLib/Single.swift")
            try write("let value = true\n", to: file)

            let planner = MutationStrategyPlanner()
            let plan = try await planner.buildPlan(
                sourceFiles: [file.path],
                packagePath: packageRoot.path,
                testFilterOverride: "MyLibTests",
                jobs: 8
            )

            XCTAssertEqual(plan.jobsPlanned, 1)
        }
    }

    func testBuildPlanWithoutOverrideResolvesScopesWithoutCrashing() async throws {
        try await withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            try write(
                """
                public enum Calculator {
                    public static func value() -> Int { 42 }
                }
                """,
                to: sourceFile
            )
            try write(
                """
                import XCTest
                @testable import MyLib

                final class ScopeTests: XCTestCase {
                    func testValue() {
                        XCTAssertEqual(Calculator.value(), 42)
                    }
                }
                """,
                to: packageRoot.appendingPathComponent("Tests/MyLibTests/ScopeTests.swift")
            )

            let planner = MutationStrategyPlanner()
            let plan = try await planner.buildPlan(
                sourceFiles: [sourceFile.path],
                packagePath: packageRoot.path,
                jobs: 1
            )

            XCTAssertEqual(plan.workloads.count, 1)
            XCTAssertEqual(plan.workloads[0].sourceFile, sourceFile.path)
        }
    }

    func testBuildPlanKeepsDominantScopeMostlyAnchoredToOneWorker() async throws {
        try await withTemporaryPackage { packageRoot in
            var sourceFiles: [String] = []
            for index in 1...6 {
                let file = packageRoot.appendingPathComponent("Sources/MyLib/File\(index).swift")
                try write(
                    """
                    let a\(index) = true
                    let b\(index) = false
                    let c\(index) = true
                    """,
                    to: file
                )
                sourceFiles.append(file.path)
            }

            let planner = MutationStrategyPlanner()
            let plan = try await planner.buildPlan(
                sourceFiles: sourceFiles,
                packagePath: packageRoot.path,
                testFilterOverride: "MyLibTests",
                jobs: 3
            )

            let workersWithScope = plan.buckets.filter { bucket in
                bucket.workloads.contains { $0.scopeFilter == "MyLibTests" }
            }
            XCTAssertLessThanOrEqual(workersWithScope.count, 2)
        }
    }

    private func withTemporaryPackage(_ body: (URL) async throws -> Void) async throws {
        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutationStrategyPlannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "TmpPkg",
            targets: [
                .target(name: "MyLib"),
                .testTarget(name: "MyLibTests", dependencies: ["MyLib"]),
            ]
        )
        """
        try write(packageSwift, to: packageRoot.appendingPathComponent("Package.swift"))
        try write("import XCTest\n", to: packageRoot.appendingPathComponent("Tests/MyLibTests/SmokeTests.swift"))

        try await body(packageRoot)
    }

    private func write(_ content: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: path, atomically: true, encoding: .utf8)
    }
}

private final class StubCoverageProvider: CoverageProvider, @unchecked Sendable {
    private let linesByFile: [String: Set<Int>]

    init(linesByFile: [String: Set<Int>]) {
        self.linesByFile = linesByFile
    }

    func coveredLines(forFile filePath: String, packagePath: String) throws -> Set<Int> {
        linesByFile[filePath] ?? []
    }
}
