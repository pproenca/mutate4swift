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
}
