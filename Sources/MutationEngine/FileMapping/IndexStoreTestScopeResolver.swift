import Foundation
import IndexStoreDB

protocol IndexStoreTestScopeResolving: Sendable {
    func resolveTestFilter(forSourceFile sourceFile: String) -> String?
}

final class IndexStoreTestScopeResolver: IndexStoreTestScopeResolving, @unchecked Sendable {
    static let shared = IndexStoreTestScopeResolver()

    private enum CachedFilter {
        case scope(String)
        case noScope
    }

    private struct PackageContext {
        var cachedFilters: [String: CachedFilter] = [:]
        var indexStorePath: String?
        var indexDatabasePath: String?
        var library: IndexStoreLibrary?
        var index: IndexStoreDB?
        var attemptedBootstrapBuild = false
        var attemptedRefreshBuild = false
    }

    private struct IndexStoreCandidate {
        let path: String
        let modifiedAt: Date
    }

    private let fileManager: FileManager
    private let forcedIndexStoreLibraryPath: String?
    private let allowAutomaticLibraryResolution: Bool

    private let lock = NSLock()
    private var contexts: [String: PackageContext] = [:]

    init(
        fileManager: FileManager = .default,
        forcedIndexStoreLibraryPath: String? = nil,
        allowAutomaticLibraryResolution: Bool = true
    ) {
        self.fileManager = fileManager
        self.forcedIndexStoreLibraryPath = forcedIndexStoreLibraryPath
        self.allowAutomaticLibraryResolution = allowAutomaticLibraryResolution
    }

    func resolveTestFilter(forSourceFile sourceFile: String) -> String? {
        let normalizedSourcePath = standardizedPath(sourceFile)
        guard let packagePath = packagePath(forSourceFile: normalizedSourcePath) else {
            return nil
        }
        let normalizedPackagePath = standardizedPath(packagePath)

        lock.lock()
        defer { lock.unlock() }

        var context = contexts[normalizedPackagePath] ?? PackageContext()
        if let cached = context.cachedFilters[normalizedSourcePath] {
            contexts[normalizedPackagePath] = context
            switch cached {
            case .scope(let scope):
                return scope
            case .noScope:
                return nil
            }
        }

        guard prepareContext(
            &context,
            packagePath: normalizedPackagePath,
            sourceFile: normalizedSourcePath
        ) else {
            context.cachedFilters[normalizedSourcePath] = .noScope
            contexts[normalizedPackagePath] = context
            return nil
        }

        let filter = buildScopeFilter(
            sourceFile: normalizedSourcePath,
            packagePath: normalizedPackagePath,
            index: context.index
        )
        context.cachedFilters[normalizedSourcePath] = filter.map(CachedFilter.scope) ?? .noScope
        contexts[normalizedPackagePath] = context
        return filter
    }

    private func prepareContext(
        _ context: inout PackageContext,
        packagePath: String,
        sourceFile: String
    ) -> Bool {
        if context.indexStorePath == nil {
            context.indexStorePath = discoverIndexStorePath(in: packagePath)
        }

        if context.indexStorePath == nil, !context.attemptedBootstrapBuild {
            context.attemptedBootstrapBuild = true
            _ = runSwiftBuild(packagePath: packagePath)
            context.indexStorePath = discoverIndexStorePath(in: packagePath)
        }

        guard let indexStorePath = context.indexStorePath else {
            return false
        }

        guard openIndexIfNeeded(
            &context,
            packagePath: packagePath,
            indexStorePath: indexStorePath
        ) else {
            return false
        }

        refreshIndexIfNeeded(
            &context,
            packagePath: packagePath,
            sourceFile: sourceFile
        )
        return context.index != nil
    }

    private func openIndexIfNeeded(
        _ context: inout PackageContext,
        packagePath: String,
        indexStorePath: String
    ) -> Bool {
        if context.index != nil {
            return true
        }

        guard let library = resolveLibrary(&context) else {
            return false
        }

        let databasePath = (packagePath as NSString)
            .appendingPathComponent(".mutate4swift/indexdb")
        do {
            try fileManager.createDirectory(
                atPath: databasePath,
                withIntermediateDirectories: true
            )
            context.indexDatabasePath = databasePath
            context.index = try IndexStoreDB(
                storePath: indexStorePath,
                databasePath: databasePath,
                library: library,
                waitUntilDoneInitializing: true
            )
            return true
        } catch {
            context.index = nil
            return false
        }
    }

    private func refreshIndexIfNeeded(
        _ context: inout PackageContext,
        packagePath: String,
        sourceFile: String
    ) {
        guard let index = context.index else {
            return
        }
        guard !context.attemptedRefreshBuild else {
            return
        }
        guard sourceNeedsRefresh(sourceFile: sourceFile, index: index) else {
            return
        }

        context.attemptedRefreshBuild = true
        guard runSwiftBuild(packagePath: packagePath) else {
            return
        }

        if let refreshedIndexStorePath = discoverIndexStorePath(in: packagePath) {
            context.indexStorePath = refreshedIndexStorePath
        }
        guard let indexStorePath = context.indexStorePath else {
            return
        }

        context.index = nil
        guard openIndexIfNeeded(
            &context,
            packagePath: packagePath,
            indexStorePath: indexStorePath
        ) else {
            return
        }
        context.index?.pollForUnitChangesAndWait()
    }

    private func resolveLibrary(_ context: inout PackageContext) -> IndexStoreLibrary? {
        if let library = context.library {
            return library
        }

        guard let dylibPath = resolveIndexStoreLibraryPath() else {
            return nil
        }

        do {
            let library = try IndexStoreLibrary(dylibPath: dylibPath)
            context.library = library
            return library
        } catch {
            return nil
        }
    }

    private func resolveIndexStoreLibraryPath() -> String? {
        if let forcedIndexStoreLibraryPath {
            return fileManager.fileExists(atPath: forcedIndexStoreLibraryPath)
                ? forcedIndexStoreLibraryPath
                : nil
        }

        let environment = ProcessInfo.processInfo.environment
        if let toolchainDir = environment["TOOLCHAIN_DIR"] {
            let candidate = URL(fileURLWithPath: toolchainDir, isDirectory: true)
                .appendingPathComponent("usr/lib/libIndexStore.dylib")
                .path
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }

        guard allowAutomaticLibraryResolution else {
            return nil
        }

        guard let swiftcPath = runXcrunFindSwiftc() else {
            return nil
        }

        let candidate = URL(fileURLWithPath: swiftcPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lib/libIndexStore.dylib")
            .path

        return fileManager.fileExists(atPath: candidate) ? candidate : nil
    }

    private func runXcrunFindSwiftc() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swiftc"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return output.isEmpty ? nil : output
    }

    private func runSwiftBuild(packagePath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["build", "--package-path", packagePath, "--build-tests"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func sourceNeedsRefresh(sourceFile: String, index: IndexStoreDB) -> Bool {
        guard let sourceDate = sourceModificationDate(path: sourceFile) else {
            return false
        }

        guard let latestIndexedUnit = index.dateOfLatestUnitFor(filePath: sourceFile) else {
            return true
        }

        return sourceDate > latestIndexedUnit
    }

    private func sourceModificationDate(path: String) -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return modificationDate
    }

    private func buildScopeFilter(
        sourceFile: String,
        packagePath: String,
        index: IndexStoreDB?
    ) -> String? {
        guard let index else {
            return nil
        }

        var mainFiles = index.mainFilesContainingFile(path: sourceFile)
            .map(standardizedPath)

        if mainFiles.isEmpty {
            mainFiles = [sourceFile]
        }

        let normalizedMainFiles = Array(Set(mainFiles)).sorted()
        let testOccurrences = index.unitTests(referencedByMainFiles: normalizedMainFiles)

        let packagePrefix = packagePath.hasSuffix("/") ? packagePath : packagePath + "/"
        var testTargets = Set<String>()
        for occurrence in testOccurrences {
            let testPath = standardizedPath(occurrence.location.path)
            guard testPath.hasPrefix(packagePrefix),
                  let target = testTargetName(for: testPath) else {
                continue
            }
            testTargets.insert(target)
        }

        guard !testTargets.isEmpty else {
            return nil
        }

        let sortedTargets = testTargets.sorted()
        if sortedTargets.count == 1 {
            return sortedTargets[0]
        }

        let escapedTargets = sortedTargets.map(NSRegularExpression.escapedPattern(for:))
        return "^(\(escapedTargets.joined(separator: "|")))\\."
    }

    private func testTargetName(for testFilePath: String) -> String? {
        let components = URL(fileURLWithPath: testFilePath).pathComponents
        guard let testsIndex = components.firstIndex(of: "Tests"),
              testsIndex + 1 < components.count else {
            return nil
        }

        let targetName = components[testsIndex + 1]
        return targetName.isEmpty ? nil : targetName
    }

    private func discoverIndexStorePath(in packagePath: String) -> String? {
        let buildURL = URL(fileURLWithPath: packagePath)
            .appendingPathComponent(".build", isDirectory: true)
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: buildURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                at: buildURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var candidates: [IndexStoreCandidate] = []
        for case let candidateURL as URL in enumerator {
            guard candidateURL.lastPathComponent == "store",
                  candidateURL.deletingLastPathComponent().lastPathComponent == "index" else {
                continue
            }

            let resourceValues = try? candidateURL.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            )
            guard resourceValues?.isDirectory == true else {
                continue
            }

            candidates.append(
                IndexStoreCandidate(
                    path: candidateURL.path,
                    modifiedAt: resourceValues?.contentModificationDate ?? .distantPast
                )
            )
        }

        guard !candidates.isEmpty else {
            return nil
        }

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.path < rhs.path
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }

        return sorted[0].path
    }

    private func packagePath(forSourceFile sourceFile: String) -> String? {
        let sourceURL = URL(fileURLWithPath: sourceFile).standardizedFileURL
        var current = sourceURL.deletingLastPathComponent()

        while current.path != "/" {
            let packageSwift = current.appendingPathComponent("Package.swift").path
            if fileManager.fileExists(atPath: packageSwift) {
                return current.path
            }
            current = current.deletingLastPathComponent()
        }

        return nil
    }

    private func standardizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
