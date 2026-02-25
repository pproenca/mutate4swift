import ArgumentParser
import Foundation
import MutationEngine

@main
struct Mutate4Swift: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mutate4swift",
        abstract: "Mutation testing for Swift Package Manager projects",
        version: "0.1.0"
    )

    @Argument(help: "Path to the Swift source file to mutate (omit when using --all)")
    var sourceFile: String?

    @Flag(name: .long, help: "Mutate all Swift source files under Sources/")
    var all: Bool = false

    @Option(name: .long, help: "SPM package root (auto-detected if omitted)")
    var packagePath: String?

    @Option(name: .long, help: "Filter test cases (auto-detected from file mapping)")
    var testFilter: String?

    @Option(name: .long, help: "Only test mutations on these lines (comma-separated)")
    var lines: String?

    @Option(name: .long, help: "Timeout multiplier (default: 10)")
    var timeoutMultiplier: Double = 10.0

    @Flag(name: .long, help: "Use code coverage to skip untested lines")
    var coverage: Bool = false

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    @Flag(name: [.short, .long], help: "Verbose progress output")
    var verbose: Bool = false

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
    }

    func run() throws {
        let resolvedSource = resolveSourceFile()
        let resolvedPackage = try resolvePackagePath(startingFrom: resolvedSource)

        let testRunner = SPMTestRunner(verbose: verbose)
        let coverageProvider: CoverageProvider? = coverage ? SPMCoverageProvider(verbose: verbose) : nil

        let orchestrator = Orchestrator(
            testRunner: testRunner,
            coverageProvider: coverageProvider,
            verbose: verbose,
            timeoutMultiplier: timeoutMultiplier
        )

        if all {
            let sourceFiles = try SourceFileDiscoverer().discoverSourceFiles(in: resolvedPackage)
            if sourceFiles.isEmpty {
                throw Mutate4SwiftError.invalidSourceFile(
                    "No Swift source files found under \(resolvedPackage)/Sources"
                )
            }

            var reports: [MutationReport] = []
            reports.reserveCapacity(sourceFiles.count)

            for (index, sourceFile) in sourceFiles.enumerated() {
                if verbose {
                    print("== [\(index + 1)/\(sourceFiles.count)] \(sourceFile) ==")
                }

                let report = try orchestrator.run(
                    sourceFile: sourceFile,
                    packagePath: resolvedPackage,
                    testFilter: testFilter
                )
                reports.append(report)
            }

            let repositoryReport = RepositoryMutationReport(
                packagePath: resolvedPackage,
                fileReports: reports
            )

            if json {
                let reporter = JSONReporter()
                print(reporter.report(repositoryReport))
            } else {
                let reporter = TextReporter()
                print(reporter.report(repositoryReport))
            }

            if repositoryReport.survived > 0 {
                throw ExitCode(1)
            }
            return
        }

        guard let resolvedSource else {
            throw ValidationError("Missing <source-file>. Provide a file path or use --all.")
        }
        guard FileManager.default.fileExists(atPath: resolvedSource) else {
            throw Mutate4SwiftError.sourceFileNotFound(resolvedSource)
        }

        let lineSet = parseLines()
        let report = try orchestrator.run(
            sourceFile: resolvedSource,
            packagePath: resolvedPackage,
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

        if report.survived > 0 {
            throw ExitCode(1)
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
            let resolved = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
            guard FileManager.default.fileExists(atPath: resolved + "/Package.swift") else {
                throw Mutate4SwiftError.packagePathNotFound(resolved)
            }
            return resolved
        }

        // Auto-detect: walk up from source file (or CWD for --all) looking for Package.swift
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

    private func parseLines() -> Set<Int>? {
        guard let lines = lines else { return nil }
        let numbers = lines.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return numbers.isEmpty ? nil : Set(numbers)
    }
}
