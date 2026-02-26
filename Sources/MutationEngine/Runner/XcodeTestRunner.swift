import Foundation

public struct XcodeTestInvocation: Sendable {
    public let workspacePath: String?
    public let projectPath: String?
    public let scheme: String
    public let destination: String?
    public let testPlan: String?
    public let configuration: String?
    public let derivedDataPath: String?

    public init(
        workspacePath: String?,
        projectPath: String?,
        scheme: String,
        destination: String?,
        testPlan: String?,
        configuration: String?,
        derivedDataPath: String?
    ) {
        self.workspacePath = workspacePath
        self.projectPath = projectPath
        self.scheme = scheme
        self.destination = destination
        self.testPlan = testPlan
        self.configuration = configuration
        self.derivedDataPath = derivedDataPath
    }
}

public final class XcodeTestRunner: BaselineCapableTestRunner, @unchecked Sendable {
    private let invocation: XcodeTestInvocation
    private let verbose: Bool
    private let executablePath: String

    public init(
        invocation: XcodeTestInvocation,
        verbose: Bool = false,
        executablePath: String = "/usr/bin/xcodebuild"
    ) {
        self.invocation = invocation
        self.verbose = verbose
        self.executablePath = executablePath
    }

    public func runTests(packagePath: String, filter: String?, timeout: TimeInterval) throws -> TestRunResult {
        let execution = try executeXcodeTests(
            packagePath: packagePath,
            filter: filter,
            timeout: timeout
        )

        if execution.didTimeout {
            return .timeout
        }

        if verbose {
            print(execution.output)
        }

        return classifyXcodeTestResult(
            terminationStatus: execution.terminationStatus,
            output: execution.output
        )
    }

    private func executeXcodeTests(
        packagePath: String,
        filter: String?,
        timeout: TimeInterval
    ) throws -> (terminationStatus: Int32, output: String, didTimeout: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = URL(fileURLWithPath: packagePath, isDirectory: true)
        process.arguments = buildArguments(filter: filter)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

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

    private func classifyXcodeTestResult(
        terminationStatus: Int32,
        output: String
    ) -> TestRunResult {
        if terminationStatus == 0 {
            return didExecuteAtLeastOneTest(output) ? .passed : .noTests
        }

        if indicatesNoTests(output), !didExecuteAtLeastOneTest(output) {
            return .noTests
        }

        if output.contains("** BUILD FAILED **") {
            return .buildError
        }

        if output.contains("error:"), !output.contains("** TEST FAILED **") {
            return .buildError
        }

        return .failed
    }

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

    private func buildArguments(filter: String?) -> [String] {
        var args: [String] = ["test"]

        if let workspacePath = invocation.workspacePath {
            args += ["-workspace", workspacePath]
        } else if let projectPath = invocation.projectPath {
            args += ["-project", projectPath]
        }

        args += ["-scheme", invocation.scheme]

        if let destination = invocation.destination {
            args += ["-destination", destination]
        }

        if let testPlan = invocation.testPlan {
            args += ["-testPlan", testPlan]
        }

        if let configuration = invocation.configuration {
            args += ["-configuration", configuration]
        }

        if let derivedDataPath = invocation.derivedDataPath {
            args += ["-derivedDataPath", derivedDataPath]
        }

        if let filter, !filter.isEmpty {
            args.append("-only-testing:\(filter)")
        }

        return args
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
            of: #"Executed\s+0\s+tests"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if output.range(
            of: #"Test run with\s+0\s+tests"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return output.contains("No tests were run")
    }
}
