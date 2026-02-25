import Foundation

public enum Mutate4SwiftError: Error, LocalizedError {
    case sourceFileNotFound(String)
    case packagePathNotFound(String)
    case baselineTestsFailed
    case noTestsExecuted(String?)
    case backupRestoreFailed(String)
    case coverageDataUnavailable
    case invalidSourceFile(String)
    case buildErrorRatioExceeded(actual: Double, limit: Double)
    case workingTreeDirty(String)

    public var errorDescription: String? {
        switch self {
        case .sourceFileNotFound(let path):
            return "Source file not found: \(path)"
        case .packagePathNotFound(let path):
            return "Package path not found: \(path)"
        case .baselineTestsFailed:
            return "Baseline tests failed — all tests must pass before mutation testing"
        case .noTestsExecuted(let filter):
            if let filter {
                return "No tests were executed for filter '\(filter)'."
            }
            return "No tests were executed."
        case .backupRestoreFailed(let path):
            return "Failed to restore backup: \(path)"
        case .coverageDataUnavailable:
            return "Code coverage data is unavailable"
        case .invalidSourceFile(let reason):
            return "Invalid source file: \(reason)"
        case .buildErrorRatioExceeded(let actual, let limit):
            return "Build error ratio \(String(format: "%.2f", actual * 100))% exceeded limit \(String(format: "%.2f", limit * 100))%"
        case .workingTreeDirty(let root):
            return "Git working tree is dirty at \(root). Commit or stash changes first."
        }
    }
}
