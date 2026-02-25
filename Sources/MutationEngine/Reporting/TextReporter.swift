import Foundation

public struct TextReporter: Sendable {
    public init() {}

    public func report(_ report: MutationReport) -> String {
        var lines: [String] = []

        lines.append("")
        lines.append("== Mutation Testing Report ==")
        lines.append("Source: \(report.sourceFile)")
        lines.append("Baseline duration: \(String(format: "%.2f", report.baselineDuration))s")
        lines.append("")

        // Per-mutation details
        for result in report.results {
            let site = result.site
            let status: String
            switch result.outcome {
            case .killed: status = "KILLED"
            case .survived: status = "SURVIVED"
            case .timeout: status = "TIMEOUT"
            case .buildError: status = "BUILD_ERROR"
            case .skipped: status = "SKIPPED"
            }

            lines.append(
                "  [\(status)] Line \(site.line): "
                + "\(site.mutationOperator.description) "
                + "\"\(site.originalText)\" → \"\(site.mutatedText)\""
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
        lines.append("")

        if report.survived > 0 {
            lines.append("SURVIVING MUTATIONS (test gaps):")
            for result in report.results where result.outcome == .survived {
                let site = result.site
                lines.append(
                    "  Line \(site.line): "
                    + "\(site.mutationOperator.description) "
                    + "\"\(site.originalText)\" → \"\(site.mutatedText)\""
                )
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
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
