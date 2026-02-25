import Foundation

public final class Orchestrator: @unchecked Sendable {
    private let testRunner: TestRunner
    private let coverageProvider: CoverageProvider?
    private let verbose: Bool
    private let timeoutMultiplier: Double

    public init(
        testRunner: TestRunner,
        coverageProvider: CoverageProvider? = nil,
        verbose: Bool = false,
        timeoutMultiplier: Double = 10.0
    ) {
        self.testRunner = testRunner
        self.coverageProvider = coverageProvider
        self.verbose = verbose
        self.timeoutMultiplier = timeoutMultiplier
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

        // Step 1: Recovery — restore stale backup if present
        if fileManager.hasStaleBackup {
            if verbose { print("Restoring stale backup from interrupted run...") }
            fileManager.restoreIfNeeded()
        }

        // Step 2: Read and parse source
        let originalSource = try fileManager.backup()

        // Step 3: Discover mutation sites
        let discoverer = MutationDiscoverer(source: originalSource, fileName: sourceFile)
        var sites = discoverer.discoverSites()

        if verbose { print("Discovered \(sites.count) potential mutation sites") }

        // Step 4: Filter equivalent mutations
        let equivalentFilter = EquivalentMutationFilter()
        sites = equivalentFilter.filter(sites, source: originalSource)

        if verbose { print("After equivalent filter: \(sites.count) sites") }

        // Step 5: Filter by lines (if specified)
        if let lines = lines {
            sites = sites.filter { lines.contains($0.line) }
            if verbose { print("After line filter: \(sites.count) sites") }
        }

        // Step 6: Filter by coverage (if enabled)
        if let coverageProvider = coverageProvider {
            do {
                let covered = try coverageProvider.coveredLines(forFile: sourceFile, packagePath: packagePath)
                sites = sites.filter { covered.contains($0.line) }
                if verbose { print("After coverage filter: \(sites.count) sites") }
            } catch {
                if verbose { print("Warning: Could not load coverage data: \(error)") }
            }
        }

        // Step 7: Run baseline
        let autoFilter = resolvedTestFilter ?? testFilter ?? TestFileMapper().testFilter(forSourceFile: sourceFile)
        let baseline: BaselineResult
        if let baselineOverride {
            baseline = baselineOverride
            if verbose {
                print("Using cached baseline (\(String(format: "%.2f", baseline.duration))s, timeout: \(String(format: "%.2f", baseline.timeout))s)")
            }
        } else if let baselineRunner = testRunner as? BaselineCapableTestRunner {
            if verbose { print("Running baseline tests...") }
            let rawBaseline = try baselineRunner.runBaseline(packagePath: packagePath, filter: autoFilter)
            baseline = BaselineResult(duration: rawBaseline.duration, timeoutMultiplier: timeoutMultiplier)
        } else {
            if verbose { print("Running baseline tests...") }
            let start = Date()
            let result = try testRunner.runTests(packagePath: packagePath, filter: autoFilter, timeout: 600)
            let duration = Date().timeIntervalSince(start)
            guard result == .passed else {
                if result == .noTests {
                    throw Mutate4SwiftError.noTestsExecuted(autoFilter)
                }
                throw Mutate4SwiftError.baselineTestsFailed
            }
            baseline = BaselineResult(duration: duration, timeoutMultiplier: timeoutMultiplier)
        }

        if verbose { print("Baseline passed in \(String(format: "%.2f", baseline.duration))s, timeout: \(String(format: "%.2f", baseline.timeout))s") }

        // Step 8: Mutation loop
        let applicator = MutationApplicator()
        var results: [MutationResult] = []

        for (index, site) in sites.enumerated() {
            if verbose {
                print("[\(index + 1)/\(sites.count)] Testing \(site.mutationOperator.description): \"\(site.originalText)\" → \"\(site.mutatedText)\" (line \(site.line))")
            }

            // Apply mutation
            let mutatedSource = applicator.apply(site, to: originalSource)
            try fileManager.writeMutated(mutatedSource)

            // Run tests
            let testResult: TestRunResult
            do {
                testResult = try testRunner.runTests(
                    packagePath: packagePath,
                    filter: autoFilter,
                    timeout: baseline.timeout
                )
            } catch {
                // If running tests fails entirely, classify as build error
                testResult = .buildError
            }

            // Classify
            let outcome: MutationOutcome
            switch testResult {
            case .passed:
                outcome = .survived
            case .failed:
                outcome = .killed
            case .timeout:
                outcome = .timeout
            case .buildError:
                outcome = .buildError
            case .noTests:
                if verbose {
                    print("  → NO_TESTS (classifying as BUILD_ERROR)")
                }
                outcome = .buildError
            }

            results.append(MutationResult(site: site, outcome: outcome))

            if verbose {
                print("  → \(outcome.rawValue.uppercased())")
            }
        }

        // Step 9: Restore original
        try fileManager.restore()

        return MutationReport(
            results: results,
            sourceFile: sourceFile,
            baselineDuration: baseline.duration
        )
    }
}
