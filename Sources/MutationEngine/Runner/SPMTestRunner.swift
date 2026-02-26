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
            timeout: timeout,
            captureOutput: verbose,
            analyzeOutput: false
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
        let args = swiftTestArguments(
            packagePath: packagePath,
            filter: filter,
            skipBuild: skipBuild
        )

        let result = try runCommand(
            executable: "/usr/bin/swift",
            args: args,
            timeout: timeout,
            captureOutput: verbose,
            analyzeOutput: true
        )

        if result.didTimeout {
            return .timeout
        }

        let output = result.output
        if verbose {
            print(output)
        }

        return classifySwiftTestResult(
            terminationStatus: result.terminationStatus,
            analysis: result.analysis
        )
    }

    private func swiftTestArguments(
        packagePath: String,
        filter: String?,
        skipBuild: Bool
    ) -> [String] {
        var args = ["test", "--package-path", packagePath]
        if skipBuild {
            args.append("--skip-build")
        }
        if let filter {
            args += ["--filter", filter]
        }
        return args
    }

    private func classifySwiftTestResult(
        terminationStatus: Int32,
        analysis: OutputAnalysis
    ) -> TestRunResult {
        if terminationStatus == 0 {
            return analysis.executedAtLeastOneTest ? .passed : .noTests
        }

        if analysis.indicatesNoTests && !analysis.executedAtLeastOneTest {
            return .noTests
        }

        if analysis.sawBuildErrorMarker && !analysis.sawBuildCompleteMarker {
            return .buildError
        }

        return .failed
    }

    private func runCommand(
        executable: String,
        args: [String],
        timeout: TimeInterval,
        captureOutput: Bool,
        analyzeOutput: Bool
    ) throws -> (
        terminationStatus: Int32,
        output: String,
        didTimeout: Bool,
        analysis: OutputAnalysis
    ) {
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
        var analysis = OutputAnalysis()
        let outputLock = NSLock()
        let fileHandle = pipe.fileHandleForReading

        func absorb(_ data: Data) {
            guard !data.isEmpty else {
                return
            }

            outputLock.lock()
            if captureOutput {
                outputData.append(data)
            }
            if analyzeOutput {
                analysis.ingest(data)
            }
            outputLock.unlock()
        }

        fileHandle.readabilityHandler = { handle in
            absorb(handle.availableData)
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
        absorb(fileHandle.readDataToEndOfFile())

        outputLock.lock()
        let finalData = outputData
        let finalAnalysis = analysis
        outputLock.unlock()

        return (
            process.terminationStatus,
            captureOutput ? String(decoding: finalData, as: UTF8.self) : "",
            didTimeout,
            finalAnalysis
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

    private struct OutputAnalysis: Sendable {
        var executedAtLeastOneTest = false
        var indicatesNoTests = false
        var sawBuildErrorMarker = false
        var sawBuildCompleteMarker = false

        private var rollingWindow = ""

        mutating func ingest(_ data: Data) {
            let chunk = String(decoding: data, as: UTF8.self)
            guard !chunk.isEmpty else {
                return
            }

            let scan = rollingWindow + chunk
            updateTestExecutionMarkers(scan)
            updateNoTestsMarker(scan)
            updateBuildMarkers(scan)
            rollingWindow = String(scan.suffix(512))
        }

        private mutating func updateTestExecutionMarkers(_ scan: String) {
            guard !executedAtLeastOneTest else {
                return
            }
            executedAtLeastOneTest = hasExecutedTestMarker(scan)
        }

        private func hasExecutedTestMarker(_ scan: String) -> Bool {
            scan.range(of: #"Executed\s+[1-9][0-9]*\s+tests"#, options: .regularExpression) != nil
                || scan.range(of: #"Test run with\s+[1-9][0-9]*\s+tests"#, options: .regularExpression) != nil
                || scan.contains("Test Case '-[")
        }

        private mutating func updateNoTestsMarker(_ scan: String) {
            guard !indicatesNoTests else {
                return
            }
            indicatesNoTests = hasNoTestsMarker(scan)
        }

        private func hasNoTestsMarker(_ scan: String) -> Bool {
            scan.range(of: #"Test run with\s+0\s+tests"#, options: .regularExpression) != nil
                || scan.contains("No matching test cases were run")
        }

        private mutating func updateBuildMarkers(_ scan: String) {
            if !sawBuildErrorMarker {
                sawBuildErrorMarker = scan.contains("error:")
            }
            if !sawBuildCompleteMarker {
                sawBuildCompleteMarker = scan.contains("Build complete!")
            }
        }
    }
}
