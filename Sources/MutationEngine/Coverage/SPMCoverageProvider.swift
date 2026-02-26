import Foundation

public final class SPMCoverageProvider: CoverageProvider, @unchecked Sendable {
    private struct PersistentCoverageCache: Codable {
        let linesByFile: [String: [Int]]
    }

    private let verbose: Bool
    private let cacheLock = NSLock()
    private var coverageByPackageCache: [String: [String: Set<Int>]] = [:]

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    public func coveredLines(forFile filePath: String, packagePath: String) throws -> Set<Int> {
        let normalizedPackagePath = (packagePath as NSString).standardizingPath
        let normalizedFilePath = (filePath as NSString).standardizingPath
        let buildPath = (normalizedPackagePath as NSString).appendingPathComponent(".build")

        cacheLock.lock()
        if let cachedCoverage = coverageByPackageCache[normalizedPackagePath] {
            let lines = cachedCoverage[normalizedFilePath] ?? []
            cacheLock.unlock()
            return lines
        }
        cacheLock.unlock()

        if let cacheKey = coverageCacheKey(buildPath: buildPath),
           let persistedCoverage = try? loadPersistentCoverage(
               packagePath: normalizedPackagePath,
               cacheKey: cacheKey
           ) {
            cacheLock.lock()
            coverageByPackageCache[normalizedPackagePath] = persistedCoverage
            let lines = persistedCoverage[normalizedFilePath] ?? []
            cacheLock.unlock()
            return lines
        }

        // Run swift test with coverage enabled
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        buildProcess.arguments = ["test", "--package-path", normalizedPackagePath, "--enable-code-coverage"]
        buildProcess.standardOutput = FileHandle.nullDevice
        buildProcess.standardError = FileHandle.nullDevice

        try buildProcess.run()
        buildProcess.waitUntilExit()

        guard buildProcess.terminationStatus == 0 else {
            throw Mutate4SwiftError.coverageDataUnavailable
        }

        // Find the profdata and binary
        let codecovPath = try findCodecovJSON(buildPath: buildPath, packagePath: normalizedPackagePath)
        let coverageByFile = try parseCoverageMap(codecovPath: codecovPath)

        cacheLock.lock()
        coverageByPackageCache[normalizedPackagePath] = coverageByFile
        let lines = coverageByFile[normalizedFilePath] ?? []
        cacheLock.unlock()

        if let cacheKey = coverageCacheKey(buildPath: buildPath) {
            try? savePersistentCoverage(
                packagePath: normalizedPackagePath,
                cacheKey: cacheKey,
                coverageByFile: coverageByFile
            )
        }

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
        let outputPath = NSTemporaryDirectory() + "mutate4swift_coverage_\(UUID().uuidString).json"
        let outputURL = URL(fileURLWithPath: outputPath)
        let fileManager = FileManager.default
        _ = fileManager.createFile(atPath: outputPath, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "llvm-cov", "export", "-format=text",
            "-instr-profile=\(profdataPath)",
            binaryPath,
        ]
        process.standardOutput = outputHandle
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Mutate4SwiftError.coverageDataUnavailable
        }

        return outputPath
    }

    func coverageCacheKey(buildPath: String) -> String? {
        let profdataPath = (buildPath as NSString)
            .appendingPathComponent("debug/codecov/default.profdata")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: profdataPath),
              let modificationDate = attributes[.modificationDate] as? Date,
              let sizeNumber = attributes[.size] as? NSNumber else {
            return nil
        }

        let mtimeMillis = Int64((modificationDate.timeIntervalSince1970 * 1000).rounded())
        return "prof-\(sizeNumber.int64Value)-\(mtimeMillis)"
    }

    func loadPersistentCoverage(
        packagePath: String,
        cacheKey: String
    ) throws -> [String: Set<Int>] {
        let cachePath = persistentCoverageCachePath(
            packagePath: packagePath,
            cacheKey: cacheKey
        )
        guard FileManager.default.fileExists(atPath: cachePath) else {
            throw Mutate4SwiftError.coverageDataUnavailable
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: cachePath))
        let decoded = try JSONDecoder().decode(PersistentCoverageCache.self, from: data)
        return decoded.linesByFile.reduce(into: [String: Set<Int>]()) { partial, entry in
            partial[entry.key] = Set(entry.value)
        }
    }

    func savePersistentCoverage(
        packagePath: String,
        cacheKey: String,
        coverageByFile: [String: Set<Int>]
    ) throws {
        let cacheDirectory = persistentCoverageCacheDirectory(packagePath: packagePath)
        try FileManager.default.createDirectory(
            atPath: cacheDirectory,
            withIntermediateDirectories: true
        )

        let serializable = PersistentCoverageCache(
            linesByFile: coverageByFile.reduce(into: [String: [Int]]()) { partial, entry in
                partial[entry.key] = entry.value.sorted()
            }
        )
        let data = try JSONEncoder().encode(serializable)
        let cachePath = persistentCoverageCachePath(
            packagePath: packagePath,
            cacheKey: cacheKey
        )
        try data.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
    }

    func persistentCoverageCacheDirectory(packagePath: String) -> String {
        (packagePath as NSString)
            .appendingPathComponent(".mutate4swift/cache/coverage")
    }

    func persistentCoverageCachePath(packagePath: String, cacheKey: String) -> String {
        (persistentCoverageCacheDirectory(packagePath: packagePath) as NSString)
            .appendingPathComponent("\(cacheKey).json")
    }

    func parseCoverage(codecovPath: String, filePath: String) throws -> Set<Int> {
        let coverageByFile = try parseCoverageMap(codecovPath: codecovPath)
        let resolvedPath = (filePath as NSString).standardizingPath
        return coverageByFile[resolvedPath] ?? []
    }

    func parseCoverageMap(codecovPath: String) throws -> [String: Set<Int>] {
        let data = try Data(contentsOf: URL(fileURLWithPath: codecovPath))
        let dataArray = try decodeCoverageEntries(from: data)
        var linesByFile: [String: Set<Int>] = [:]

        for entry in dataArray {
            appendCoveredLines(from: entry, into: &linesByFile)
        }

        return linesByFile
    }

    private func decodeCoverageEntries(from data: Data) throws -> [[String: Any]] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw Mutate4SwiftError.coverageDataUnavailable
        }
        return dataArray
    }

    private func appendCoveredLines(
        from entry: [String: Any],
        into linesByFile: inout [String: Set<Int>]
    ) {
        guard let files = entry["files"] as? [[String: Any]] else {
            return
        }

        for file in files {
            guard let payload = extractFileCoveragePayload(file) else {
                continue
            }
            ingestCoveredSegments(
                payload.segments,
                normalizedFilename: payload.normalizedFilename,
                into: &linesByFile
            )
        }
    }

    private func extractFileCoveragePayload(
        _ file: [String: Any]
    ) -> (normalizedFilename: String, segments: [[Any]])? {
        guard let filename = file["filename"] as? String,
              let segments = file["segments"] as? [[Any]] else {
            return nil
        }

        return ((filename as NSString).standardizingPath, segments)
    }

    private func ingestCoveredSegments(
        _ segments: [[Any]],
        normalizedFilename: String,
        into linesByFile: inout [String: Set<Int>]
    ) {
        for segment in segments {
            guard let coveredLine = parseCoveredSegmentLine(segment) else {
                continue
            }
            linesByFile[normalizedFilename, default: []].insert(coveredLine)
        }
    }

    private func parseCoveredSegmentLine(_ segment: [Any]) -> Int? {
        guard segment.count >= 5,
              let line = segment[0] as? Int,
              let count = segment[2] as? Int,
              count > 0 else {
            return nil
        }

        return line
    }

}
