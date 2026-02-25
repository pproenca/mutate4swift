import Foundation
import XCTest
@testable import MutationEngine

final class SPMTestRunnerTests: XCTestCase {
    func testRunTestsPassed() throws {
        try withTemporaryPackage(
            source: "public enum SamplePkg { public static func value() -> Int { 1 } }",
            testMethodBody: "XCTAssertEqual(SamplePkg.value(), 1)"
        ) { packagePath in
            let runner = SPMTestRunner(verbose: true)
            let result = try runner.runTests(
                packagePath: packagePath.path,
                filter: "SamplePkgTests",
                timeout: 60
            )
            XCTAssertEqual(result, .passed)
        }
    }

    func testRunTestsFailed() throws {
        try withTemporaryPackage(
            source: "public enum SamplePkg { public static func value() -> Int { 1 } }",
            testMethodBody: "XCTAssertEqual(SamplePkg.value(), 2)"
        ) { packagePath in
            let runner = SPMTestRunner()
            let result = try runner.runTests(packagePath: packagePath.path, filter: nil, timeout: 60)
            XCTAssertEqual(result, .failed)
        }
    }

    func testRunTestsBuildError() throws {
        try withTemporaryPackage(
            source: "public enum SamplePkg { public static func value() -> Int {",
            testMethodBody: "XCTAssertTrue(true)"
        ) { packagePath in
            let runner = SPMTestRunner()
            let result = try runner.runTests(packagePath: packagePath.path, filter: nil, timeout: 60)
            XCTAssertEqual(result, .buildError)
        }
    }

    func testRunTestsTimeout() throws {
        try withTemporaryPackage(
            source: "public enum SamplePkg { public static func value() -> Int { 1 } }",
            testMethodBody: """
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertEqual(SamplePkg.value(), 1)
            """
        ) { packagePath in
            let runner = SPMTestRunner()
            let result = try runner.runTests(packagePath: packagePath.path, filter: nil, timeout: 0.01)
            XCTAssertEqual(result, .timeout)
        }
    }

    func testRunTestsReturnsNoTestsWhenFilterMatchesNothing() throws {
        try withTemporaryPackage(
            source: "public enum SamplePkg { public static func value() -> Int { 1 } }",
            testMethodBody: "XCTAssertEqual(SamplePkg.value(), 1)"
        ) { packagePath in
            let runner = SPMTestRunner()
            let result = try runner.runTests(
                packagePath: packagePath.path,
                filter: "MissingTests",
                timeout: 60
            )
            XCTAssertEqual(result, .noTests)
        }
    }

    func testRunBaselineSuccessAndFailure() throws {
        try withTemporaryPackage(
            source: "public enum SamplePkg { public static func value() -> Int { 1 } }",
            testMethodBody: "XCTAssertEqual(SamplePkg.value(), 1)"
        ) { packagePath in
            let runner = SPMTestRunner()
            let baseline = try runner.runBaseline(packagePath: packagePath.path, filter: nil)
            XCTAssertGreaterThanOrEqual(baseline.timeout, 30)
        }

        try withTemporaryPackage(
            source: "public enum SamplePkg { public static func value() -> Int { 1 } }",
            testMethodBody: "XCTAssertEqual(SamplePkg.value(), 2)"
        ) { packagePath in
            let runner = SPMTestRunner()
            XCTAssertThrowsError(
                try runner.runBaseline(packagePath: packagePath.path, filter: nil)
            ) { error in
                guard case .baselineTestsFailed = error as? Mutate4SwiftError else {
                    XCTFail("Expected baselineTestsFailed, got \(error)")
                    return
                }
            }
        }
    }

    func testRunBaselineThrowsWhenNoTestsExecuted() throws {
        try withTemporaryPackage(
            source: "public enum SamplePkg { public static func value() -> Int { 1 } }",
            testMethodBody: "XCTAssertEqual(SamplePkg.value(), 1)"
        ) { packagePath in
            let runner = SPMTestRunner()
            XCTAssertThrowsError(
                try runner.runBaseline(packagePath: packagePath.path, filter: "MissingTests")
            ) { error in
                guard case .noTestsExecuted(let filter) = error as? Mutate4SwiftError else {
                    XCTFail("Expected noTestsExecuted, got \(error)")
                    return
                }
                XCTAssertEqual(filter, "MissingTests")
            }
        }
    }

    private func withTemporaryPackage(
        source: String,
        testMethodBody: String,
        body: (URL) throws -> Void
    ) throws {
        let packagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPMTestRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packagePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packagePath) }

        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "SamplePkg",
            products: [
                .library(name: "SamplePkg", targets: ["SamplePkg"]),
            ],
            targets: [
                .target(name: "SamplePkg"),
                .testTarget(name: "SamplePkgTests", dependencies: ["SamplePkg"]),
            ]
        )
        """

        let testSource = """
        import Foundation
        import XCTest
        @testable import SamplePkg

        final class SamplePkgTests: XCTestCase {
            func testValue() {
                \(testMethodBody)
            }
        }
        """

        try write(packageSwift, to: packagePath.appendingPathComponent("Package.swift"))
        try write(source, to: packagePath.appendingPathComponent("Sources/SamplePkg/SamplePkg.swift"))
        try write(testSource, to: packagePath.appendingPathComponent("Tests/SamplePkgTests/SamplePkgTests.swift"))

        try body(packagePath)
    }

    private func write(_ content: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: path, atomically: true, encoding: .utf8)
    }
}
