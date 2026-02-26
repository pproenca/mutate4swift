import Foundation
import XCTest
@testable import MutationEngine

final class SPMTestRunnerTests: XCTestCase {
    private static let packageName = "SamplePkg"
    private static let packageLock = NSLock()
    private static var packagePath: URL?

    override class func setUp() {
        super.setUp()
        do {
            packagePath = FileManager.default.temporaryDirectory
                .appendingPathComponent("SPMTestRunnerTests-\(UUID().uuidString)")
            guard let packagePath else {
                XCTFail("Failed to create package path")
                return
            }

            try FileManager.default.createDirectory(at: packagePath, withIntermediateDirectories: true)
            try writePackageManifest(at: packagePath)
        } catch {
            XCTFail("Failed to set up shared Swift package fixture: \(error)")
        }
    }

    override class func tearDown() {
        if let packagePath {
            try? FileManager.default.removeItem(at: packagePath)
        }
        packagePath = nil
        super.tearDown()
    }

    override func invokeTest() {
        // This suite mutates one shared fixture package to avoid repeated full rebuilds.
        Self.packageLock.lock()
        defer { Self.packageLock.unlock() }
        super.invokeTest()
    }

    func testRunTestsPassed() throws {
        try withConfiguredPackage(
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
        try withConfiguredPackage(
            source: "public enum SamplePkg { public static func value() -> Int { 1 } }",
            testMethodBody: "XCTAssertEqual(SamplePkg.value(), 2)"
        ) { packagePath in
            let runner = SPMTestRunner()
            let result = try runner.runTests(packagePath: packagePath.path, filter: nil, timeout: 60)
            XCTAssertEqual(result, .failed)
        }
    }

    func testRunTestsBuildError() throws {
        try withConfiguredPackage(
            source: "public enum SamplePkg { public static func value() -> Int {",
            testMethodBody: "XCTAssertTrue(true)"
        ) { packagePath in
            let runner = SPMTestRunner()
            let result = try runner.runTests(packagePath: packagePath.path, filter: nil, timeout: 60)
            XCTAssertEqual(result, .buildError)
        }
    }

    func testRunTestsTimeout() throws {
        try withConfiguredPackage(
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
        try withConfiguredPackage(
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
        try withConfiguredPackage(
            source: "public enum SamplePkg { public static func value() -> Int { 1 } }",
            testMethodBody: "XCTAssertEqual(SamplePkg.value(), 1)"
        ) { packagePath in
            let runner = SPMTestRunner()
            let baseline = try runner.runBaseline(packagePath: packagePath.path, filter: nil)
            XCTAssertGreaterThanOrEqual(baseline.timeout, 30)
        }

        try withConfiguredPackage(
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
        try withConfiguredPackage(
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

    func testRunBuildAndRunTestsWithoutBuildPassed() throws {
        try withConfiguredPackage(
            source: "public enum SamplePkg { public static func value() -> Int { 1 } }",
            testMethodBody: "XCTAssertEqual(SamplePkg.value(), 1)"
        ) { packagePath in
            let runner = SPMTestRunner()

            let buildResult = try runner.runBuild(
                packagePath: packagePath.path,
                timeout: 60
            )
            XCTAssertEqual(buildResult, .passed)

            let testsResult = try runner.runTestsWithoutBuild(
                packagePath: packagePath.path,
                filter: "SamplePkgTests",
                timeout: 60
            )
            XCTAssertEqual(testsResult, .passed)
        }
    }

    func testRunBuildReturnsBuildError() throws {
        try withConfiguredPackage(
            source: "public enum SamplePkg { public static func value() -> Int {",
            testMethodBody: "XCTAssertTrue(true)"
        ) { packagePath in
            let runner = SPMTestRunner()
            let result = try runner.runBuild(packagePath: packagePath.path, timeout: 60)
            XCTAssertEqual(result, .buildError)
        }
    }

    private func withConfiguredPackage(
        source: String,
        testMethodBody: String,
        body: (URL) throws -> Void
    ) throws {
        guard let packagePath = Self.packagePath else {
            throw NSError(
                domain: "SPMTestRunnerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Shared package fixture is not initialized"]
            )
        }

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

        try write(
            source,
            to: packagePath.appendingPathComponent("Sources/\(Self.packageName)/\(Self.packageName).swift")
        )
        try write(
            testSource,
            to: packagePath.appendingPathComponent("Tests/\(Self.packageName)Tests/\(Self.packageName)Tests.swift")
        )

        try body(packagePath)
    }

    private static func writePackageManifest(at packagePath: URL) throws {
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

        try packageSwift.write(
            to: packagePath.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func write(_ content: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: path, atomically: true, encoding: .utf8)
    }
}
