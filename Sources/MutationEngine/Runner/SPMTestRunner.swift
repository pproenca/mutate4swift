import Foundation

public final class SPMTestRunner: TestRunner, @unchecked Sendable {
    private let verbose: Bool

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    public func runTests(packagePath: String, filter: String?, timeout: TimeInterval) throws -> TestRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")

        var args = ["test", "--package-path", packagePath]
        if let filter = filter {
            args += ["--filter", filter]
        }
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Timeout handling
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()

        var didTimeout = false
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            didTimeout = true
            process.terminate()
            // Give it a moment to clean up
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning {
                process.interrupt()
            }
        }

        if didTimeout {
            return .timeout
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        if verbose {
            print(output)
        }

        let status = process.terminationStatus

        // swift test exits 0 on success
        if status == 0 {
            return .passed
        }

        // Check if it's a build error vs test failure
        if output.contains("error:") && output.contains("Build complete!") == false {
            return .buildError
        }

        return .failed
    }

    /// Runs baseline tests, returning duration.
    public func runBaseline(packagePath: String, filter: String?) throws -> BaselineResult {
        let start = Date()
        let result = try runTests(packagePath: packagePath, filter: filter, timeout: 600) // 10 min max for baseline
        let duration = Date().timeIntervalSince(start)

        guard result == .passed else {
            throw Mutate4SwiftError.baselineTestsFailed
        }

        return BaselineResult(duration: duration)
    }
}
