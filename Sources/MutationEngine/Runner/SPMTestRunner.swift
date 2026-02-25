import Foundation

public final class SPMTestRunner: BaselineCapableTestRunner, BuildSplitCapableTestRunner, @unchecked Sendable {
    private let verbose: Bool

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    public func runTests(packagePath: String, filter: String?, timeout: TimeInterval) throws -> TestRunResult {
        try runSwiftTest(
            packagePath: packagePath,
            filter: filter,
            timeout: timeout,
            skipBuild: false
        )
    }

    public func runBuild(packagePath: String, timeout: TimeInterval) throws -> TestRunResult {
        let result = try runCommand(
            executable: "/usr/bin/swift",
            args: ["build", "--package-path", packagePath, "--build-tests"],
            timeout: timeout
        )

        if verbose {
            print(result.output)
        }

        if result.didTimeout {
            return .timeout
        }

        if result.terminationStatus == 0 {
            return .passed
        }

        return .buildError
    }

    public func runTestsWithoutBuild(packagePath: String, filter: String?, timeout: TimeInterval) throws -> TestRunResult {
        try runSwiftTest(
            packagePath: packagePath,
            filter: filter,
            timeout: timeout,
            skipBuild: true
        )
    }

    private func runSwiftTest(
        packagePath: String,
        filter: String?,
        timeout: TimeInterval,
        skipBuild: Bool
    ) throws -> TestRunResult {
        var args = ["test", "--package-path", packagePath]
        if skipBuild {
            args.append("--skip-build")
        }
        if let filter = filter {
            args += ["--filter", filter]
        }

        let result = try runCommand(
            executable: "/usr/bin/swift",
            args: args,
            timeout: timeout
        )

        if result.didTimeout {
            return .timeout
        }

        let output = result.output
        if verbose {
            print(output)
        }

        let status = result.terminationStatus
        if status == 0 {
            if !didExecuteAtLeastOneTest(output) {
                return .noTests
            }
            return .passed
        }

        if indicatesNoTests(output), !didExecuteAtLeastOneTest(output) {
            return .noTests
        }

        if output.contains("error:") && !output.contains("Build complete!") {
            return .buildError
        }

        return .failed
    }

    private func runCommand(
        executable: String,
        args: [String],
        timeout: TimeInterval
    ) throws -> (terminationStatus: Int32, output: String, didTimeout: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Drain pipe output on a background thread to prevent buffer deadlock.
        // If the pipe buffer (~64KB) fills, the child process blocks on write,
        // waitUntilExit never returns, and we false-timeout.
        var outputData = Data()
        let outputLock = NSLock()
        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputLock.lock()
                outputData.append(data)
                outputLock.unlock()
            }
        }

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
            Thread.sleep(forTimeInterval: 0.5)
            process.interrupt()
        }

        // Stop reading and collect any remaining data
        fileHandle.readabilityHandler = nil
        let remaining = fileHandle.readDataToEndOfFile()
        outputLock.lock()
        outputData.append(remaining)
        let finalData = outputData
        outputLock.unlock()

        return (
            process.terminationStatus,
            String(decoding: finalData, as: UTF8.self),
            didTimeout
        )
    }

    /// Runs baseline tests, returning duration.
    public func runBaseline(packagePath: String, filter: String?) throws -> BaselineResult {
        let start = Date()
        let result = try runTests(packagePath: packagePath, filter: filter, timeout: 600)
        let duration = Date().timeIntervalSince(start)

        guard result == .passed else {
            if result == .noTests {
                throw Mutate4SwiftError.noTestsExecuted(filter)
            }
            throw Mutate4SwiftError.baselineTestsFailed
        }

        return BaselineResult(duration: duration)
    }

    private func didExecuteAtLeastOneTest(_ output: String) -> Bool {
        if output.range(
            of: #"Executed\s+[1-9][0-9]*\s+tests"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if output.range(
            of: #"Test run with\s+[1-9][0-9]*\s+tests"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return output.contains("Test Case '-[")
    }

    private func indicatesNoTests(_ output: String) -> Bool {
        if output.range(
            of: #"Test run with\s+0\s+tests"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return output.contains("No matching test cases were run")
    }
}
