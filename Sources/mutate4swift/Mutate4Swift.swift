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

    @Argument(help: "Path to the Swift source file to mutate")
    var sourceFile: String

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

    func run() throws {
        let resolvedSource = resolveSourceFile()
        let resolvedPackage = try resolvePackagePath()

        guard FileManager.default.fileExists(atPath: resolvedSource) else {
            throw Mutate4SwiftError.sourceFileNotFound(resolvedSource)
        }

        let lineSet = parseLines()

        let testRunner = SPMTestRunner(verbose: verbose)
        let coverageProvider: CoverageProvider? = coverage ? SPMCoverageProvider(verbose: verbose) : nil

        let orchestrator = Orchestrator(
            testRunner: testRunner,
            coverageProvider: coverageProvider,
            verbose: verbose,
            timeoutMultiplier: timeoutMultiplier
        )

        let report = try orchestrator.run(
            sourceFile: resolvedSource,
            packagePath: resolvedPackage,
            testFilter: testFilter,
            lines: lineSet
        )

        // Output report
        if json {
            let reporter = JSONReporter()
            print(reporter.report(report))
        } else {
            let reporter = TextReporter()
            print(reporter.report(report))
        }

        // Exit code 1 if any mutations survived
        if report.survived > 0 {
            throw ExitCode(1)
        }
    }

    private func resolveSourceFile() -> String {
        if sourceFile.hasPrefix("/") {
            return sourceFile
        }
        return FileManager.default.currentDirectoryPath + "/" + sourceFile
    }

    private func resolvePackagePath() throws -> String {
        if let path = packagePath {
            let resolved = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
            guard FileManager.default.fileExists(atPath: resolved + "/Package.swift") else {
                throw Mutate4SwiftError.packagePathNotFound(resolved)
            }
            return resolved
        }

        // Auto-detect: walk up from source file looking for Package.swift
        var dir = URL(fileURLWithPath: resolveSourceFile()).deletingLastPathComponent()
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
