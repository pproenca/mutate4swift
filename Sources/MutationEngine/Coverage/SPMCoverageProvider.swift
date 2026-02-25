import Foundation

public final class SPMCoverageProvider: CoverageProvider, @unchecked Sendable {
    private let verbose: Bool
    private let cacheLock = NSLock()
    private var coverageByPackageCache: [String: [String: Set<Int>]] = [:]

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    public func coveredLines(forFile filePath: String, packagePath: String) throws -> Set<Int> {
        let normalizedPackagePath = (packagePath as NSString).standardizingPath
        let normalizedFilePath = (filePath as NSString).standardizingPath

        cacheLock.lock()
        if let cachedCoverage = coverageByPackageCache[normalizedPackagePath] {
            let lines = cachedCoverage[normalizedFilePath] ?? []
            cacheLock.unlock()
            return lines
        }
        cacheLock.unlock()

        // Run swift test with coverage enabled
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        buildProcess.arguments = ["test", "--package-path", normalizedPackagePath, "--enable-code-coverage"]

        let buildPipe = Pipe()
        buildProcess.standardOutput = buildPipe
        buildProcess.standardError = buildPipe

        try buildProcess.run()
        buildProcess.waitUntilExit()

        guard buildProcess.terminationStatus == 0 else {
            throw Mutate4SwiftError.coverageDataUnavailable
        }

        // Find the profdata and binary
        let buildPath = (normalizedPackagePath as NSString).appendingPathComponent(".build")
        let codecovPath = try findCodecovJSON(buildPath: buildPath, packagePath: normalizedPackagePath)
        let coverageByFile = try parseCoverageMap(codecovPath: codecovPath)

        cacheLock.lock()
        coverageByPackageCache[normalizedPackagePath] = coverageByFile
        let lines = coverageByFile[normalizedFilePath] ?? []
        cacheLock.unlock()

        return lines
    }

    func findCodecovJSON(buildPath: String, packagePath: String) throws -> String {
        // swift test --enable-code-coverage produces a codecov JSON at .build/debug/codecov/
        // We use `llvm-cov export` to generate the JSON

        // Find the .profdata
        let profdataPath = (buildPath as NSString)
            .appendingPathComponent("debug/codecov/default.profdata")

        guard FileManager.default.fileExists(atPath: profdataPath) else {
            throw Mutate4SwiftError.coverageDataUnavailable
        }

        // Find the test binary
        let packageName = URL(fileURLWithPath: packagePath).lastPathComponent
        let binaryPath = (buildPath as NSString)
            .appendingPathComponent("debug/\(packageName)PackageTests.xctest/Contents/MacOS/\(packageName)PackageTests")

        guard FileManager.default.fileExists(atPath: binaryPath) else {
            // Try alternative path
            let altBinaryPath = (buildPath as NSString)
                .appendingPathComponent("debug/\(packageName)PackageTests")
            guard FileManager.default.fileExists(atPath: altBinaryPath) else {
                throw Mutate4SwiftError.coverageDataUnavailable
            }
            return try exportCoverage(binaryPath: altBinaryPath, profdataPath: profdataPath)
        }

        return try exportCoverage(binaryPath: binaryPath, profdataPath: profdataPath)
    }

    func exportCoverage(binaryPath: String, profdataPath: String) throws -> String {
        let outputPath = NSTemporaryDirectory() + "mutate4swift_coverage.json"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "llvm-cov", "export", "-format=text",
            "-instr-profile=\(profdataPath)",
            binaryPath,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Mutate4SwiftError.coverageDataUnavailable
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try data.write(to: URL(fileURLWithPath: outputPath))

        return outputPath
    }

    func parseCoverage(codecovPath: String, filePath: String) throws -> Set<Int> {
        let coverageByFile = try parseCoverageMap(codecovPath: codecovPath)
        let resolvedPath = (filePath as NSString).standardizingPath
        return coverageByFile[resolvedPath] ?? []
    }

    func parseCoverageMap(codecovPath: String) throws -> [String: Set<Int>] {
        let data = try Data(contentsOf: URL(fileURLWithPath: codecovPath))

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw Mutate4SwiftError.coverageDataUnavailable
        }

        var linesByFile: [String: Set<Int>] = [:]

        for entry in dataArray {
            guard let files = entry["files"] as? [[String: Any]] else { continue }
            for file in files {
                guard let filename = file["filename"] as? String,
                      let segments = file["segments"] as? [[Any]] else { continue }
                let normalizedFilename = (filename as NSString).standardizingPath

                for segment in segments {
                    guard segment.count >= 5,
                          let line = segment[0] as? Int,
                          let count = segment[2] as? Int else { continue }
                    if count > 0 {
                        linesByFile[normalizedFilename, default: []].insert(line)
                    }
                }
            }
        }

        return linesByFile
    }
}
