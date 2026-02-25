import ArgumentParser
import Foundation
import MutationEngine

@main
struct Mutate4Swift: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mutate4swift",
        abstract: "Mutation testing for SwiftPM and Xcode projects",
        version: "0.1.1"
    )

    @Argument(help: "Path to the Swift source file to mutate (omit when using --all)")
    var sourceFile: String?

    @Flag(name: .long, help: "Mutate all Swift source files under Sources/ (SwiftPM mode only)")
    var all: Bool = false

    @Flag(name: .long, help: "Analyze mutation strategy and exit without mutating files")
    var strategyReport: Bool = false

    @Option(name: .long, help: "Number of worker buckets for --all and --strategy-report (default: 1)")
    var jobs: Int = 1

    @Option(name: .long, help: "SPM package root (auto-detected if omitted)")
    var packagePath: String?

    @Option(name: .long, help: "Filter test cases (SPM: swift test --filter, Xcode: only-testing identifier)")
    var testFilter: String?

    @Option(name: .long, help: "Only test mutations on these lines (comma-separated)")
    var lines: String?

    @Option(name: .long, help: "Timeout multiplier (default: 10)")
    var timeoutMultiplier: Double = 10.0

    @Option(name: .long, help: "Retries after timeout before classifying as timeout (default: 1)")
    var timeoutRetries: Int = 1

    @Option(name: .long, help: "Mutation sample size before enabling build-first mode (default: 6)")
    var buildFirstSampleSize: Int = 6

    @Option(name: .long, help: "Build-error ratio threshold to enable build-first mode in [0,1] (default: 0.5)")
    var buildFirstErrorRatio: Double = 0.5

    @Flag(name: .long, help: "Use code coverage to skip untested lines (SwiftPM mode only)")
    var coverage: Bool = false

    @Option(name: .long, help: "Maximum allowed build-error ratio in [0,1] (default: 0.25)")
    var maxBuildErrorRatio: Double = 0.25

    @Flag(name: .long, help: "Require a clean git working tree before mutation runs")
    var requireCleanWorkingTree: Bool = false

    @Flag(name: .long, help: "Disable readiness scorecard output")
    var noReadinessScorecard: Bool = false

    @Option(name: .long, help: "Path to .xcworkspace (enables Xcode runner)")
    var xcodeWorkspace: String?

    @Option(name: .long, help: "Path to .xcodeproj (enables Xcode runner)")
    var xcodeProject: String?

    @Option(name: .long, help: "Xcode scheme for test execution")
    var xcodeScheme: String?

    @Option(name: .long, help: "xcodebuild destination (for example: platform=iOS Simulator,name=iPhone 16)")
    var xcodeDestination: String?

    @Option(name: .long, help: "Xcode test plan name")
    var xcodeTestPlan: String?

    @Option(name: .long, help: "Xcode build configuration (for example: Debug)")
    var xcodeConfiguration: String?

    @Option(name: .long, help: "DerivedData path for xcodebuild")
    var xcodeDerivedDataPath: String?

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    @Flag(name: [.short, .long], help: "Verbose progress output")
    var verbose: Bool = false

    private var usesXcodeRunner: Bool {
        xcodeWorkspace != nil
            || xcodeProject != nil
            || xcodeScheme != nil
            || xcodeDestination != nil
            || xcodeTestPlan != nil
            || xcodeConfiguration != nil
            || xcodeDerivedDataPath != nil
    }

    func validate() throws {
        if all && sourceFile != nil {
            throw ValidationError("Specify either <source-file> or --all, not both.")
        }

        if !all && sourceFile == nil {
            throw ValidationError("Missing <source-file>. Provide a file path or use --all.")
        }

        if all && lines != nil {
            throw ValidationError("--lines can only be used with a single <source-file>.")
        }

        guard (0.0...1.0).contains(maxBuildErrorRatio) else {
            throw ValidationError("--max-build-error-ratio must be in [0,1].")
        }

        guard jobs >= 1 else {
            throw ValidationError("--jobs must be >= 1.")
        }

        guard timeoutRetries >= 0 else {
            throw ValidationError("--timeout-retries must be >= 0.")
        }

        guard buildFirstSampleSize >= 1 else {
            throw ValidationError("--build-first-sample-size must be >= 1.")
        }

        guard (0.0...1.0).contains(buildFirstErrorRatio) else {
            throw ValidationError("--build-first-error-ratio must be in [0,1].")
        }

        if usesXcodeRunner {
            if all {
                throw ValidationError("--all is currently only supported in SwiftPM mode.")
            }

            if coverage {
                throw ValidationError("--coverage is currently only supported in SwiftPM mode.")
            }

            if packagePath != nil {
                throw ValidationError("--package-path cannot be combined with Xcode runner options.")
            }

            if xcodeWorkspace != nil && xcodeProject != nil {
                throw ValidationError("Specify either --xcode-workspace or --xcode-project, not both.")
            }

            if xcodeWorkspace == nil && xcodeProject == nil {
                throw ValidationError("Xcode mode requires --xcode-workspace or --xcode-project.")
            }

            guard let scheme = xcodeScheme, !scheme.isEmpty else {
                throw ValidationError("Xcode mode requires --xcode-scheme.")
            }
        }
    }

    func run() async throws {
        let resolvedSource = resolveSourceFile()
        if !all {
            guard let resolvedSource else {
                throw ValidationError("Missing <source-file>. Provide a file path or use --all.")
            }
            guard FileManager.default.fileExists(atPath: resolvedSource) else {
                throw Mutate4SwiftError.sourceFileNotFound(resolvedSource)
            }
        }

        var scorecard = ReadinessScorecard(
            runnerMode: usesXcodeRunner ? "xcode" : "swiftpm",
            maxBuildErrorRatio: maxBuildErrorRatio,
            allMode: all,
            requireCleanWorkingTree: requireCleanWorkingTree
        )

        defer {
            if !noReadinessScorecard {
                emitReadinessScorecard(scorecard)
            }
        }

        do {
            let executionRoot: String
            let testRunner: TestRunner
            let coverageProvider: CoverageProvider?

            if usesXcodeRunner {
                let xcode = try resolveXcodeInvocation()
                executionRoot = xcode.rootPath
                testRunner = XcodeTestRunner(invocation: xcode.invocation, verbose: verbose)
                coverageProvider = nil
            } else {
                let resolvedPackage = try resolvePackagePath(startingFrom: resolvedSource)
                executionRoot = resolvedPackage
                testRunner = SPMTestRunner(verbose: verbose)
                coverageProvider = coverage ? SPMCoverageProvider(verbose: verbose) : nil
            }

            if requireCleanWorkingTree {
                if isGitWorkingTreeClean(at: executionRoot) {
                    scorecard.workspaceSafetyGate = .passed("Git working tree is clean")
                } else {
                    scorecard.workspaceSafetyGate = .failed("Git working tree is dirty")
                    throw Mutate4SwiftError.workingTreeDirty(executionRoot)
                }
            }

            if strategyReport {
                let sourceFilesForPlan: [String]
                if all {
                    let sourceFiles = try SourceFileDiscoverer().discoverSourceFiles(in: executionRoot)
                    if sourceFiles.isEmpty {
                        throw Mutate4SwiftError.invalidSourceFile(
                            "No Swift source files found under \(executionRoot)/Sources"
                        )
                    }
                    sourceFilesForPlan = sourceFiles
                } else {
                    guard let resolvedSource else {
                        throw ValidationError("Missing <source-file>. Provide a file path or use --all.")
                    }
                    sourceFilesForPlan = [resolvedSource]
                }

                let planner = MutationStrategyPlanner(coverageProvider: coverageProvider)
                let plan = try await planner.buildPlan(
                    sourceFiles: sourceFilesForPlan,
                    packagePath: executionRoot,
                    testFilterOverride: testFilter,
                    jobs: jobs
                )

                if json {
                    print(StrategyReporter.jsonReport(for: plan))
                } else {
                    print(StrategyReporter.textReport(for: plan))
                }

                scorecard.baselineGate = .skipped("Strategy-only run")
                scorecard.noTestsGate = .skipped("Strategy-only run")
                scorecard.buildErrorBudgetGate = .skipped("Strategy-only run")
                scorecard.restoreGuaranteeGate = .passed("No source mutation executed")
                scorecard.scaleEfficiencyGate = .passed(
                    "Planned \(plan.filesWithCandidateMutations) file(s) across \(plan.jobsPlanned) bucket(s)"
                )
                return
            }

            var processedSourceFiles: [String] = []
            var totalMutations = 0
            var totalBuildErrors = 0
            var totalSurvivors = 0

            if all {
                let batch = try await runRepositoryMutationBatch(
                    executionRoot: executionRoot,
                    testRunner: testRunner,
                    coverageProvider: coverageProvider
                )
                let reports = batch.reports
                processedSourceFiles = batch.processedSourceFiles
                totalMutations = batch.totalMutations
                totalBuildErrors = batch.totalBuildErrors
                totalSurvivors = batch.totalSurvivors

                let repositoryReport = RepositoryMutationReport(
                    packagePath: executionRoot,
                    fileReports: reports
                )

                if json {
                    let reporter = JSONReporter()
                    print(reporter.report(repositoryReport))
                } else {
                    let reporter = TextReporter()
                    print(reporter.report(repositoryReport))
                }

                if batch.processedSourceFiles.count <= 1 {
                    scorecard.scaleEfficiencyGate = .skipped("Single-file batch")
                } else {
                    scorecard.scaleEfficiencyGate = .passed(
                        "Workers: \(batch.jobsUsed), baseline runs: \(batch.baselineExecutions), unique scopes: \(batch.baselineScopeCount), files: \(batch.processedSourceFiles.count)"
                    )
                }
            } else {
                guard let resolvedSource else {
                    throw ValidationError("Missing <source-file>. Provide a file path or use --all.")
                }

                let lineSet = parseLines()
                let orchestrator = Orchestrator(
                    testRunner: testRunner,
                    coverageProvider: coverageProvider,
                    verbose: verbose,
                    timeoutMultiplier: timeoutMultiplier,
                    timeoutRetries: timeoutRetries,
                    buildFirstSampleSize: buildFirstSampleSize,
                    buildFirstErrorRatio: buildFirstErrorRatio
                )
                let resolvedSingleFileFilter: String? = if usesXcodeRunner {
                    testFilter
                } else if let testFilter {
                    testFilter
                } else {
                    await TestFileMapper().testFilterAsync(forSourceFile: resolvedSource)
                }
                let report: MutationReport
                if usesXcodeRunner {
                    report = try orchestrator.run(
                        sourceFile: resolvedSource,
                        packagePath: executionRoot,
                        testFilter: resolvedSingleFileFilter,
                        lines: lineSet
                    )
                } else {
                    let workspaceRoot = try Self.prepareMutationRunDirectory(
                        in: executionRoot,
                        prefix: "single"
                    )
                    defer { try? FileManager.default.removeItem(at: workspaceRoot) }
                    try Self.createWorkerPackageCopy(from: executionRoot, to: workspaceRoot.path)

                    let workspaceSource = try Self.remapSourceFile(
                        resolvedSource,
                        fromExecutionRoot: executionRoot,
                        toWorkerRoot: workspaceRoot.path
                    )
                    let workspaceReport = try orchestrator.run(
                        sourceFile: workspaceSource,
                        packagePath: workspaceRoot.path,
                        testFilter: resolvedSingleFileFilter,
                        lines: lineSet,
                        resolvedTestFilter: resolvedSingleFileFilter
                    )
                    report = MutationReport(
                        results: workspaceReport.results,
                        sourceFile: resolvedSource,
                        baselineDuration: workspaceReport.baselineDuration
                    )
                }

                processedSourceFiles = [resolvedSource]
                totalMutations = report.totalMutations
                totalBuildErrors = report.buildErrors
                totalSurvivors = report.survived

                if json {
                    let reporter = JSONReporter()
                    print(reporter.report(report))
                } else {
                    let reporter = TextReporter()
                    print(reporter.report(report))
                }
            }

            if totalMutations > 0 {
                scorecard.baselineGate = .passed("Baseline tests passed")
                scorecard.noTestsGate = .passed("At least one test executed per baseline scope")
            } else {
                scorecard.baselineGate = .skipped("No mutation sites discovered")
                scorecard.noTestsGate = .skipped("No mutation sites discovered")
            }

            if let staleBackupPath = firstStaleBackupPath(for: processedSourceFiles) {
                scorecard.restoreGuaranteeGate = .failed("Stale backup remains: \(staleBackupPath)")
                throw Mutate4SwiftError.backupRestoreFailed(staleBackupPath)
            }
            scorecard.restoreGuaranteeGate = .passed("No backup artifacts remain")

            let budget = evaluateBuildErrorBudget(
                totalMutations: totalMutations,
                buildErrors: totalBuildErrors
            )
            scorecard.buildErrorBudgetGate = budget.status
            if budget.exceeded {
                throw Mutate4SwiftError.buildErrorRatioExceeded(
                    actual: budget.actualRatio,
                    limit: maxBuildErrorRatio
                )
            }

            if totalSurvivors > 0 {
                throw ExitCode(1)
            }
        } catch {
            applyFailureToScorecard(scorecard: &scorecard, error: error)
            throw error
        }
    }

    private struct OrchestratorConfig: Sendable {
        let verbose: Bool
        let timeoutMultiplier: Double
        let timeoutRetries: Int
        let buildFirstSampleSize: Int
        let buildFirstErrorRatio: Double
        let testFilterOverride: String?
        let coverageEnabled: Bool
    }

    private struct RepositoryBatchResult: Sendable {
        let reports: [MutationReport]
        let processedSourceFiles: [String]
        let totalMutations: Int
        let totalBuildErrors: Int
        let totalSurvivors: Int
        let baselineExecutions: Int
        let baselineScopeCount: Int
        let jobsUsed: Int

        init(
            reports: [MutationReport],
            processedSourceFiles: [String],
            baselineExecutions: Int,
            baselineScopeCount: Int,
            jobsUsed: Int
        ) {
            self.reports = reports
            self.processedSourceFiles = processedSourceFiles
            self.baselineExecutions = baselineExecutions
            self.baselineScopeCount = baselineScopeCount
            self.jobsUsed = jobsUsed

            var totalMutations = 0
            var totalBuildErrors = 0
            var totalSurvivors = 0
            for report in reports {
                totalMutations += report.totalMutations
                totalBuildErrors += report.buildErrors
                totalSurvivors += report.survived
            }

            self.totalMutations = totalMutations
            self.totalBuildErrors = totalBuildErrors
            self.totalSurvivors = totalSurvivors
        }
    }

    private struct WorkerBucketResult: Sendable {
        let reports: [MutationReport]
        let baselineExecutions: Int
    }

    private func orchestratorConfig() -> OrchestratorConfig {
        OrchestratorConfig(
            verbose: verbose,
            timeoutMultiplier: timeoutMultiplier,
            timeoutRetries: timeoutRetries,
            buildFirstSampleSize: buildFirstSampleSize,
            buildFirstErrorRatio: buildFirstErrorRatio,
            testFilterOverride: testFilter,
            coverageEnabled: coverage
        )
    }

    private func runRepositoryMutationBatch(
        executionRoot: String,
        testRunner: TestRunner,
        coverageProvider: CoverageProvider?
    ) async throws -> RepositoryBatchResult {
        let sourceFiles = try SourceFileDiscoverer().discoverSourceFiles(in: executionRoot)
        if sourceFiles.isEmpty {
            throw Mutate4SwiftError.invalidSourceFile(
                "No Swift source files found under \(executionRoot)/Sources"
            )
        }

        let config = orchestratorConfig()

        if jobs <= 1 {
            return try await Self.runRepositoryMutationBatchSerial(
                sourceFiles: sourceFiles,
                executionRoot: executionRoot,
                testRunner: testRunner,
                coverageProvider: coverageProvider,
                config: config
            )
        }

        let planner = MutationStrategyPlanner(coverageProvider: coverageProvider)
        let plan = try await planner.buildPlan(
            sourceFiles: sourceFiles,
            packagePath: executionRoot,
            testFilterOverride: config.testFilterOverride,
            jobs: jobs
        )

        if plan.jobsPlanned <= 1 {
            return try await Self.runRepositoryMutationBatchSerial(
                sourceFiles: sourceFiles,
                executionRoot: executionRoot,
                testRunner: testRunner,
                coverageProvider: coverageProvider,
                config: config
            )
        }

        return try await Self.runRepositoryMutationBatchParallel(
            plan: plan,
            executionRoot: executionRoot,
            config: config
        )
    }

    private static func runRepositoryMutationBatchSerial(
        sourceFiles: [String],
        executionRoot: String,
        testRunner: TestRunner,
        coverageProvider: CoverageProvider?,
        config: OrchestratorConfig
    ) async throws -> RepositoryBatchResult {
        let workspaceRoot = try prepareMutationRunDirectory(
            in: executionRoot,
            prefix: "serial"
        )
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        try createWorkerPackageCopy(from: executionRoot, to: workspaceRoot.path)

        let orchestrator = Orchestrator(
            testRunner: testRunner,
            coverageProvider: coverageProvider,
            verbose: config.verbose,
            timeoutMultiplier: config.timeoutMultiplier,
            timeoutRetries: config.timeoutRetries,
            buildFirstSampleSize: config.buildFirstSampleSize,
            buildFirstErrorRatio: config.buildFirstErrorRatio
        )

        var reports: [MutationReport] = []
        reports.reserveCapacity(sourceFiles.count)
        var baselineCache: [String: BaselineResult] = [:]
        var baselineExecutions = 0
        var baselineScopes = Set<String>()
        let mapper = TestFileMapper()

        for (index, sourceFile) in sourceFiles.enumerated() {
            if config.verbose {
                print("== [\(index + 1)/\(sourceFiles.count)] \(sourceFile) ==")
            }

            let resolvedFilter = if let override = config.testFilterOverride {
                override
            } else {
                await mapper.testFilterAsync(forSourceFile: sourceFile)
            }
            let baselineKey = resolvedFilter ?? "__all_tests__"
            baselineScopes.insert(baselineKey)
            let cachedBaseline = baselineCache[baselineKey]
            let workspaceSource = try remapSourceFile(
                sourceFile,
                fromExecutionRoot: executionRoot,
                toWorkerRoot: workspaceRoot.path
            )

            let workspaceReport = try orchestrator.run(
                sourceFile: workspaceSource,
                packagePath: workspaceRoot.path,
                testFilter: resolvedFilter,
                baselineOverride: cachedBaseline,
                resolvedTestFilter: resolvedFilter
            )
            let report = MutationReport(
                results: workspaceReport.results,
                sourceFile: sourceFile,
                baselineDuration: workspaceReport.baselineDuration
            )

            reports.append(report)

            if cachedBaseline == nil && workspaceReport.totalMutations > 0 {
                baselineExecutions += 1
                baselineCache[baselineKey] = BaselineResult(
                    duration: workspaceReport.baselineDuration,
                    timeoutMultiplier: config.timeoutMultiplier
                )
            }
        }

        return RepositoryBatchResult(
            reports: reports,
            processedSourceFiles: sourceFiles,
            baselineExecutions: baselineExecutions,
            baselineScopeCount: baselineScopes.count,
            jobsUsed: 1
        )
    }

    private static func runRepositoryMutationBatchParallel(
        plan: MutationStrategyPlan,
        executionRoot: String,
        config: OrchestratorConfig
    ) async throws -> RepositoryBatchResult {
        let workerParent = try prepareMutationRunDirectory(
            in: executionRoot,
            prefix: "parallel"
        )
        defer { try? FileManager.default.removeItem(at: workerParent) }

        let emptyReports = plan.workloads
            .filter { $0.candidateMutations == 0 }
            .map {
                MutationReport(
                    results: [],
                    sourceFile: $0.sourceFile,
                    baselineDuration: 0
                )
            }

        let candidateBuckets = plan.buckets.filter { !$0.workloads.isEmpty }
        var workerResults: [WorkerBucketResult] = []
        workerResults.reserveCapacity(candidateBuckets.count)

        try await withThrowingTaskGroup(of: WorkerBucketResult.self) { group in
            for bucket in candidateBuckets {
                group.addTask {
                    try executeBucket(
                        bucket: bucket,
                        executionRoot: executionRoot,
                        workerParent: workerParent,
                        config: config
                    )
                }
            }

            for try await result in group {
                workerResults.append(result)
            }
        }

        var reports = emptyReports
        for worker in workerResults {
            reports.append(contentsOf: worker.reports)
        }
        reports.sort { $0.sourceFile < $1.sourceFile }

        let baselineExecutions = workerResults.reduce(0) { $0 + $1.baselineExecutions }
        let baselineScopeCount = Set(plan.workloads.map(\.scopeKey)).count
        let processed = plan.workloads.map(\.sourceFile)

        return RepositoryBatchResult(
            reports: reports,
            processedSourceFiles: processed,
            baselineExecutions: baselineExecutions,
            baselineScopeCount: baselineScopeCount,
            jobsUsed: plan.jobsPlanned
        )
    }

    private static func executeBucket(
        bucket: MutationExecutionBucket,
        executionRoot: String,
        workerParent: URL,
        config: OrchestratorConfig
    ) throws -> WorkerBucketResult {
        let workerRoot = workerParent
            .appendingPathComponent("worker-\(bucket.workerIndex)-\(UUID().uuidString)")
            .path

        try createWorkerPackageCopy(from: executionRoot, to: workerRoot)
        defer { try? FileManager.default.removeItem(atPath: workerRoot) }

        let workerRunner = SPMTestRunner(verbose: config.verbose)
        let workerCoverage: CoverageProvider? = config.coverageEnabled
            ? SPMCoverageProvider(verbose: config.verbose)
            : nil
        let orchestrator = Orchestrator(
            testRunner: workerRunner,
            coverageProvider: workerCoverage,
            verbose: config.verbose,
            timeoutMultiplier: config.timeoutMultiplier,
            timeoutRetries: config.timeoutRetries,
            buildFirstSampleSize: config.buildFirstSampleSize,
            buildFirstErrorRatio: config.buildFirstErrorRatio
        )

        var reports: [MutationReport] = []
        reports.reserveCapacity(bucket.workloads.count)
        var baselineCache: [String: BaselineResult] = [:]
        var baselineExecutions = 0

        for (index, workload) in bucket.workloads.enumerated() {
            if config.verbose {
                print(
                    "== [worker \(bucket.workerIndex + 1):\(index + 1)/\(bucket.workloads.count)] \(workload.sourceFile) =="
                )
            }

            let workerSource = try remapSourceFile(
                workload.sourceFile,
                fromExecutionRoot: executionRoot,
                toWorkerRoot: workerRoot
            )
            let baselineKey = workload.scopeKey
            let cachedBaseline = baselineCache[baselineKey]

            let workerReport = try orchestrator.run(
                sourceFile: workerSource,
                packagePath: workerRoot,
                testFilter: workload.scopeFilter,
                baselineOverride: cachedBaseline,
                resolvedTestFilter: workload.scopeFilter
            )

            reports.append(
                MutationReport(
                    results: workerReport.results,
                    sourceFile: workload.sourceFile,
                    baselineDuration: workerReport.baselineDuration
                )
            )

            if cachedBaseline == nil && workerReport.totalMutations > 0 {
                baselineExecutions += 1
                baselineCache[baselineKey] = BaselineResult(
                    duration: workerReport.baselineDuration,
                    timeoutMultiplier: config.timeoutMultiplier
                )
            }
        }

        return WorkerBucketResult(
            reports: reports,
            baselineExecutions: baselineExecutions
        )
    }

    private static func prepareMutationRunDirectory(in executionRoot: String, prefix: String) throws -> URL {
        let runsRoot = URL(fileURLWithPath: executionRoot)
            .appendingPathComponent(".mutate4swift/worktrees", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runsRoot,
            withIntermediateDirectories: true
        )
        let runDirectory = runsRoot.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )
        return runDirectory
    }

    private static func createWorkerPackageCopy(from sourceRoot: String, to workerRoot: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: workerRoot, withIntermediateDirectories: true)

        let excludedTopLevelEntries: Set<String> = [".build", ".git", ".mutate4swift"]
        for entry in try fileManager.contentsOfDirectory(atPath: sourceRoot) {
            if excludedTopLevelEntries.contains(entry) {
                continue
            }

            let sourcePath = (sourceRoot as NSString).appendingPathComponent(entry)
            let destinationPath = (workerRoot as NSString).appendingPathComponent(entry)
            try fileManager.copyItem(atPath: sourcePath, toPath: destinationPath)
        }
    }

    private static func remapSourceFile(
        _ sourceFile: String,
        fromExecutionRoot executionRoot: String,
        toWorkerRoot workerRoot: String
    ) throws -> String {
        let normalizedSource = URL(fileURLWithPath: sourceFile).standardizedFileURL.path
        let normalizedRoot = URL(fileURLWithPath: executionRoot).standardizedFileURL.path

        let rootPrefix = normalizedRoot + "/"
        guard normalizedSource.hasPrefix(rootPrefix) else {
            throw Mutate4SwiftError.invalidSourceFile(
                "Source file \(sourceFile) is outside package root \(executionRoot)"
            )
        }

        let relativePath = String(normalizedSource.dropFirst(normalizedRoot.count + 1))
        return URL(fileURLWithPath: workerRoot)
            .appendingPathComponent(relativePath)
            .path
    }

    private func evaluateBuildErrorBudget(totalMutations: Int, buildErrors: Int) -> (
        status: ReadinessScorecard.GateStatus,
        exceeded: Bool,
        actualRatio: Double
    ) {
        guard totalMutations > 0 else {
            return (.skipped("No mutations discovered"), false, 0)
        }

        let actualRatio = Double(buildErrors) / Double(totalMutations)
        if actualRatio <= maxBuildErrorRatio {
            return (
                .passed(
                    "Build errors \(buildErrors)/\(totalMutations) (\(String(format: "%.2f", actualRatio * 100))%) <= \(String(format: "%.2f", maxBuildErrorRatio * 100))%"
                ),
                false,
                actualRatio
            )
        }

        return (
            .failed(
                "Build errors \(buildErrors)/\(totalMutations) (\(String(format: "%.2f", actualRatio * 100))%) > \(String(format: "%.2f", maxBuildErrorRatio * 100))%"
            ),
            true,
            actualRatio
        )
    }

    private func firstStaleBackupPath(for sourceFiles: [String]) -> String? {
        let uniqueSources = Set(sourceFiles)
        for sourceFile in uniqueSources.sorted() {
            let backupPath = sourceFile + ".mutate4swift.backup"
            if FileManager.default.fileExists(atPath: backupPath) {
                return backupPath
            }
        }
        return nil
    }

    private func emitReadinessScorecard(_ scorecard: ReadinessScorecard) {
        let output = scorecard.render() + "\n"
        guard let data = output.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    private func applyFailureToScorecard(scorecard: inout ReadinessScorecard, error: Error) {
        guard let mutateError = error as? Mutate4SwiftError else {
            return
        }

        switch mutateError {
        case .baselineTestsFailed:
            scorecard.baselineGate = .failed("Baseline tests failed")
            if case .skipped = scorecard.noTestsGate {
                scorecard.noTestsGate = .passed("Tests executed, but baseline assertions failed")
            }
        case .noTestsExecuted(let filter):
            let detail = filter.map { "No tests executed for filter '\($0)'" } ?? "No tests executed"
            scorecard.baselineGate = .failed(detail)
            scorecard.noTestsGate = .failed(detail)
        case .buildErrorRatioExceeded(let actual, let limit):
            scorecard.buildErrorBudgetGate = .failed(
                "Build error ratio \(String(format: "%.2f", actual * 100))% exceeded \(String(format: "%.2f", limit * 100))%"
            )
        case .backupRestoreFailed(let path):
            scorecard.restoreGuaranteeGate = .failed("Stale backup remains at \(path)")
        case .workingTreeDirty:
            scorecard.workspaceSafetyGate = .failed("Working tree is dirty")
        default:
            break
        }
    }

    private func resolveSourceFile() -> String? {
        guard let sourceFile else { return nil }
        if sourceFile.hasPrefix("/") {
            return sourceFile
        }
        return FileManager.default.currentDirectoryPath + "/" + sourceFile
    }

    private func resolvePackagePath(startingFrom sourceFile: String?) throws -> String {
        if let path = packagePath {
            let resolved = resolvePath(path)
            guard FileManager.default.fileExists(atPath: resolved + "/Package.swift") else {
                throw Mutate4SwiftError.packagePathNotFound(resolved)
            }
            return resolved
        }

        let start = sourceFile ?? FileManager.default.currentDirectoryPath
        var dir = URL(fileURLWithPath: start).standardizedFileURL
        if sourceFile != nil {
            dir = dir.deletingLastPathComponent()
        }

        while dir.path != "/" {
            let packageSwift = dir.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: packageSwift) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }

        throw Mutate4SwiftError.packagePathNotFound(FileManager.default.currentDirectoryPath)
    }

    private func resolveXcodeInvocation() throws -> (invocation: XcodeTestInvocation, rootPath: String) {
        let workspace = xcodeWorkspace.map(resolvePath)
        let project = xcodeProject.map(resolvePath)

        if let workspace {
            guard FileManager.default.fileExists(atPath: workspace) else {
                throw Mutate4SwiftError.invalidSourceFile("Xcode workspace not found: \(workspace)")
            }
        }

        if let project {
            guard FileManager.default.fileExists(atPath: project) else {
                throw Mutate4SwiftError.invalidSourceFile("Xcode project not found: \(project)")
            }
        }

        let rootCandidate = workspace ?? project ?? FileManager.default.currentDirectoryPath
        let rootPath = URL(fileURLWithPath: rootCandidate).deletingLastPathComponent().path

        let invocation = XcodeTestInvocation(
            workspacePath: workspace,
            projectPath: project,
            scheme: xcodeScheme ?? "",
            destination: xcodeDestination,
            testPlan: xcodeTestPlan,
            configuration: xcodeConfiguration,
            derivedDataPath: xcodeDerivedDataPath.map(resolvePath)
        )

        return (invocation, rootPath)
    }

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        }
        return FileManager.default.currentDirectoryPath + "/" + path
    }

    private func isGitWorkingTreeClean(at rootPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", rootPath, "status", "--porcelain"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard process.terminationStatus == 0 else {
            return false
        }

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func parseLines() -> Set<Int>? {
        guard let lines = lines else { return nil }
        let numbers = lines.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return numbers.isEmpty ? nil : Set(numbers)
    }
}
