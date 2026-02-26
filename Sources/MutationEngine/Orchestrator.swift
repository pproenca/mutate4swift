import Foundation

public enum OrchestratorProgressEvent: Sendable {
    case candidateSitesDiscovered(count: Int)
    case baselineStarted(filter: String?)
    case baselineFinished(duration: TimeInterval, timeout: TimeInterval)
    case mutationEvaluated(index: Int, total: Int, site: MutationSite, outcome: MutationOutcome)
}

public typealias OrchestratorProgressHandler = (OrchestratorProgressEvent) -> Void

public final class Orchestrator: @unchecked Sendable {
    private let testRunner: TestRunner
    private let coverageProvider: CoverageProvider?
    private let verbose: Bool
    private let timeoutMultiplier: Double
    private let timeoutRetries: Int
    private let buildFirstSampleSize: Int
    private let buildFirstErrorRatio: Double
    private let progressHandler: OrchestratorProgressHandler?

    public init(
        testRunner: TestRunner,
        coverageProvider: CoverageProvider? = nil,
        verbose: Bool = false,
        timeoutMultiplier: Double = 10.0,
        timeoutRetries: Int = 0,
        buildFirstSampleSize: Int = 6,
        buildFirstErrorRatio: Double = 0.5,
        progressHandler: OrchestratorProgressHandler? = nil
    ) {
        self.testRunner = testRunner
        self.coverageProvider = coverageProvider
        self.verbose = verbose
        self.timeoutMultiplier = timeoutMultiplier
        self.timeoutRetries = max(0, timeoutRetries)
        self.buildFirstSampleSize = max(1, buildFirstSampleSize)
        self.buildFirstErrorRatio = max(0, min(1, buildFirstErrorRatio))
        self.progressHandler = progressHandler
    }

    public func run(
        sourceFile: String,
        packagePath: String,
        testFilter: String? = nil,
        lines: Set<Int>? = nil,
        baselineOverride: BaselineResult? = nil,
        resolvedTestFilter: String? = nil
    ) throws -> MutationReport {
        let fileManager = SourceFileManager(filePath: sourceFile)
        restoreStaleBackupIfNeeded(fileManager)

        let originalSource = try fileManager.backup()
        let sites = discoverMutationSites(
            sourceFile: sourceFile,
            packagePath: packagePath,
            originalSource: originalSource,
            lines: lines
        )

        progressHandler?(.candidateSitesDiscovered(count: sites.count))

        if sites.isEmpty {
            if verbose { print("No mutation sites after filters; skipping baseline and test runs") }
            try fileManager.restore()
            return MutationReport(
                results: [],
                sourceFile: sourceFile,
                baselineDuration: 0
            )
        }

        // Step 7: Run baseline
        let autoFilter = resolvedTestFilter ?? testFilter ?? TestFileMapper().testFilter(forSourceFile: sourceFile)
        progressHandler?(.baselineStarted(filter: autoFilter))
        let baseline = try resolveBaseline(
            packagePath: packagePath,
            filter: autoFilter,
            baselineOverride: baselineOverride
        )
        progressHandler?(.baselineFinished(duration: baseline.duration, timeout: baseline.timeout))

        if verbose { print("Baseline passed in \(String(format: "%.2f", baseline.duration))s, timeout: \(String(format: "%.2f", baseline.timeout))s") }

        // Step 8: Mutation loop
        let results = try runMutationLoop(
            sites: sites,
            originalSource: originalSource,
            fileManager: fileManager,
            packagePath: packagePath,
            filter: autoFilter,
            timeout: baseline.timeout
        )

        // Step 9: Restore original
        try fileManager.restore()

        return MutationReport(
            results: results,
            sourceFile: sourceFile,
            baselineDuration: baseline.duration
        )
    }

    private func restoreStaleBackupIfNeeded(_ fileManager: SourceFileManager) {
        guard fileManager.hasStaleBackup else {
            return
        }

        if verbose {
            print("Restoring stale backup from interrupted run...")
        }
        fileManager.restoreIfNeeded()
    }

    private func discoverMutationSites(
        sourceFile: String,
        packagePath: String,
        originalSource: String,
        lines: Set<Int>?
    ) -> [MutationSite] {
        let discoverer = MutationDiscoverer(source: originalSource, fileName: sourceFile)
        var sites = discoverer.discoverSites()

        if verbose { print("Discovered \(sites.count) potential mutation sites") }

        let equivalentFilter = EquivalentMutationFilter()
        sites = equivalentFilter.filter(sites, source: originalSource)

        if verbose { print("After equivalent filter: \(sites.count) sites") }

        if let lines {
            sites = sites.filter { lines.contains($0.line) }
            if verbose { print("After line filter: \(sites.count) sites") }
        }

        guard let coverageProvider else {
            return sites
        }

        do {
            let covered = try coverageProvider.coveredLines(forFile: sourceFile, packagePath: packagePath)
            sites = sites.filter { covered.contains($0.line) }
            if verbose { print("After coverage filter: \(sites.count) sites") }
        } catch {
            if verbose { print("Warning: Could not load coverage data: \(error)") }
        }

        return sites
    }

    private func resolveBaseline(
        packagePath: String,
        filter: String?,
        baselineOverride: BaselineResult?
    ) throws -> BaselineResult {
        if let baselineOverride {
            if verbose {
                print("Using cached baseline (\(String(format: "%.2f", baselineOverride.duration))s, timeout: \(String(format: "%.2f", baselineOverride.timeout))s)")
            }
            return baselineOverride
        }

        if verbose { print("Running baseline tests...") }

        if let baselineRunner = testRunner as? BaselineCapableTestRunner {
            let rawBaseline = try baselineRunner.runBaseline(packagePath: packagePath, filter: filter)
            return BaselineResult(duration: rawBaseline.duration, timeoutMultiplier: timeoutMultiplier)
        }

        let start = Date()
        let result = try testRunner.runTests(packagePath: packagePath, filter: filter, timeout: 600)
        let duration = Date().timeIntervalSince(start)
        guard result == .passed else {
            if result == .noTests {
                throw Mutate4SwiftError.noTestsExecuted(filter)
            }
            throw Mutate4SwiftError.baselineTestsFailed
        }
        return BaselineResult(duration: duration, timeoutMultiplier: timeoutMultiplier)
    }

    private func runMutationLoop(
        sites: [MutationSite],
        originalSource: String,
        fileManager: SourceFileManager,
        packagePath: String,
        filter: String?,
        timeout: TimeInterval
    ) throws -> [MutationResult] {
        let applicator = MutationApplicator()
        var results: [MutationResult] = []
        var processedMutations = 0
        var buildErrorsSeen = 0
        var buildFirstModeEnabled = false
        let splitRunner = testRunner as? BuildSplitCapableTestRunner

        for (index, site) in sites.enumerated() {
            if verbose {
                print("[\(index + 1)/\(sites.count)] Testing \(site.mutationOperator.description): \"\(site.originalText)\" → \"\(site.mutatedText)\" (line \(site.line))")
            }

            let mutatedSource = applicator.apply(site, to: originalSource)
            try fileManager.writeMutated(mutatedSource)

            let testResult = runMutationTests(
                buildFirstModeEnabled: buildFirstModeEnabled,
                splitRunner: splitRunner,
                packagePath: packagePath,
                filter: filter,
                timeout: timeout
            )
            let outcome = classifyMutationOutcome(testResult)

            results.append(MutationResult(site: site, outcome: outcome))
            progressHandler?(
                .mutationEvaluated(
                    index: index + 1,
                    total: sites.count,
                    site: site,
                    outcome: outcome
                )
            )

            if verbose {
                print("  → \(outcome.rawValue.uppercased())")
            }

            processedMutations += 1
            if outcome == .buildError {
                buildErrorsSeen += 1
            }
            buildFirstModeEnabled = updateBuildFirstMode(
                current: buildFirstModeEnabled,
                splitRunner: splitRunner,
                processedMutations: processedMutations,
                buildErrorsSeen: buildErrorsSeen
            )
        }

        return results
    }

    private func runMutationTests(
        buildFirstModeEnabled: Bool,
        splitRunner: BuildSplitCapableTestRunner?,
        packagePath: String,
        filter: String?,
        timeout: TimeInterval
    ) -> TestRunResult {
        guard buildFirstModeEnabled, let splitRunner else {
            return runWithTimeoutRetry {
                try testRunner.runTests(
                    packagePath: packagePath,
                    filter: filter,
                    timeout: timeout
                )
            }
        }

        let buildResult = runWithTimeoutRetry {
            try splitRunner.runBuild(packagePath: packagePath, timeout: timeout)
        }

        switch buildResult {
        case .passed:
            return runWithTimeoutRetry {
                try splitRunner.runTestsWithoutBuild(
                    packagePath: packagePath,
                    filter: filter,
                    timeout: timeout
                )
            }
        case .timeout:
            return .timeout
        case .buildError, .failed, .noTests:
            return .buildError
        }
    }

    private func classifyMutationOutcome(_ testResult: TestRunResult) -> MutationOutcome {
        switch testResult {
        case .passed:
            return .survived
        case .failed:
            return .killed
        case .timeout:
            return .timeout
        case .buildError:
            return .buildError
        case .noTests:
            if verbose {
                print("  → NO_TESTS (classifying as BUILD_ERROR)")
            }
            return .buildError
        }
    }

    private func updateBuildFirstMode(
        current: Bool,
        splitRunner: BuildSplitCapableTestRunner?,
        processedMutations: Int,
        buildErrorsSeen: Int
    ) -> Bool {
        guard !current,
              splitRunner != nil,
              processedMutations >= buildFirstSampleSize else {
            return current
        }

        let ratio = Double(buildErrorsSeen) / Double(processedMutations)
        guard ratio >= buildFirstErrorRatio else {
            return current
        }

        if verbose {
            print(
                "Enabling build-first mode (\(buildErrorsSeen)/\(processedMutations) build errors = \(String(format: "%.2f", ratio * 100))%)"
            )
        }
        return true
    }

    private func runWithTimeoutRetry(action: () throws -> TestRunResult) -> TestRunResult {
        var attempts = 0
        while true {
            let result: TestRunResult
            do {
                result = try action()
            } catch {
                return .buildError
            }

            if result != .timeout {
                return result
            }

            if attempts >= timeoutRetries {
                return .timeout
            }

            attempts += 1
            if verbose {
                print("  ↺ Timeout retry \(attempts)/\(timeoutRetries)")
            }
        }
    }
}
