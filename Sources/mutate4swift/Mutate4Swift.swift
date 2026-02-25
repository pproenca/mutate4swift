import ArgumentParser
import Foundation
import MutationEngine

@main
struct Mutate4Swift: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mutate4swift",
        abstract: "Mutation testing for SwiftPM and Xcode projects",
        version: "0.1.0"
    )

    @Argument(help: "Path to the Swift source file to mutate (omit when using --all)")
    var sourceFile: String?

    @Flag(name: .long, help: "Mutate all Swift source files under Sources/ (SwiftPM mode only)")
    var all: Bool = false

    @Option(name: .long, help: "SPM package root (auto-detected if omitted)")
    var packagePath: String?

    @Option(name: .long, help: "Filter test cases (SPM: swift test --filter, Xcode: only-testing identifier)")
    var testFilter: String?

    @Option(name: .long, help: "Only test mutations on these lines (comma-separated)")
    var lines: String?

    @Option(name: .long, help: "Timeout multiplier (default: 10)")
    var timeoutMultiplier: Double = 10.0

    @Flag(name: .long, help: "Use code coverage to skip untested lines (SwiftPM mode only)")
    var coverage: Bool = false

    @Option(name: .long, help: "Maximum allowed build-error ratio in [0,1] (default: 0.25)")
    var maxBuildErrorRatio: Double = 0.25

    @Flag(name: .long, help: "Require a clean git working tree before mutation runs")
    var requireCleanWorkingTree: Bool = false

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

    func run() throws {
        let resolvedSource = resolveSourceFile()
        if !all {
            guard let resolvedSource else {
                throw ValidationError("Missing <source-file>. Provide a file path or use --all.")
            }
            guard FileManager.default.fileExists(atPath: resolvedSource) else {
                throw Mutate4SwiftError.sourceFileNotFound(resolvedSource)
            }
        }

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

        if requireCleanWorkingTree && !isGitWorkingTreeClean(at: executionRoot) {
            throw Mutate4SwiftError.workingTreeDirty(executionRoot)
        }

        let orchestrator = Orchestrator(
            testRunner: testRunner,
            coverageProvider: coverageProvider,
            verbose: verbose,
            timeoutMultiplier: timeoutMultiplier
        )

        if all {
            let sourceFiles = try SourceFileDiscoverer().discoverSourceFiles(in: executionRoot)
            if sourceFiles.isEmpty {
                throw Mutate4SwiftError.invalidSourceFile(
                    "No Swift source files found under \(executionRoot)/Sources"
                )
            }

            var reports: [MutationReport] = []
            reports.reserveCapacity(sourceFiles.count)
            var baselineCache: [String: BaselineResult] = [:]
            let mapper = TestFileMapper()

            for (index, sourceFile) in sourceFiles.enumerated() {
                if verbose {
                    print("== [\(index + 1)/\(sourceFiles.count)] \(sourceFile) ==")
                }

                let resolvedFilter = testFilter ?? mapper.testFilter(forSourceFile: sourceFile)
                let baselineKey = resolvedFilter ?? "__all_tests__"
                let cachedBaseline = baselineCache[baselineKey]

                let report = try orchestrator.run(
                    sourceFile: sourceFile,
                    packagePath: executionRoot,
                    testFilter: resolvedFilter,
                    baselineOverride: cachedBaseline,
                    resolvedTestFilter: resolvedFilter
                )
                reports.append(report)

                if cachedBaseline == nil {
                    baselineCache[baselineKey] = BaselineResult(
                        duration: report.baselineDuration,
                        timeoutMultiplier: timeoutMultiplier
                    )
                }
            }

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

            try enforceBuildErrorRatio(
                totalMutations: repositoryReport.totalMutations,
                buildErrors: repositoryReport.buildErrors
            )

            if repositoryReport.survived > 0 {
                throw ExitCode(1)
            }
            return
        }

        guard let resolvedSource else {
            throw ValidationError("Missing <source-file>. Provide a file path or use --all.")
        }

        let lineSet = parseLines()
        let report = try orchestrator.run(
            sourceFile: resolvedSource,
            packagePath: executionRoot,
            testFilter: testFilter,
            lines: lineSet
        )

        if json {
            let reporter = JSONReporter()
            print(reporter.report(report))
        } else {
            let reporter = TextReporter()
            print(reporter.report(report))
        }

        try enforceBuildErrorRatio(
            totalMutations: report.totalMutations,
            buildErrors: report.buildErrors
        )

        if report.survived > 0 {
            throw ExitCode(1)
        }
    }

    private func enforceBuildErrorRatio(totalMutations: Int, buildErrors: Int) throws {
        guard totalMutations > 0 else { return }
        let ratio = Double(buildErrors) / Double(totalMutations)
        if ratio > maxBuildErrorRatio {
            throw Mutate4SwiftError.buildErrorRatioExceeded(actual: ratio, limit: maxBuildErrorRatio)
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
