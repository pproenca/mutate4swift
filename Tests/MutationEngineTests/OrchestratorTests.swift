import Foundation
import XCTest
@testable import MutationEngine

final class OrchestratorTests: XCTestCase {
    func testRunProducesKilledOutcomeAndRestoresSource() throws {
        try withTemporarySourceFile(contents: "let flag = true") { sourceFile in
            let runner = MockTestRunner(results: [.success(.passed), .success(.failed)])
            let orchestrator = Orchestrator(testRunner: runner, timeoutMultiplier: 10.0)

            let report = try orchestrator.run(
                sourceFile: sourceFile.path,
                packagePath: "/tmp/pkg"
            )

            XCTAssertEqual(report.totalMutations, 1)
            XCTAssertEqual(report.killed, 1)
            XCTAssertEqual(report.survived, 0)
            XCTAssertEqual(report.buildErrors, 0)
            XCTAssertEqual(runner.calls.count, 2)
            XCTAssertEqual(runner.calls[0].filter, "SampleTests")
            XCTAssertEqual(runner.calls[0].timeout, 600)
            XCTAssertEqual(runner.calls[1].timeout, 30.0)

            let finalSource = try String(contentsOf: sourceFile, encoding: .utf8)
            XCTAssertEqual(finalSource, "let flag = true")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path + ".mutate4swift.backup"))
        }
    }

    func testRunCanClassifySurvivedTimeoutAndBuildError() throws {
        let survived = try runSingleMutation(with: [.success(.passed), .success(.passed)])
        XCTAssertEqual(survived.survived, 1)

        let timedOut = try runSingleMutation(with: [.success(.passed), .success(.timeout)])
        XCTAssertEqual(timedOut.timedOut, 1)

        let buildError = try runSingleMutation(with: [.success(.passed), .success(.buildError)])
        XCTAssertEqual(buildError.buildErrors, 1)
    }

    func testRunTreatsThrownMutationRunAsBuildError() throws {
        let report = try runSingleMutation(with: [.success(.passed), .failure(MockError.boom)])
        XCTAssertEqual(report.buildErrors, 1)
    }

    func testRunThrowsWhenBaselineFails() throws {
        try withTemporarySourceFile(contents: "let flag = true") { sourceFile in
            let runner = MockTestRunner(results: [.success(.failed)])
            let orchestrator = Orchestrator(testRunner: runner)

            XCTAssertThrowsError(
                try orchestrator.run(sourceFile: sourceFile.path, packagePath: "/tmp/pkg")
            ) { error in
                guard case .baselineTestsFailed = error as? Mutate4SwiftError else {
                    XCTFail("Expected baselineTestsFailed, got \(error)")
                    return
                }
            }
        }
    }

    func testRunRespectsLineFilter() throws {
        try withTemporarySourceFile(contents: "let flag = true") { sourceFile in
            let runner = MockTestRunner(results: [.success(.passed)])
            let orchestrator = Orchestrator(testRunner: runner)

            let report = try orchestrator.run(
                sourceFile: sourceFile.path,
                packagePath: "/tmp/pkg",
                lines: [999]
            )

            XCTAssertEqual(report.totalMutations, 0)
            XCTAssertEqual(runner.calls.count, 1)
        }
    }

    func testRunRespectsCoverageFilterAndIgnoresCoverageErrors() throws {
        try withTemporarySourceFile(contents: "let flag = true") { sourceFile in
            let emptyCoverageRunner = MockTestRunner(results: [.success(.passed)])
            let emptyCoverage = MockCoverageProvider(result: .success([]))
            let filtered = Orchestrator(
                testRunner: emptyCoverageRunner,
                coverageProvider: emptyCoverage
            )
            let filteredReport = try filtered.run(
                sourceFile: sourceFile.path,
                packagePath: "/tmp/pkg"
            )
            XCTAssertEqual(filteredReport.totalMutations, 0)
            XCTAssertEqual(emptyCoverageRunner.calls.count, 1)

            let throwingCoverageRunner = MockTestRunner(results: [.success(.passed), .success(.passed)])
            let throwingCoverage = MockCoverageProvider(result: .failure(MockError.boom))
            let fallback = Orchestrator(
                testRunner: throwingCoverageRunner,
                coverageProvider: throwingCoverage,
                verbose: true
            )
            let fallbackReport = try fallback.run(
                sourceFile: sourceFile.path,
                packagePath: "/tmp/pkg"
            )
            XCTAssertEqual(fallbackReport.totalMutations, 1)
            XCTAssertEqual(fallbackReport.survived, 1)
        }
    }

    func testRunRestoresStaleBackupBeforeMutation() throws {
        try withTemporarySourceFile(contents: "let flag = true") { sourceFile in
            let backupPath = sourceFile.path + ".mutate4swift.backup"
            try "let flag = true".write(toFile: backupPath, atomically: true, encoding: .utf8)
            try "let flag = false".write(to: sourceFile, atomically: true, encoding: .utf8)

            let runner = MockTestRunner(results: [.success(.passed)])
            let orchestrator = Orchestrator(testRunner: runner, verbose: true)

            let report = try orchestrator.run(
                sourceFile: sourceFile.path,
                packagePath: "/tmp/pkg",
                lines: [999]
            )

            XCTAssertEqual(report.totalMutations, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath))
            let finalSource = try String(contentsOf: sourceFile, encoding: .utf8)
            XCTAssertEqual(finalSource, "let flag = true")
        }
    }

    func testRunWorksWithSPMTestRunnerBranch() throws {
        try withTemporarySwiftPackage { packagePath, sourceFile in
            let orchestrator = Orchestrator(
                testRunner: SPMTestRunner(),
                timeoutMultiplier: 5.0
            )

            let report = try orchestrator.run(
                sourceFile: sourceFile.path,
                packagePath: packagePath.path,
                lines: [999]
            )

            XCTAssertEqual(report.totalMutations, 0)
        }
    }

    private func runSingleMutation(
        with results: [Result<TestRunResult, Error>]
    ) throws -> MutationReport {
        try withTemporarySourceFile(contents: "let flag = true") { sourceFile in
            let runner = MockTestRunner(results: results)
            let orchestrator = Orchestrator(testRunner: runner)
            return try orchestrator.run(sourceFile: sourceFile.path, packagePath: "/tmp/pkg")
        }
    }

    private func withTemporarySourceFile<T>(
        contents: String,
        body: (URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchestratorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceFile = directory.appendingPathComponent("Sample.swift")
        try contents.write(to: sourceFile, atomically: true, encoding: .utf8)
        return try body(sourceFile)
    }

    private func withTemporarySwiftPackage(
        _ body: (URL, URL) throws -> Void
    ) throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let packageName = "Orchestrator\(suffix)"
        let packagePath = URL(fileURLWithPath: "/tmp").appendingPathComponent(packageName)
        try? FileManager.default.removeItem(at: packagePath)
        try FileManager.default.createDirectory(at: packagePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packagePath) }

        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(packageName)",
            products: [
                .library(name: "\(packageName)", targets: ["\(packageName)"]),
            ],
            targets: [
                .target(name: "\(packageName)"),
                .testTarget(name: "\(packageName)Tests", dependencies: ["\(packageName)"]),
            ]
        )
        """

        let sourceFile = packagePath.appendingPathComponent("Sources/\(packageName)/\(packageName).swift")
        let source = """
        public enum \(packageName) {
            public static let value = 42
        }
        """

        let tests = """
        import XCTest
        @testable import \(packageName)

        final class \(packageName)Tests: XCTestCase {
            func testValue() {
                XCTAssertEqual(\(packageName).value, 42)
            }
        }
        """

        try write(packageSwift, to: packagePath.appendingPathComponent("Package.swift"))
        try write(source, to: sourceFile)
        try write(tests, to: packagePath.appendingPathComponent("Tests/\(packageName)Tests/\(packageName)Tests.swift"))

        try body(packagePath, sourceFile)
    }

    private func write(_ content: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: path, atomically: true, encoding: .utf8)
    }
}

private enum MockError: Error {
    case boom
}

private final class MockTestRunner: TestRunner, @unchecked Sendable {
    var results: [Result<TestRunResult, Error>]
    var calls: [(packagePath: String, filter: String?, timeout: TimeInterval)] = []

    init(results: [Result<TestRunResult, Error>]) {
        self.results = results
    }

    func runTests(packagePath: String, filter: String?, timeout: TimeInterval) throws -> TestRunResult {
        calls.append((packagePath: packagePath, filter: filter, timeout: timeout))
        guard !results.isEmpty else { return .passed }
        let next = results.removeFirst()
        switch next {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

private final class MockCoverageProvider: CoverageProvider, @unchecked Sendable {
    let result: Result<Set<Int>, Error>

    init(result: Result<Set<Int>, Error>) {
        self.result = result
    }

    func coveredLines(forFile filePath: String, packagePath: String) throws -> Set<Int> {
        switch result {
        case .success(let covered): return covered
        case .failure(let error): throw error
        }
    }
}
