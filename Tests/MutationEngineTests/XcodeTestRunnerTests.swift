import Foundation
import XCTest
@testable import MutationEngine

final class XcodeTestRunnerTests: XCTestCase {
    func testRunTestsPassedWhenOutputShowsExecutedTests() throws {
        try withExecutableScript(
            """
            #!/bin/sh
            echo "Executed 3 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds"
            exit 0
            """
        ) { scriptPath, workDir in
            let runner = XcodeTestRunner(
                invocation: invocation(workspacePath: "/tmp/App.xcworkspace"),
                executablePath: scriptPath.path
            )
            let result = try runner.runTests(packagePath: workDir.path, filter: nil, timeout: 5)
            XCTAssertEqual(result, .passed)
        }
    }

    func testRunTestsReturnsNoTestsWhenOutputShowsZeroTests() throws {
        try withExecutableScript(
            """
            #!/bin/sh
            echo "Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds"
            exit 0
            """
        ) { scriptPath, workDir in
            let runner = XcodeTestRunner(
                invocation: invocation(workspacePath: "/tmp/App.xcworkspace"),
                executablePath: scriptPath.path
            )
            let result = try runner.runTests(packagePath: workDir.path, filter: nil, timeout: 5)
            XCTAssertEqual(result, .noTests)
        }
    }

    func testRunTestsClassifiesBuildFailures() throws {
        try withExecutableScript(
            """
            #!/bin/sh
            echo "** BUILD FAILED **"
            exit 65
            """
        ) { scriptPath, workDir in
            let runner = XcodeTestRunner(
                invocation: invocation(projectPath: "/tmp/App.xcodeproj"),
                executablePath: scriptPath.path
            )
            let result = try runner.runTests(packagePath: workDir.path, filter: nil, timeout: 5)
            XCTAssertEqual(result, .buildError)
        }
    }

    func testRunTestsClassifiesTestFailures() throws {
        try withExecutableScript(
            """
            #!/bin/sh
            echo "** TEST FAILED **"
            echo "Executed 2 tests, with 1 failure (0 unexpected) in 0.020 (0.021) seconds"
            exit 65
            """
        ) { scriptPath, workDir in
            let runner = XcodeTestRunner(
                invocation: invocation(projectPath: "/tmp/App.xcodeproj"),
                executablePath: scriptPath.path
            )
            let result = try runner.runTests(packagePath: workDir.path, filter: nil, timeout: 5)
            XCTAssertEqual(result, .failed)
        }
    }

    func testRunTestsPassesOnlyTestingFilterToXcodebuild() throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeTestRunnerArgs-\(UUID().uuidString).txt")

        try withExecutableScript(
            """
            #!/bin/sh
            printf "%s\\n" "$@" > "\(argsFile.path)"
            echo "Executed 1 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds"
            exit 0
            """
        ) { scriptPath, workDir in
            defer { try? FileManager.default.removeItem(at: argsFile) }

            let runner = XcodeTestRunner(
                invocation: XcodeTestInvocation(
                    workspacePath: "/tmp/App.xcworkspace",
                    projectPath: nil,
                    scheme: "AppTests",
                    destination: "platform=iOS Simulator,name=iPhone 16",
                    testPlan: "CI",
                    configuration: "Debug",
                    derivedDataPath: "/tmp/DerivedData"
                ),
                executablePath: scriptPath.path
            )

            _ = try runner.runTests(
                packagePath: workDir.path,
                filter: "AppTests/FeatureTests/testExample",
                timeout: 5
            )

            let args = try String(contentsOf: argsFile, encoding: .utf8)
            XCTAssertTrue(args.contains("test"))
            XCTAssertTrue(args.contains("-workspace"))
            XCTAssertTrue(args.contains("/tmp/App.xcworkspace"))
            XCTAssertTrue(args.contains("-scheme"))
            XCTAssertTrue(args.contains("AppTests"))
            XCTAssertTrue(args.contains("-destination"))
            XCTAssertTrue(args.contains("platform=iOS Simulator,name=iPhone 16"))
            XCTAssertTrue(args.contains("-testPlan"))
            XCTAssertTrue(args.contains("CI"))
            XCTAssertTrue(args.contains("-configuration"))
            XCTAssertTrue(args.contains("Debug"))
            XCTAssertTrue(args.contains("-derivedDataPath"))
            XCTAssertTrue(args.contains("/tmp/DerivedData"))
            XCTAssertTrue(args.contains("-only-testing:AppTests/FeatureTests/testExample"))
        }
    }

    func testRunBaselineThrowsWhenNoTestsExecuted() throws {
        try withExecutableScript(
            """
            #!/bin/sh
            echo "Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds"
            exit 0
            """
        ) { scriptPath, workDir in
            let runner = XcodeTestRunner(
                invocation: invocation(projectPath: "/tmp/App.xcodeproj"),
                executablePath: scriptPath.path
            )

            XCTAssertThrowsError(
                try runner.runBaseline(packagePath: workDir.path, filter: "AppTests/Foo")
            ) { error in
                guard case .noTestsExecuted(let filter) = error as? Mutate4SwiftError else {
                    XCTFail("Expected noTestsExecuted, got \(error)")
                    return
                }
                XCTAssertEqual(filter, "AppTests/Foo")
            }
        }
    }

    private func invocation(workspacePath: String? = nil, projectPath: String? = nil) -> XcodeTestInvocation {
        XcodeTestInvocation(
            workspacePath: workspacePath,
            projectPath: projectPath,
            scheme: "AppTests",
            destination: nil,
            testPlan: nil,
            configuration: nil,
            derivedDataPath: nil
        )
    }

    private func withExecutableScript(
        _ script: String,
        body: (URL, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeTestRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptPath = directory.appendingPathComponent("fake-xcodebuild.sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptPath.path
        )

        try body(scriptPath, directory)
    }
}
