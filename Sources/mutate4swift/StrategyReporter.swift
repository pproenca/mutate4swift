import Foundation
import MutationEngine

enum StrategyReporter {
    static func textReport(for plan: MutationStrategyPlan) -> String {
        var lines: [String] = []
        lines.append("== Mutation Strategy Plan ==")
        lines.append("Jobs requested: \(plan.jobsRequested)")
        lines.append("Jobs planned: \(plan.jobsPlanned)")
        lines.append("Analyzed files: \(plan.analyzedFiles)")
        lines.append("Files with candidate mutations: \(plan.filesWithCandidateMutations)")
        lines.append("Potential mutations: \(plan.totalPotentialMutations)")
        lines.append("Candidate mutations: \(plan.totalCandidateMutations)")
        lines.append("Theoretical lower bound (work units): \(plan.theoreticalLowerBound)")
        lines.append("Estimated speedup upper bound: \(String(format: "%.2f", plan.estimatedSpeedupUpperBound))x")
        lines.append("")

        let uncovered = plan.uncoveredFiles
        lines.append("Uncovered files (potential > 0, candidate = 0): \(uncovered.count)")
        if !uncovered.isEmpty {
            for file in uncovered {
                lines.append("  - \(file)")
            }
        }
        lines.append("")

        lines.append("Scope weights:")
        let sortedScopes = plan.scopeWeights
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
        for (scope, weight) in sortedScopes {
            lines.append("  - \(scope): \(weight)")
        }
        lines.append("")

        lines.append("Execution buckets:")
        for bucket in plan.buckets {
            lines.append("  Worker \(bucket.workerIndex + 1): weight \(bucket.totalWeight), files \(bucket.workloads.count)")
            for workload in bucket.workloads {
                lines.append(
                    "    - \(workload.sourceFile) [candidate=\(workload.candidateMutations), potential=\(workload.potentialMutations), scope=\(workload.scopeKey)]"
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    static func jsonReport(for plan: MutationStrategyPlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(plan) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
