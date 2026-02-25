import Foundation

/// Maps a source file to its corresponding test file using SPM conventions.
/// E.g., Sources/MyLib/Foo.swift → Tests/MyLibTests/FooTests.swift
public struct TestFileMapper: Sendable {
    public init() {}

    /// Returns a test filter pattern for `swift test --filter` based on the source file.
    public func testFilter(forSourceFile sourceFile: String) -> String? {
        guard let packagePath = packagePath(forSourceFile: sourceFile) else {
            return nil
        }
        guard let mapping = sourceTargetMapping(forSourceFile: sourceFile) else {
            return nil
        }

        if testFile(forSourceFile: sourceFile, packagePath: packagePath) != nil {
            return "\(mapping.fileName)Tests"
        }

        var candidateTargets: [String] = []

        if testTargetContainsTests(
            testTargetName: mapping.conventionalTestTargetName,
            packagePath: packagePath
        ) {
            candidateTargets.append(mapping.conventionalTestTargetName)
        }

        let manifestTargets = manifestBackedTestTargets(
            forSourceTarget: mapping.sourceTargetName,
            packagePath: packagePath
        )
        for target in manifestTargets where testTargetContainsTests(testTargetName: target, packagePath: packagePath) {
            candidateTargets.append(target)
        }

        candidateTargets = uniquePreservingOrder(candidateTargets)
        guard !candidateTargets.isEmpty else {
            return nil
        }

        if candidateTargets.count == 1 {
            return candidateTargets[0]
        }

        let escapedTargets = candidateTargets.map(NSRegularExpression.escapedPattern(for:))
        return "^(\(escapedTargets.joined(separator: "|")))\\."
    }

    /// Returns the expected test file path for a source file.
    public func testFile(forSourceFile sourceFile: String, packagePath: String) -> String? {
        guard let mapping = sourceTargetMapping(forSourceFile: sourceFile) else {
            return nil
        }

        let testPath = (packagePath as NSString)
            .appendingPathComponent("Tests")
            .appending("/\(mapping.conventionalTestTargetName)/\(mapping.fileName)Tests.swift")

        return FileManager.default.fileExists(atPath: testPath) ? testPath : nil
    }

    private func sourceTargetMapping(forSourceFile sourceFile: String) -> (
        fileName: String,
        sourceTargetName: String,
        conventionalTestTargetName: String
    )? {
        let url = URL(fileURLWithPath: sourceFile)
        let fileName = url.deletingPathExtension().lastPathComponent
        guard !fileName.isEmpty else {
            return nil
        }

        // Walk up to find the target directory under Sources/
        let components = url.pathComponents
        guard let sourcesIdx = components.firstIndex(of: "Sources"),
              sourcesIdx + 1 < components.count else {
            return nil
        }

        let targetName = components[sourcesIdx + 1]
        guard !targetName.isEmpty else {
            return nil
        }

        return (fileName, targetName, targetName + "Tests")
    }

    private func manifestBackedTestTargets(forSourceTarget sourceTarget: String, packagePath: String) -> [String] {
        guard let index = PackageTestTargetIndexCache.shared.index(for: packagePath) else {
            return []
        }
        return index.targetsBySourceTarget[sourceTarget] ?? []
    }

    private func testTargetContainsTests(testTargetName: String, packagePath: String) -> Bool {
        let testsPath = (packagePath as NSString).appendingPathComponent("Tests")
        let testTargetPath = (testsPath as NSString).appendingPathComponent(testTargetName)

        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: testTargetPath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(atPath: testTargetPath) else {
            return false
        }

        for case let entry as String in enumerator where entry.hasSuffix(".swift") {
            return true
        }
        return false
    }

    private func packagePath(forSourceFile sourceFile: String) -> String? {
        let sourceURL = URL(fileURLWithPath: sourceFile).standardizedFileURL
        var current = sourceURL.deletingLastPathComponent()

        while current.path != "/" {
            let packageSwift = current.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: packageSwift) {
                return current.path
            }
            current = current.deletingLastPathComponent()
        }

        return nil
    }

    private func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(values.count)

        for value in values where seen.insert(value).inserted {
            result.append(value)
        }

        return result
    }
}

private struct PackageTestTargetIndex: Sendable {
    let targetsBySourceTarget: [String: [String]]
}

private final class PackageTestTargetIndexCache: @unchecked Sendable {
    static let shared = PackageTestTargetIndexCache()

    private let lock = NSLock()
    private var cache: [String: PackageTestTargetIndex] = [:]

    private init() {}

    func index(for packagePath: String) -> PackageTestTargetIndex? {
        let key = (packagePath as NSString).standardizingPath

        lock.lock()
        if let existing = cache[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let loaded = loadIndex(packagePath: key) else {
            return nil
        }

        lock.lock()
        cache[key] = loaded
        lock.unlock()
        return loaded
    }

    private func loadIndex(packagePath: String) -> PackageTestTargetIndex? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["package", "--package-path", packagePath, "dump-package"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let targets = root["targets"] as? [[String: Any]] else {
            return nil
        }

        var mapping: [String: [String]] = [:]

        for target in targets {
            guard let type = target["type"] as? String,
                  type == "test",
                  let testTargetName = target["name"] as? String else {
                continue
            }

            let dependencies = target["dependencies"] as? [[String: Any]] ?? []
            for dependency in dependencies {
                guard let byName = dependency["byName"] as? [Any],
                      let sourceTargetName = byName.first as? String,
                      !sourceTargetName.isEmpty else {
                    continue
                }

                mapping[sourceTargetName, default: []].append(testTargetName)
            }
        }

        let sortedMapping = mapping.mapValues { values in
            Array(Set(values)).sorted()
        }

        return PackageTestTargetIndex(targetsBySourceTarget: sortedMapping)
    }
}
