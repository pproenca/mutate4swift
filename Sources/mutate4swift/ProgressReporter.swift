import Foundation
import MutationEngine

final class ProgressReporter: @unchecked Sendable {
    private struct OutcomeTally {
        var killed = 0
        var survived = 0
        var timedOut = 0
        var buildErrors = 0

        mutating func record(_ outcome: MutationOutcome) {
            switch outcome {
            case .killed:
                killed += 1
            case .survived:
                survived += 1
            case .timeout:
                timedOut += 1
            case .buildError:
                buildErrors += 1
            case .skipped:
                break
            }
        }
    }

    private let enabled: Bool
    private let startTime: Date
    private let lock = NSLock()
    private var talliesByContext: [String: OutcomeTally] = [:]

    init(enabled: Bool) {
        self.enabled = enabled
        self.startTime = Date()
    }

    func stage(_ message: String) {
        emit(message)
    }

    func record(event: OrchestratorProgressEvent, context: String) {
        guard enabled else { return }

        lock.lock()
        defer { lock.unlock() }

        switch event {
        case .candidateSitesDiscovered(let count):
            emitLocked("[\(context)] candidate mutations: \(count)")
        case .baselineStarted(let filter):
            if let filter, !filter.isEmpty {
                emitLocked("[\(context)] baseline: running tests (filter: \(filter))")
            } else {
                emitLocked("[\(context)] baseline: running tests")
            }
        case .baselineFinished(let duration, let timeout):
            emitLocked(
                "[\(context)] baseline: passed in \(fmt(duration))s (timeout \(fmt(timeout))s)"
            )
        case .mutationEvaluated(let index, let total, let site, let outcome):
            var tally = talliesByContext[context] ?? OutcomeTally()
            tally.record(outcome)
            talliesByContext[context] = tally
            emitLocked(
                "[\(context)] [\(index)/\(total)] line \(site.line) \(site.mutationOperator.description) -> \(label(for: outcome)) "
                + "(K:\(tally.killed) S:\(tally.survived) T:\(tally.timedOut) B:\(tally.buildErrors))"
            )
        }
    }

    private func emit(_ message: String) {
        guard enabled else { return }
        lock.lock()
        emitLocked(message)
        lock.unlock()
    }

    private func emitLocked(_ message: String) {
        let elapsed = Date().timeIntervalSince(startTime)
        let line = "[+\(fmt(elapsed))s] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
    }

    private func fmt(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }

    private func label(for outcome: MutationOutcome) -> String {
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
}
