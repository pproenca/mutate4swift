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

        if didTimeout {
            return .timeout
        }

        let output = String(decoding: finalData, as: UTF8.self)

        if verbose {
            print(output)
        }

        let status = process.terminationStatus

        if status == 0 {
            return .passed
        }

        // Check if it's a build error vs test failure
        if output.contains("error:") && !output.contains("Build complete!") {
            return .buildError
        }

        return .failed
    }

    /// Runs baseline tests, returning duration.
    public func runBaseline(packagePath: String, filter: String?) throws -> BaselineResult {
        let start = Date()
        let result = try runTests(packagePath: packagePath, filter: filter, timeout: 600)
        let duration = Date().timeIntervalSince(start)

        guard result == .passed else {
            throw Mutate4SwiftError.baselineTestsFailed
        }

        return BaselineResult(duration: duration)
    }
}
