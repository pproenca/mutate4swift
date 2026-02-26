import ArgumentParser
import Foundation
import MutationEngine

@main
struct Mutate4Swift: AsyncParsableCommand {
    enum SchedulerMode: String, CaseIterable, ExpressibleByArgument, Sendable {
        case dynamic
        case `static`
    }

    static let configuration = CommandConfiguration(
        commandName: "mutate4swift",
        abstract: "Mutation testing for SwiftPM and Xcode projects",
        discussion: """
        QUICK START:
          mutate4swift Sources/App/Feature.swift
          mutate4swift --all --jobs 4
          mutate4swift --plan --all --jobs 4
          mutate4swift Sources/App/Feature.swift --xcode-project App.xcodeproj --xcode-scheme AppTests

        OUTPUT:
          Reports are written to stdout.
          Live progress is written to stderr (disable with --no-progress).
          Use --json for machine-readable report output.
        """,
        version: "0.1.3"
    )

    struct TargetOptions: ParsableArguments {
        @Argument(
            help: "Swift source file to mutate. Omit when using --all."
        )
        var sourceFile: String?

        @Flag(
            name: .long,
            help: "Mutate all Swift files under Sources/ (SwiftPM mode only)."
        )
        var all: Bool = false

        @Flag(
            name: [.customLong("plan"), .long],
            help: "Analyze mutation strategy and exit without mutating files."
        )
        var strategyReport: Bool = false

        @Option(
            name: .long,
            help: "Only mutate these 1-based lines (comma-separated)."
        )
        var lines: String?
    }

    struct ExecutionOptions: ParsableArguments {
        @Option(
            name: [.customLong("workers"), .long],
            help: ArgumentHelp("Worker buckets used for --all and --plan.", valueName: "count")
        )
        var jobs: Int = 1

        @Option(
            name: [.customLong("project"), .long],
            help: ArgumentHelp("SwiftPM package root. Auto-detected when omitted.", valueName: "path")
        )
        var packagePath: String?

        @Option(
            name: [.customLong("tests"), .long],
            help: ArgumentHelp("Test filter (SwiftPM --filter / Xcode only-testing).", valueName: "filter")
        )
        var testFilter: String?

        @Flag(
            name: .long,
            help: "Use code coverage to skip untested lines (SwiftPM mode only)."
        )
        var coverage: Bool = false
    }

    struct SafeguardOptions: ParsableArguments {
        @Option(
            name: .long,
            help: "Maximum allowed build-error ratio in [0,1]."
        )
        var maxBuildErrorRatio: Double = 0.25

        @Flag(
            name: .long,
            help: "Require a clean git working tree before mutation runs."
        )
        var requireCleanWorkingTree: Bool = false
    }

    struct XcodeOptions: ParsableArguments {
        @Option(name: .long, help: "Path to .xcworkspace.")
        var xcodeWorkspace: String?

        @Option(name: .long, help: "Path to .xcodeproj.")
        var xcodeProject: String?

        @Option(name: .long, help: "Xcode scheme for test execution.")
        var xcodeScheme: String?

        @Option(name: .long, help: "xcodebuild destination (example: platform=iOS Simulator,name=iPhone 16).")
        var xcodeDestination: String?

        @Option(name: .long, help: "Xcode test plan name.")
        var xcodeTestPlan: String?

        @Option(name: .long, help: "Xcode build configuration (example: Debug).")
        var xcodeConfiguration: String?

        @Option(name: .long, help: "DerivedData path for xcodebuild.")
        var xcodeDerivedDataPath: String?
    }

    struct OutputOptions: ParsableArguments {
        @Flag(name: .long, help: "Output report as JSON.")
        var json: Bool = false

        @Flag(name: .long, help: "Disable live progress updates on stderr.")
        var noProgress: Bool = false

        @Flag(name: [.short, .long], help: "Print detailed logs from test runners.")
        var verbose: Bool = false

        @Flag(name: .long, help: "Disable readiness scorecard output.")
        var noReadinessScorecard: Bool = false
    }

    struct AdvancedTuningOptions: ParsableArguments {
        @Option(name: .long, help: "Timeout multiplier for mutation test runs.")
        var timeoutMultiplier: Double = 10.0

        @Option(name: .long, help: "Retries after timeout before classifying as timeout.")
        var timeoutRetries: Int = 1

        @Option(name: .long, help: "Mutation sample size before enabling build-first mode.")
        var buildFirstSampleSize: Int = 6

        @Option(name: .long, help: "Build-error ratio threshold to enable build-first mode in [0,1].")
        var buildFirstErrorRatio: Double = 0.5

        @Option(
            name: .long,
            help: ArgumentHelp("Repository scheduler mode for --all runs.", valueName: "dynamic|static")
        )
        var scheduler: SchedulerMode = .dynamic
    }

    @OptionGroup(title: "Target")
    var target: TargetOptions

    @OptionGroup(title: "Execution")
    var execution: ExecutionOptions

    @OptionGroup(title: "Safeguards")
    var safeguards: SafeguardOptions

    @OptionGroup(title: "Xcode")
    var xcode: XcodeOptions

    @OptionGroup(title: "Report Output")
    var output: OutputOptions

    @OptionGroup(title: "Advanced", visibility: .hidden)
    var advanced: AdvancedTuningOptions

    private var sourceFile: String? { target.sourceFile }
    private var all: Bool { target.all }
    private var strategyReport: Bool { target.strategyReport }
    private var lines: String? { target.lines }
    private var jobs: Int { execution.jobs }
    private var packagePath: String? { execution.packagePath }
    private var testFilter: String? { execution.testFilter }
    private var coverage: Bool { execution.coverage }
    private var maxBuildErrorRatio: Double { safeguards.maxBuildErrorRatio }
    private var requireCleanWorkingTree: Bool { safeguards.requireCleanWorkingTree }
    private var xcodeWorkspace: String? { xcode.xcodeWorkspace }
    private var xcodeProject: String? { xcode.xcodeProject }
    private var xcodeScheme: String? { xcode.xcodeScheme }
    private var xcodeDestination: String? { xcode.xcodeDestination }
    private var xcodeTestPlan: String? { xcode.xcodeTestPlan }
    private var xcodeConfiguration: String? { xcode.xcodeConfiguration }
    private var xcodeDerivedDataPath: String? { xcode.xcodeDerivedDataPath }
    private var json: Bool { output.json }
    private var noProgress: Bool { output.noProgress }
    private var verbose: Bool { output.verbose }
    private var noReadinessScorecard: Bool { output.noReadinessScorecard }
    private var timeoutMultiplier: Double { advanced.timeoutMultiplier }
    private var timeoutRetries: Int { advanced.timeoutRetries }
    private var buildFirstSampleSize: Int { advanced.buildFirstSampleSize }
    private var buildFirstErrorRatio: Double { advanced.buildFirstErrorRatio }
    private var scheduler: SchedulerMode { advanced.scheduler }

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
        try validateTargetSelection()
        try validateNumericOptions()
        try validateXcodeOptionsIfNeeded()
    }

    func run() async throws {
        let resolvedSource = try resolveSourceFile()
        try validateResolvedSourceForRun(resolvedSource)

        let progressReporter = ProgressReporter(enabled: !noProgress)
        let modeLabel = strategyReport ? "plan" : (all ? "repository-run" : "single-run")
        progressReporter.stage(
            "starting \(modeLabel) (runner: \(usesXcodeRunner ? "xcode" : "swiftpm"))"
        )

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
            let runContext = try resolveRunContext(
                resolvedSource: resolvedSource,
                progressReporter: progressReporter
            )
            try validateWorkingTreeIfNeeded(
                executionRoot: runContext.executionRoot,
                progressReporter: progressReporter,
                scorecard: &scorecard
            )

            if strategyReport {
                let plan = try await buildAndPrintStrategyPlan(
                    resolvedSource: resolvedSource,
                    executionRoot: runContext.executionRoot,
                    coverageProvider: runContext.coverageProvider,
                    progressReporter: progressReporter
                )
                applyStrategyOnlyScorecard(
                    scorecard: &scorecard,
                    filesWithCandidateMutations: plan.filesWithCandidateMutations,
                    jobsPlanned: plan.jobsPlanned
                )
                return
            }

            let totals = try await executeMutationRun(
                resolvedSource: resolvedSource,
                runContext: runContext,
                progressReporter: progressReporter,
                scorecard: &scorecard
            )

            applyMutationExecutionScorecard(totals: totals, scorecard: &scorecard)
            try validateBackupRestoreGuarantee(
                processedSourceFiles: totals.processedSourceFiles,
                scorecard: &scorecard
            )
            try enforceBuildErrorBudget(totals: totals, scorecard: &scorecard)
            try finalizeRun(totals: totals, progressReporter: progressReporter)
        } catch {
            applyFailureToScorecard(scorecard: &scorecard, error: error)
            progressReporter.stage("run failed: \(error)")
            throw error
        }
    }

    private struct RunContext {
        let executionRoot: String
        let testRunner: TestRunner
        let coverageProvider: CoverageProvider?
    }

    private struct RunTotals {
        let processedSourceFiles: [String]
        let totalMutations: Int
        let totalBuildErrors: Int
        let totalSurvivors: Int
    }

    private func applyStrategyOnlyScorecard(
        scorecard: inout ReadinessScorecard,
        filesWithCandidateMutations: Int,
        jobsPlanned: Int
    ) {
        scorecard.baselineGate = .skipped("Strategy-only run")
        scorecard.noTestsGate = .skipped("Strategy-only run")
        scorecard.buildErrorBudgetGate = .skipped("Strategy-only run")
        scorecard.restoreGuaranteeGate = .passed("No source mutation executed")
        scorecard.scaleEfficiencyGate = .passed(
            "Planned \(filesWithCandidateMutations) file(s) across \(jobsPlanned) bucket(s)"
        )
    }

    private func applyMutationExecutionScorecard(
        totals: RunTotals,
        scorecard: inout ReadinessScorecard
    ) {
        if totals.totalMutations > 0 {
            scorecard.baselineGate = .passed("Baseline tests passed")
            scorecard.noTestsGate = .passed("At least one test executed per baseline scope")
        } else {
            scorecard.baselineGate = .skipped("No mutation sites discovered")
            scorecard.noTestsGate = .skipped("No mutation sites discovered")
        }
    }

    private func validateBackupRestoreGuarantee(
        processedSourceFiles: [String],
        scorecard: inout ReadinessScorecard
    ) throws {
        if let staleBackupPath = firstStaleBackupPath(for: processedSourceFiles) {
            scorecard.restoreGuaranteeGate = .failed("Stale backup remains: \(staleBackupPath)")
            throw Mutate4SwiftError.backupRestoreFailed(staleBackupPath)
        }
        scorecard.restoreGuaranteeGate = .passed("No backup artifacts remain")
    }

    private func enforceBuildErrorBudget(
        totals: RunTotals,
        scorecard: inout ReadinessScorecard
    ) throws {
        let budget = evaluateBuildErrorBudget(
            totalMutations: totals.totalMutations,
            buildErrors: totals.totalBuildErrors
        )
        scorecard.buildErrorBudgetGate = budget.status
        if budget.exceeded {
            throw Mutate4SwiftError.buildErrorRatioExceeded(
                actual: budget.actualRatio,
                limit: maxBuildErrorRatio
            )
        }
    }

    private func finalizeRun(
        totals: RunTotals,
        progressReporter: ProgressReporter
    ) throws {
        if totals.totalSurvivors > 0 {
            throw ExitCode(1)
        }
        progressReporter.stage("run completed")
    }

    private func validateTargetSelection() throws {
        if all && sourceFile != nil {
            throw ValidationError("Specify either <source-file> or --all, not both.")
        }

        if !all && sourceFile == nil {
            throw ValidationError("Missing <source-file>. Provide a file path or use --all.")
        }

        if all && lines != nil {
            throw ValidationError("--lines can only be used with a single <source-file>.")
        }
    }

    private func validateNumericOptions() throws {
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
    }

    private func validateXcodeOptionsIfNeeded() throws {
        guard usesXcodeRunner else {
            return
        }

        try validateUnsupportedXcodeModeOptions()
        try validateXcodeRootSelection()
        try validateXcodeSchemeOption()
    }

    private func validateUnsupportedXcodeModeOptions() throws {
        if all {
            throw ValidationError("--all is currently only supported in SwiftPM mode.")
        }

        if coverage {
            throw ValidationError("--coverage is currently only supported in SwiftPM mode.")
        }

        if packagePath != nil {
            throw ValidationError("--package-path/--project cannot be combined with Xcode runner options.")
        }
    }

    private func validateXcodeRootSelection() throws {
        if xcodeWorkspace != nil && xcodeProject != nil {
            throw ValidationError("Specify either --xcode-workspace or --xcode-project, not both.")
        }

        if xcodeWorkspace == nil && xcodeProject == nil {
            throw ValidationError("Xcode mode requires --xcode-workspace or --xcode-project.")
        }
    }

    private func validateXcodeSchemeOption() throws {
        guard let scheme = xcodeScheme, !scheme.isEmpty else {
            throw ValidationError("Xcode mode requires --xcode-scheme.")
        }
    }

    private func validateResolvedSourceForRun(_ resolvedSource: String?) throws {
        guard !all else {
            return
        }
        guard let resolvedSource else {
            throw ValidationError("Missing <source-file>. Provide a file path or use --all.")
        }
        guard FileManager.default.fileExists(atPath: resolvedSource) else {
            throw Mutate4SwiftError.sourceFileNotFound(resolvedSource)
        }
    }

    private func resolveRunContext(
        resolvedSource: String?,
        progressReporter: ProgressReporter
    ) throws -> RunContext {
        if usesXcodeRunner {
            let xcode = try resolveXcodeInvocation()
            progressReporter.stage("resolved Xcode invocation (root: \(xcode.rootPath))")
            return RunContext(
                executionRoot: xcode.rootPath,
                testRunner: XcodeTestRunner(invocation: xcode.invocation, verbose: verbose),
                coverageProvider: nil
            )
        }

        let resolvedPackage = try resolvePackagePath(startingFrom: resolvedSource)
        progressReporter.stage("resolved SwiftPM package root: \(resolvedPackage)")
        return RunContext(
            executionRoot: resolvedPackage,
            testRunner: SPMTestRunner(verbose: verbose),
            coverageProvider: coverage ? SPMCoverageProvider(verbose: verbose) : nil
        )
    }

    private func validateWorkingTreeIfNeeded(
        executionRoot: String,
        progressReporter: ProgressReporter,
        scorecard: inout ReadinessScorecard
    ) throws {
        guard requireCleanWorkingTree else {
            return
        }

        progressReporter.stage("checking git working tree state")
        if isGitWorkingTreeClean(at: executionRoot) {
            scorecard.workspaceSafetyGate = .passed("Git working tree is clean")
            return
        }

        scorecard.workspaceSafetyGate = .failed("Git working tree is dirty")
        throw Mutate4SwiftError.workingTreeDirty(executionRoot)
    }

    private func buildAndPrintStrategyPlan(
        resolvedSource: String?,
        executionRoot: String,
        coverageProvider: CoverageProvider?,
        progressReporter: ProgressReporter
    ) async throws -> MutationStrategyPlan {
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
        progressReporter.stage(
            "building strategy plan for \(sourceFilesForPlan.count) file(s) with \(jobs) worker(s)"
        )
        let plan = try await planner.buildPlan(
            sourceFiles: sourceFilesForPlan,
            packagePath: executionRoot,
            testFilterOverride: testFilter,
            jobs: jobs
        )
        progressReporter.stage(
            "strategy plan complete: \(plan.totalCandidateMutations) candidate mutation(s) across \(plan.jobsPlanned) worker bucket(s)"
        )

        if json {
            print(StrategyReporter.jsonReport(for: plan))
        } else {
            print(StrategyReporter.textReport(for: plan))
        }

        return plan
    }

    private func executeMutationRun(
        resolvedSource: String?,
        runContext: RunContext,
        progressReporter: ProgressReporter,
        scorecard: inout ReadinessScorecard
    ) async throws -> RunTotals {
        if all {
            let batch = try await executeRepositoryMutationRun(
                executionRoot: runContext.executionRoot,
                testRunner: runContext.testRunner,
                coverageProvider: runContext.coverageProvider,
                progressReporter: progressReporter
            )
            if batch.processedSourceFiles.count <= 1 {
                scorecard.scaleEfficiencyGate = .skipped("Single-file batch")
            } else {
                scorecard.scaleEfficiencyGate = .passed(
                    "Workers: \(batch.jobsUsed), baseline runs: \(batch.baselineExecutions), unique scopes: \(batch.baselineScopeCount), queue steals: \(batch.queueSteals), files: \(batch.processedSourceFiles.count)"
                )
            }
            return RunTotals(
                processedSourceFiles: batch.processedSourceFiles,
                totalMutations: batch.totalMutations,
                totalBuildErrors: batch.totalBuildErrors,
                totalSurvivors: batch.totalSurvivors
            )
        }

        guard let resolvedSource else {
            throw ValidationError("Missing <source-file>. Provide a file path or use --all.")
        }

        let report = try await executeSingleFileMutationRun(
            resolvedSource: resolvedSource,
            runContext: runContext,
            progressReporter: progressReporter
        )
        return RunTotals(
            processedSourceFiles: [resolvedSource],
            totalMutations: report.totalMutations,
            totalBuildErrors: report.buildErrors,
            totalSurvivors: report.survived
        )
    }

    private func executeRepositoryMutationRun(
        executionRoot: String,
        testRunner: TestRunner,
        coverageProvider: CoverageProvider?,
        progressReporter: ProgressReporter
    ) async throws -> RepositoryBatchResult {
        progressReporter.stage("starting repository mutation run")
        let batch = try await runRepositoryMutationBatch(
            executionRoot: executionRoot,
            testRunner: testRunner,
            coverageProvider: coverageProvider,
            progressReporter: progressReporter
        )
        progressReporter.stage(
            "repository mutation run complete: files \(batch.processedSourceFiles.count), mutations \(batch.totalMutations), survivors \(batch.totalSurvivors), build errors \(batch.totalBuildErrors)"
        )

        let repositoryReport = RepositoryMutationReport(
            packagePath: executionRoot,
            fileReports: batch.reports
        )
        if json {
            let reporter = JSONReporter()
            print(reporter.report(repositoryReport))
        } else {
            let reporter = TextReporter()
            print(reporter.report(repositoryReport))
        }

        return batch
    }

    private func executeSingleFileMutationRun(
        resolvedSource: String,
        runContext: RunContext,
        progressReporter: ProgressReporter
    ) async throws -> MutationReport {
        progressReporter.stage("starting mutation run for \(resolvedSource)")
        let lineSet = parseLines()
        let orchestrator = Orchestrator(
            testRunner: runContext.testRunner,
            coverageProvider: runContext.coverageProvider,
            verbose: verbose,
            timeoutMultiplier: timeoutMultiplier,
            timeoutRetries: timeoutRetries,
            buildFirstSampleSize: buildFirstSampleSize,
            buildFirstErrorRatio: buildFirstErrorRatio,
            progressHandler: Self.makeProgressHandler(
                reporter: progressReporter,
                context: resolvedSource
            )
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
                packagePath: runContext.executionRoot,
                testFilter: resolvedSingleFileFilter,
                lines: lineSet
            )
        } else {
            let workspaceRoot = try Self.prepareMutationRunDirectory(
                in: runContext.executionRoot,
                prefix: "single"
            )
            defer { try? FileManager.default.removeItem(at: workspaceRoot) }
            try Self.createWorkerPackageCopy(from: runContext.executionRoot, to: workspaceRoot.path)

            let workspaceSource = try Self.remapSourceFile(
                resolvedSource,
                fromExecutionRoot: runContext.executionRoot,
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

        progressReporter.stage(
            "completed \(resolvedSource): mutations \(report.totalMutations), survivors \(report.survived), build errors \(report.buildErrors)"
        )
        if json {
            let reporter = JSONReporter()
            print(reporter.report(report))
        } else {
            let reporter = TextReporter()
            print(reporter.report(report))
        }

        return report
    }

    private struct OrchestratorConfig: Sendable {
        let verbose: Bool
        let timeoutMultiplier: Double
        let timeoutRetries: Int
        let buildFirstSampleSize: Int
        let buildFirstErrorRatio: Double
        let scheduler: SchedulerMode
        let testFilterOverride: String?
        let coverageEnabled: Bool
        let progressReporter: ProgressReporter?
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
        let queueSteals: Int

        init(
            reports: [MutationReport],
            processedSourceFiles: [String],
            baselineExecutions: Int,
            baselineScopeCount: Int,
            jobsUsed: Int,
            queueSteals: Int
        ) {
            self.reports = reports
            self.processedSourceFiles = processedSourceFiles
            self.baselineExecutions = baselineExecutions
            self.baselineScopeCount = baselineScopeCount
            self.jobsUsed = jobsUsed
            self.queueSteals = queueSteals

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
        let processedWorkloads: Int
    }

    private func orchestratorConfig(progressReporter: ProgressReporter?) -> OrchestratorConfig {
        OrchestratorConfig(
            verbose: verbose,
            timeoutMultiplier: timeoutMultiplier,
            timeoutRetries: timeoutRetries,
            buildFirstSampleSize: buildFirstSampleSize,
            buildFirstErrorRatio: buildFirstErrorRatio,
            scheduler: scheduler,
            testFilterOverride: testFilter,
            coverageEnabled: coverage,
            progressReporter: progressReporter
        )
    }

    private func runRepositoryMutationBatch(
        executionRoot: String,
        testRunner: TestRunner,
        coverageProvider: CoverageProvider?,
        progressReporter: ProgressReporter?
    ) async throws -> RepositoryBatchResult {
        let sourceFiles = try SourceFileDiscoverer().discoverSourceFiles(in: executionRoot)
        if sourceFiles.isEmpty {
            throw Mutate4SwiftError.invalidSourceFile(
                "No Swift source files found under \(executionRoot)/Sources"
            )
        }

        let config = orchestratorConfig(progressReporter: progressReporter)

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
            let context = "file \(index + 1)/\(sourceFiles.count): \(sourceFile)"
            config.progressReporter?.stage("[\(context)] preparing")

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
            let orchestrator = Orchestrator(
                testRunner: testRunner,
                coverageProvider: coverageProvider,
                verbose: config.verbose,
                timeoutMultiplier: config.timeoutMultiplier,
                timeoutRetries: config.timeoutRetries,
                buildFirstSampleSize: config.buildFirstSampleSize,
                buildFirstErrorRatio: config.buildFirstErrorRatio,
                progressHandler: makeProgressHandler(
                    reporter: config.progressReporter,
                    context: context
                )
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
            config.progressReporter?.stage(
                "[\(context)] completed: mutations \(report.totalMutations), survivors \(report.survived), build errors \(report.buildErrors)"
            )

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
            jobsUsed: 1,
            queueSteals: 0
        )
    }

    private static func runRepositoryMutationBatchParallel(
        plan: MutationStrategyPlan,
        executionRoot: String,
        config: OrchestratorConfig
    ) async throws -> RepositoryBatchResult {
        config.progressReporter?.stage(
            "parallel plan: \(plan.workloads.count) file(s), \(plan.totalCandidateMutations) candidate mutation(s), \(plan.jobsPlanned) worker(s), scheduler \(config.scheduler.rawValue)"
        )
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

        var workerResults: [WorkerBucketResult] = []
        workerResults.reserveCapacity(plan.jobsPlanned)
        var queueSteals = 0

        switch config.scheduler {
        case .dynamic:
            let workQueue = MutationWorkQueue(plan: plan)
            let seededWorkloadsByWorker = Dictionary(
                uniqueKeysWithValues: plan.buckets.map { ($0.workerIndex, $0.workloads.count) }
            )

            try await withThrowingTaskGroup(of: WorkerBucketResult.self) { group in
                for workerIndex in 0..<plan.jobsPlanned {
                    let seededWorkloads = seededWorkloadsByWorker[workerIndex, default: 0]
                    group.addTask {
                        try await executeQueuedWorker(
                            workerIndex: workerIndex,
                            seededWorkloads: seededWorkloads,
                            workQueue: workQueue,
                            executionRoot: executionRoot,
                            workerParent: workerParent,
                            config: config
                        )
                    }
                }

                for try await result in group {
                    workerResults.append(result)
                    config.progressReporter?.stage(
                        "completed worker (\(workerResults.count)/\(plan.jobsPlanned))"
                    )
                }
            }

            let queueMetrics = await workQueue.metrics()
            queueSteals = queueMetrics.stolenWorkloads
            config.progressReporter?.stage(
                "queue dispatch complete: dispatched \(queueMetrics.dispatchedWorkloads), steals \(queueMetrics.stolenWorkloads)"
            )
        case .static:
            let candidateBuckets = plan.buckets.filter { !$0.workloads.isEmpty }
            try await withThrowingTaskGroup(of: WorkerBucketResult.self) { group in
                for bucket in candidateBuckets {
                    group.addTask {
                        try executeStaticBucket(
                            bucket: bucket,
                            executionRoot: executionRoot,
                            workerParent: workerParent,
                            config: config
                        )
                    }
                }

                for try await result in group {
                    workerResults.append(result)
                    config.progressReporter?.stage(
                        "completed static bucket (\(workerResults.count)/\(candidateBuckets.count))"
                    )
                }
            }
            config.progressReporter?.stage("static dispatch complete: buckets \(candidateBuckets.count)")
        }

        var reports = emptyReports
        for worker in workerResults {
            reports.append(contentsOf: worker.reports)
        }
        reports.sort { $0.sourceFile < $1.sourceFile }

        let baselineExecutions = workerResults.reduce(0) { $0 + $1.baselineExecutions }
        let baselineScopeCount = Set(plan.workloads.map(\.scopeKey)).count
        let processed = plan.workloads.map(\.sourceFile)
        let jobsUsed = max(1, workerResults.filter { $0.processedWorkloads > 0 }.count)

        return RepositoryBatchResult(
            reports: reports,
            processedSourceFiles: processed,
            baselineExecutions: baselineExecutions,
            baselineScopeCount: baselineScopeCount,
            jobsUsed: jobsUsed,
            queueSteals: queueSteals
        )
    }

    private static func executeStaticBucket(
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
        config.progressReporter?.stage(
            "worker \(bucket.workerIndex + 1): starting static bucket (seed files: \(bucket.workloads.count))"
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
            let context = "worker \(bucket.workerIndex + 1) file \(index + 1)/\(bucket.workloads.count): \(workload.sourceFile)"
            config.progressReporter?.stage("[\(context)] preparing")

            let workerSource = try remapSourceFile(
                workload.sourceFile,
                fromExecutionRoot: executionRoot,
                toWorkerRoot: workerRoot
            )
            let baselineKey = workload.scopeKey
            let cachedBaseline = baselineCache[baselineKey]
            let orchestrator = Orchestrator(
                testRunner: workerRunner,
                coverageProvider: workerCoverage,
                verbose: config.verbose,
                timeoutMultiplier: config.timeoutMultiplier,
                timeoutRetries: config.timeoutRetries,
                buildFirstSampleSize: config.buildFirstSampleSize,
                buildFirstErrorRatio: config.buildFirstErrorRatio,
                progressHandler: makeProgressHandler(
                    reporter: config.progressReporter,
                    context: context
                )
            )

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
            config.progressReporter?.stage(
                "[\(context)] completed: mutations \(workerReport.totalMutations), survivors \(workerReport.survived), build errors \(workerReport.buildErrors)"
            )

            if cachedBaseline == nil && workerReport.totalMutations > 0 {
                baselineExecutions += 1
                baselineCache[baselineKey] = BaselineResult(
                    duration: workerReport.baselineDuration,
                    timeoutMultiplier: config.timeoutMultiplier
                )
            }
        }
        config.progressReporter?.stage(
            "worker \(bucket.workerIndex + 1): static bucket complete (\(bucket.workloads.count) file(s))"
        )

        return WorkerBucketResult(
            reports: reports,
            baselineExecutions: baselineExecutions,
            processedWorkloads: bucket.workloads.count
        )
    }

    private static func executeQueuedWorker(
        workerIndex: Int,
        seededWorkloads: Int,
        workQueue: MutationWorkQueue,
        executionRoot: String,
        workerParent: URL,
        config: OrchestratorConfig
    ) async throws -> WorkerBucketResult {
        let workerRoot = workerParent
            .appendingPathComponent("worker-\(workerIndex)-\(UUID().uuidString)")
            .path

        try createWorkerPackageCopy(from: executionRoot, to: workerRoot)
        defer { try? FileManager.default.removeItem(atPath: workerRoot) }

        let workerRunner = SPMTestRunner(verbose: config.verbose)
        let workerCoverage: CoverageProvider? = config.coverageEnabled
            ? SPMCoverageProvider(verbose: config.verbose)
            : nil
        config.progressReporter?.stage(
            "worker \(workerIndex + 1): starting queue (seed files: \(seededWorkloads))"
        )

        var reports: [MutationReport] = []
        reports.reserveCapacity(max(1, seededWorkloads))
        var baselineCache: [String: BaselineResult] = [:]
        var baselineExecutions = 0
        var processedWorkloads = 0

        while let workload = await workQueue.next(
            for: workerIndex,
            warmedScopes: Set(baselineCache.keys)
        ) {
            processedWorkloads += 1
            if config.verbose {
                print(
                    "== [worker \(workerIndex + 1):\(processedWorkloads)] \(workload.sourceFile) =="
                )
            }
            let context = "worker \(workerIndex + 1) file \(processedWorkloads): \(workload.sourceFile)"
            config.progressReporter?.stage("[\(context)] preparing")

            let workerSource = try remapSourceFile(
                workload.sourceFile,
                fromExecutionRoot: executionRoot,
                toWorkerRoot: workerRoot
            )
            let baselineKey = workload.scopeKey
            let cachedBaseline = baselineCache[baselineKey]
            let orchestrator = Orchestrator(
                testRunner: workerRunner,
                coverageProvider: workerCoverage,
                verbose: config.verbose,
                timeoutMultiplier: config.timeoutMultiplier,
                timeoutRetries: config.timeoutRetries,
                buildFirstSampleSize: config.buildFirstSampleSize,
                buildFirstErrorRatio: config.buildFirstErrorRatio,
                progressHandler: makeProgressHandler(
                    reporter: config.progressReporter,
                    context: context
                )
            )

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
            config.progressReporter?.stage(
                "[\(context)] completed: mutations \(workerReport.totalMutations), survivors \(workerReport.survived), build errors \(workerReport.buildErrors)"
            )

            if cachedBaseline == nil && workerReport.totalMutations > 0 {
                baselineExecutions += 1
                baselineCache[baselineKey] = BaselineResult(
                    duration: workerReport.baselineDuration,
                    timeoutMultiplier: config.timeoutMultiplier
                )
            }
        }
        config.progressReporter?.stage(
            "worker \(workerIndex + 1): queue drained (\(processedWorkloads) file(s))"
        )

        return WorkerBucketResult(
            reports: reports,
            baselineExecutions: baselineExecutions,
            processedWorkloads: processedWorkloads
        )
    }

    private static func makeProgressHandler(
        reporter: ProgressReporter?,
        context: String
    ) -> OrchestratorProgressHandler? {
        guard let reporter else {
            return nil
        }

        return { event in
            reporter.record(event: event, context: context)
        }
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
        let normalizedSource = URL(fileURLWithPath: sourceFile)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let normalizedRoot = URL(fileURLWithPath: executionRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

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
            applyBaselineFailureToScorecard(scorecard: &scorecard)
        case .noTestsExecuted(let filter):
            applyNoTestsFailureToScorecard(scorecard: &scorecard, filter: filter)
        case .buildErrorRatioExceeded(let actual, let limit):
            scorecard.buildErrorBudgetGate = .failed(
                buildErrorRatioExceededMessage(actual: actual, limit: limit)
            )
        case .backupRestoreFailed(let path):
            scorecard.restoreGuaranteeGate = .failed("Stale backup remains at \(path)")
        case .workingTreeDirty:
            scorecard.workspaceSafetyGate = .failed("Working tree is dirty")
        default:
            break
        }
    }

    private func applyBaselineFailureToScorecard(scorecard: inout ReadinessScorecard) {
        scorecard.baselineGate = .failed("Baseline tests failed")
        if case .skipped = scorecard.noTestsGate {
            scorecard.noTestsGate = .passed("Tests executed, but baseline assertions failed")
        }
    }

    private func applyNoTestsFailureToScorecard(
        scorecard: inout ReadinessScorecard,
        filter: String?
    ) {
        let detail = filter.map { "No tests executed for filter '\($0)'" } ?? "No tests executed"
        scorecard.baselineGate = .failed(detail)
        scorecard.noTestsGate = .failed(detail)
    }

    private func buildErrorRatioExceededMessage(actual: Double, limit: Double) -> String {
        "Build error ratio \(String(format: "%.2f", actual * 100))% exceeded \(String(format: "%.2f", limit * 100))%"
    }

    private func resolveSourceFile() throws -> String? {
        guard let sourceFile else { return nil }
        let resolved = resolvePath(sourceFile)
        if FileManager.default.fileExists(atPath: resolved) || sourceFile.hasPrefix("/") {
            return resolved
        }

        guard let sourceFiles = discoverSourceFilesForResolution() else {
            return resolved
        }

        let matches = matchingSourceFiles(query: sourceFile, in: sourceFiles)

        if matches.count == 1 {
            return matches[0]
        }

        if matches.count > 1 {
            let renderedMatches = matches.prefix(8).joined(separator: "\n  - ")
            throw Mutate4SwiftError.invalidSourceFile(
                "Ambiguous source file '\(sourceFile)'. Matches:\n  - \(renderedMatches)"
            )
        }

        return resolved
    }

    private func discoverSourceFilesForResolution() -> [String]? {
        guard let packageRoot = try? resolvePackagePath(startingFrom: nil),
              let sourceFiles = try? SourceFileDiscoverer().discoverSourceFiles(in: packageRoot),
              !sourceFiles.isEmpty else {
            return nil
        }
        return sourceFiles
    }

    private func matchingSourceFiles(query sourceFile: String, in sourceFiles: [String]) -> [String] {
        let rawQuery = sourceFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceFile.contains("/") {
            let suffixes = sourceFileMatchSuffixes(for: rawQuery)
            return sourceFiles.filter { path in
                suffixes.contains { suffix in
                    path.hasSuffix("/" + suffix) || path == suffix
                }
            }
            .sorted()
        }

        return sourceFiles.filter { path in
            URL(fileURLWithPath: path).lastPathComponent == rawQuery
        }
        .sorted()
    }

    private func sourceFileMatchSuffixes(for rawQuery: String) -> [String] {
        let normalizedQuery = URL(
            fileURLWithPath: rawQuery,
            relativeTo: URL(fileURLWithPath: "/", isDirectory: true)
        )
        .standardizedFileURL
        .path
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var suffixes = [normalizedQuery]
        if normalizedQuery.hasPrefix("Sources/") {
            suffixes.append(String(normalizedQuery.dropFirst("Sources/".count)))
        }
        return suffixes.filter { !$0.isEmpty }
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
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        return URL(fileURLWithPath: path, relativeTo: currentDirectory)
            .standardizedFileURL
            .path
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
