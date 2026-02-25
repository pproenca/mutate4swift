import Foundation

struct ReadinessScorecard {
    enum GateStatus {
        case passed(String)
        case failed(String)
        case skipped(String)

        var label: String {
            switch self {
            case .passed:
                return "PASS"
            case .failed:
                return "FAIL"
            case .skipped:
                return "SKIP"
            }
        }

        var detail: String {
            switch self {
            case .passed(let message), .failed(let message), .skipped(let message):
                return message
            }
        }
    }

    let runnerMode: String
    let maxBuildErrorRatio: Double
    let allMode: Bool

    var baselineGate: GateStatus = .skipped("Not evaluated yet")
    var noTestsGate: GateStatus = .skipped("Not evaluated yet")
    var buildErrorBudgetGate: GateStatus = .skipped("Not evaluated yet")
    var restoreGuaranteeGate: GateStatus = .skipped("Not evaluated yet")
    var workspaceSafetyGate: GateStatus = .skipped("Disabled")
    var scaleEfficiencyGate: GateStatus = .skipped("Single-file mode")
    var runnerSupportGate: GateStatus

    init(runnerMode: String, maxBuildErrorRatio: Double, allMode: Bool, requireCleanWorkingTree: Bool) {
        self.runnerMode = runnerMode
        self.maxBuildErrorRatio = maxBuildErrorRatio
        self.allMode = allMode
        self.runnerSupportGate = .passed("Runner mode '\(runnerMode)' is active")
        if requireCleanWorkingTree {
            self.workspaceSafetyGate = .skipped("Pending git cleanliness check")
        }
        if allMode {
            self.scaleEfficiencyGate = .skipped("Pending batch execution metrics")
        }
    }

    func render() -> String {
        let lines = [
            "== Readiness Scorecard ==",
            "Runner mode: \(runnerMode)",
            formatGate(
                name: "Baseline gate",
                status: baselineGate
            ),
            formatGate(
                name: "No-tests gate",
                status: noTestsGate
            ),
            formatGate(
                name: "Build-error budget",
                status: buildErrorBudgetGate
            ),
            formatGate(
                name: "Restore guarantee",
                status: restoreGuaranteeGate
            ),
            formatGate(
                name: "Workspace safety",
                status: workspaceSafetyGate
            ),
            formatGate(
                name: "Scale efficiency",
                status: scaleEfficiencyGate
            ),
            formatGate(
                name: "Runner support",
                status: runnerSupportGate
            ),
        ]

        return lines.joined(separator: "\n")
    }

    private func formatGate(name: String, status: GateStatus) -> String {
        "[\(status.label)] \(name): \(status.detail)"
    }
}
