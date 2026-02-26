import Foundation
import IndexStoreDB

protocol IndexStoreTestScopeResolving: Sendable {
    func resolveTestFilter(forSourceFile sourceFile: String) async -> String?
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

    private actor PackageResolverActor {
        private let packagePath: String
        private unowned let resolver: IndexStoreTestScopeResolver
        private var context = PackageContext()

        init(packagePath: String, resolver: IndexStoreTestScopeResolver) {
            self.packagePath = packagePath
            self.resolver = resolver
        }

        func resolve(sourceFileCandidates: [String], normalizedSourcePath: String) -> String? {
            if let cached = context.cachedFilters[normalizedSourcePath] {
                switch cached {
                case .scope(let scope):
                    return scope
                case .noScope:
                    return nil
                }
            }

            guard resolver.prepareContext(
                &context,
                packagePath: packagePath,
                sourceFileCandidates: sourceFileCandidates
            ) else {
                context.cachedFilters[normalizedSourcePath] = .noScope
                return nil
            }

            let filter = resolver.buildScopeFilter(
                sourceFileCandidates: sourceFileCandidates,
                sourceFileCandidateSet: Set(sourceFileCandidates),
                packagePath: packagePath,
                index: context.index
            )
            context.cachedFilters[normalizedSourcePath] = filter.map(CachedFilter.scope) ?? .noScope
            return filter
        }
    }

    private let fileManager: FileManager
    private let forcedIndexStoreLibraryPath: String?
    private let allowAutomaticLibraryResolution: Bool

    private let lock = NSLock()
    private var packageResolvers: [String: PackageResolverActor] = [:]

    init(
        fileManager: FileManager = .default,
        forcedIndexStoreLibraryPath: String? = nil,
        allowAutomaticLibraryResolution: Bool = true
    ) {
        self.fileManager = fileManager
        self.forcedIndexStoreLibraryPath = forcedIndexStoreLibraryPath
        self.allowAutomaticLibraryResolution = allowAutomaticLibraryResolution
    }

    func resolveTestFilter(forSourceFile sourceFile: String) async -> String? {
        let sourcePathCandidates = lookupPathCandidates(for: sourceFile)
        guard let normalizedSourcePath = sourcePathCandidates.first,
              let packagePath = packagePath(forSourceFile: normalizedSourcePath) else {
            return nil
        }
        let normalizedPackagePath = standardizedPath(packagePath)
        let resolver = packageResolver(for: normalizedPackagePath)
        return await resolver.resolve(
            sourceFileCandidates: sourcePathCandidates,
            normalizedSourcePath: normalizedSourcePath
        )
    }

    private func packageResolver(for packagePath: String) -> PackageResolverActor {
        lock.lock()
        defer { lock.unlock() }

        if let existing = packageResolvers[packagePath] {
            return existing
        }

        let created = PackageResolverActor(packagePath: packagePath, resolver: self)
        packageResolvers[packagePath] = created
        return created
    }

    private func prepareContext(
        _ context: inout PackageContext,
        packagePath: String,
        sourceFileCandidates: [String]
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
            sourceFileCandidates: sourceFileCandidates
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
        sourceFileCandidates: [String]
    ) {
        guard let index = context.index else {
            return
        }
        guard !context.attemptedRefreshBuild else {
            return
        }
        guard sourceNeedsRefresh(sourceFileCandidates: sourceFileCandidates, index: index) else {
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

    private func sourceNeedsRefresh(sourceFileCandidates: [String], index: IndexStoreDB) -> Bool {
        guard let sourceDate = sourceModificationDate(paths: sourceFileCandidates) else {
            return false
        }

        let latestIndexedUnit = sourceFileCandidates
            .compactMap { index.dateOfLatestUnitFor(filePath: $0) }
            .max()

        guard let latestIndexedUnit else {
            return true
        }

        return sourceDate > latestIndexedUnit
    }

    private func sourceModificationDate(paths: [String]) -> Date? {
        for path in paths {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let modificationDate = attributes[.modificationDate] as? Date else {
                continue
            }
            return modificationDate
        }
        return nil
    }

    private func buildScopeFilter(
        sourceFileCandidates: [String],
        sourceFileCandidateSet: Set<String>,
        packagePath: String,
        index: IndexStoreDB?
    ) -> String? {
        guard let index else {
            return nil
        }

        let packagePrefixes = packagePathPrefixes(for: packagePath)
        var normalizedPathCache: [String: String] = [:]
        var testTargetCache: [String: String?] = [:]

        func normalizedPath(_ rawPath: String) -> String {
            if let cached = normalizedPathCache[rawPath] {
                return cached
            }
            let normalized = standardizedPath(rawPath)
            normalizedPathCache[rawPath] = normalized
            return normalized
        }

        func cachedTestTarget(for normalizedPath: String) -> String? {
            if let cached = testTargetCache[normalizedPath] {
                return cached
            }
            let target = testTargetName(for: normalizedPath)
            testTargetCache[normalizedPath] = target
            return target
        }

        let normalizedMainFiles = normalizedMainFiles(
            sourceFileCandidates: sourceFileCandidates,
            index: index,
            normalizedPath: normalizedPath
        )
        let testOccurrences = index.unitTests(referencedByMainFiles: normalizedMainFiles)

        var testTargets = targetsFromOccurrencesWithinPackage(
            testOccurrences,
            packagePrefixes: packagePrefixes,
            normalizedPath: normalizedPath,
            cachedTestTarget: cachedTestTarget
        )

        if testTargets.isEmpty {
            testTargets = targetsFromOccurrences(
                testOccurrences,
                normalizedPath: normalizedPath,
                cachedTestTarget: cachedTestTarget
            )
        }

        if testTargets.isEmpty {
            testTargets = targetsFromSymbolReferences(
                sourceFileCandidates: sourceFileCandidates,
                sourceFileCandidateSet: sourceFileCandidateSet,
                packagePath: packagePath,
                index: index
            )
        }

        return scopeFilterPattern(for: testTargets)
    }

    private func testTargetName(for testFilePath: String) -> String? {
        guard let testsRange = testFilePath.range(of: "/Tests/") else {
            return nil
        }

        let remaining = testFilePath[testsRange.upperBound...]
        guard let slashIndex = remaining.firstIndex(of: "/"), slashIndex > remaining.startIndex else {
            return nil
        }

        let targetName = remaining[..<slashIndex]
        return targetName.isEmpty ? nil : String(targetName)
    }

    private func targetsFromSymbolReferences(
        sourceFileCandidates: [String],
        sourceFileCandidateSet: Set<String>,
        packagePath: String,
        index: IndexStoreDB
    ) -> Set<String> {
        let packagePrefixes = packagePathPrefixes(for: packagePath)
        var normalizedPathCache: [String: String] = [:]
        var testTargetCache: [String: String?] = [:]

        func normalizedPath(_ rawPath: String) -> String {
            if let cached = normalizedPathCache[rawPath] {
                return cached
            }
            let normalized = standardizedPath(rawPath)
            normalizedPathCache[rawPath] = normalized
            return normalized
        }

        func cachedTestTarget(for normalizedPath: String) -> String? {
            if let cached = testTargetCache[normalizedPath] {
                return cached
            }
            let target = testTargetName(for: normalizedPath)
            testTargetCache[normalizedPath] = target
            return target
        }

        let symbols = definedSymbolUSRs(
            sourceFileCandidates: sourceFileCandidates,
            index: index
        )
        guard !symbols.isEmpty else {
            return []
        }

        return targetsFromSymbolReferences(
            symbols: symbols,
            sourceFileCandidateSet: sourceFileCandidateSet,
            packagePrefixes: packagePrefixes,
            index: index,
            normalizedPath: normalizedPath,
            cachedTestTarget: cachedTestTarget
        )
    }

    private func normalizedMainFiles(
        sourceFileCandidates: [String],
        index: IndexStoreDB,
        normalizedPath: (String) -> String
    ) -> [String] {
        var mainFiles: [String] = []
        for sourceFile in sourceFileCandidates {
            mainFiles.append(
                contentsOf: index.mainFilesContainingFile(path: sourceFile).map(normalizedPath)
            )
        }

        if mainFiles.isEmpty {
            return sourceFileCandidates
        }

        return Array(Set(mainFiles)).sorted()
    }

    private func targetsFromOccurrencesWithinPackage(
        _ occurrences: [SymbolOccurrence],
        packagePrefixes: [String],
        normalizedPath: (String) -> String,
        cachedTestTarget: (String) -> String?
    ) -> Set<String> {
        var testTargets = Set<String>()
        for occurrence in occurrences {
            let testPath = normalizedPath(occurrence.location.path)
            guard isPath(testPath, underAnyPrefix: packagePrefixes),
                  let target = cachedTestTarget(testPath) else {
                continue
            }
            testTargets.insert(target)
        }
        return testTargets
    }

    private func targetsFromOccurrences(
        _ occurrences: [SymbolOccurrence],
        normalizedPath: (String) -> String,
        cachedTestTarget: (String) -> String?
    ) -> Set<String> {
        var testTargets = Set<String>()
        for occurrence in occurrences {
            let testPath = normalizedPath(occurrence.location.path)
            guard let target = cachedTestTarget(testPath) else {
                continue
            }
            testTargets.insert(target)
        }
        return testTargets
    }

    private func scopeFilterPattern(for testTargets: Set<String>) -> String? {
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

    private func definedSymbolUSRs(
        sourceFileCandidates: [String],
        index: IndexStoreDB
    ) -> Set<String> {
        var symbols = Set<String>()
        for sourceFile in sourceFileCandidates {
            for occurrence in index.symbolOccurrences(inFilePath: sourceFile) where
                occurrence.roles.contains(.definition) || occurrence.roles.contains(.declaration)
            {
                symbols.insert(occurrence.symbol.usr)
            }
        }
        return symbols
    }

    private func targetsFromSymbolReferences(
        symbols: Set<String>,
        sourceFileCandidateSet: Set<String>,
        packagePrefixes: [String],
        index: IndexStoreDB,
        normalizedPath: (String) -> String,
        cachedTestTarget: (String) -> String?
    ) -> Set<String> {
        var targets = Set<String>()
        let referenceRoles: SymbolRole = [.reference, .call, .read, .write]
        for usr in symbols {
            let occurrences = index.occurrences(ofUSR: usr, roles: referenceRoles)
            for occurrence in occurrences {
                let candidatePath = normalizedPath(occurrence.location.path)
                guard !sourceFileCandidateSet.contains(candidatePath) else {
                    continue
                }
                guard let target = referencedTestTarget(
                    candidatePath: candidatePath,
                    packagePrefixes: packagePrefixes,
                    cachedTestTarget: cachedTestTarget
                ) else {
                    continue
                }
                targets.insert(target)
            }
        }
        return targets
    }

    private func referencedTestTarget(
        candidatePath: String,
        packagePrefixes: [String],
        cachedTestTarget: (String) -> String?
    ) -> String? {
        if isPath(candidatePath, underAnyPrefix: packagePrefixes),
           let target = cachedTestTarget(candidatePath) {
            return target
        }

        return cachedTestTarget(candidatePath)
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
        let sourceURL = URL(fileURLWithPath: sourceFile)
            .standardizedFileURL
            .resolvingSymlinksInPath()
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
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func packagePathPrefixes(for packagePath: String) -> [String] {
        let normalized = packagePath.hasSuffix("/") ? packagePath : packagePath + "/"
        var prefixes: [String] = [normalized]

        if normalized.hasPrefix("/private/") {
            let withoutPrivate = String(normalized.dropFirst("/private".count))
            if !withoutPrivate.isEmpty {
                prefixes.append(withoutPrivate)
            }
        } else if normalized.hasPrefix("/var/") {
            prefixes.append("/private" + normalized)
        }

        return prefixes
    }

    private func isPath(_ path: String, underAnyPrefix prefixes: [String]) -> Bool {
        prefixes.contains { path.hasPrefix($0) }
    }

    private func lookupPathCandidates(for sourceFile: String) -> [String] {
        var candidates: [String] = []
        let standardizedInput = (sourceFile as NSString).standardizingPath
        let normalizedInput = standardizedPath(sourceFile)

        for path in [normalizedInput, standardizedInput] where !path.isEmpty {
            if !candidates.contains(path) {
                candidates.append(path)
            }
        }

        return candidates
    }
}
