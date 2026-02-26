import Foundation

public struct TextReporter: Sendable {
    public init() {}

    public func report(_ report: MutationReport) -> String {
        var lines = mutationReportHeaderLines(report)
        appendMutationDetails(report.results, to: &lines)
        appendMutationSummary(report, to: &lines)
        appendSurvivingMutationDetails(report.results, to: &lines)
        return lines.joined(separator: "\n")
    }

    private func mutationReportHeaderLines(_ report: MutationReport) -> [String] {
        [
            "",
            "== Mutation Testing Report ==",
            "Source: \(report.sourceFile)",
            "Baseline duration: \(String(format: "%.2f", report.baselineDuration))s",
            "",
        ]
    }

    private func appendMutationDetails(_ results: [MutationResult], to lines: inout [String]) {
        for result in results {
            lines.append(formattedMutationDetail(result: result))
        }
    }

    private func formattedMutationDetail(result: MutationResult) -> String {
        let site = result.site
        return
            "  [\(statusLabel(for: result.outcome))] Line \(site.line): "
            + "\(site.mutationOperator.description) "
            + "\"\(site.originalText)\" → \"\(site.mutatedText)\""
    }

    private func statusLabel(for outcome: MutationOutcome) -> String {
        switch outcome {
        case .killed:
            return "KILLED"
        case .survived:
            return "SURVIVED"
        case .timeout:
            return "TIMEOUT"
        case .buildError:
            return "BUILD_ERROR"
        case .skipped:
            return "SKIPPED"
        }
    }

    private func appendMutationSummary(_ report: MutationReport, to lines: inout [String]) {
        lines.append("")
        lines.append("== Summary ==")
        lines.append("Total mutations:  \(report.totalMutations)")
        lines.append("Killed:           \(report.killed)")
        lines.append("Survived:         \(report.survived)")
        lines.append("Timed out:        \(report.timedOut)")
        lines.append("Build errors:     \(report.buildErrors)")
        lines.append("Skipped:          \(report.skipped)")
        lines.append("Kill percentage:  \(String(format: "%.1f", report.killPercentage))%")
        lines.append("")
    }

    private func appendSurvivingMutationDetails(_ results: [MutationResult], to lines: inout [String]) {
        let survivors = results.filter { $0.outcome == .survived }
        guard !survivors.isEmpty else {
            return
        }

        lines.append("SURVIVING MUTATIONS (test gaps):")
        for result in survivors {
            lines.append(formattedSurvivorDetail(site: result.site))
        }
        lines.append("")
    }

    private func formattedSurvivorDetail(site: MutationSite) -> String {
        "  Line \(site.line): "
            + "\(site.mutationOperator.description) "
            + "\"\(site.originalText)\" → \"\(site.mutatedText)\""
    }

    public func report(_ report: RepositoryMutationReport) -> String {
        var lines: [String] = []

        lines.append("")
        lines.append("== Mutation Testing Report (Repository) ==")
        lines.append("Package: \(report.packagePath)")
        lines.append("Files analyzed: \(report.filesAnalyzed)")
        lines.append("Aggregate baseline duration: \(String(format: "%.2f", report.baselineDuration))s")
        lines.append("")
        lines.append("== File Summaries ==")

        for fileReport in report.fileReports {
            let fileStatus: String
            if fileReport.survived > 0 {
                fileStatus = "SURVIVED"
            } else if fileReport.totalMutations == 0 {
                fileStatus = "NO_MUTATIONS"
            } else {
                fileStatus = "OK"
            }

            lines.append(
                "  [\(fileStatus)] \(fileReport.sourceFile) "
                + "(total: \(fileReport.totalMutations), "
                + "killed: \(fileReport.killed), "
                + "survived: \(fileReport.survived), "
                + "build errors: \(fileReport.buildErrors), "
                + "kill: \(String(format: "%.1f", fileReport.killPercentage))%)"
            )
        }

        lines.append("")
        lines.append("== Summary ==")
        lines.append("Total mutations:  \(report.totalMutations)")
        lines.append("Killed:           \(report.killed)")
        lines.append("Survived:         \(report.survived)")
        lines.append("Timed out:        \(report.timedOut)")
        lines.append("Build errors:     \(report.buildErrors)")
        lines.append("Skipped:          \(report.skipped)")
        lines.append("Kill percentage:  \(String(format: "%.1f", report.killPercentage))%")
        lines.append("Files with survivors: \(report.filesWithSurvivors)")
        lines.append("")

        if report.survived > 0 {
            lines.append("SURVIVING MUTATIONS (test gaps):")
            for fileReport in report.fileReports where fileReport.survived > 0 {
                for result in fileReport.results where result.outcome == .survived {
                    let site = result.site
                    lines.append(
                        "  \(fileReport.sourceFile): Line \(site.line): "
                        + "\(site.mutationOperator.description) "
                        + "\"\(site.originalText)\" → \"\(site.mutatedText)\""
                    )
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
