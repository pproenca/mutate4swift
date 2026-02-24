import Foundation

public enum Mutate4SwiftError: Error, LocalizedError {
    case sourceFileNotFound(String)
    case packagePathNotFound(String)
    case baselineTestsFailed
    case backupRestoreFailed(String)
    case coverageDataUnavailable
    case invalidSourceFile(String)

    public var errorDescription: String? {
        switch self {
        case .sourceFileNotFound(let path):
            return "Source file not found: \(path)"
        case .packagePathNotFound(let path):
            return "Package path not found: \(path)"
        case .baselineTestsFailed:
            return "Baseline tests failed — all tests must pass before mutation testing"
        case .backupRestoreFailed(let path):
            return "Failed to restore backup: \(path)"
        case .coverageDataUnavailable:
            return "Code coverage data is unavailable"
        case .invalidSourceFile(let reason):
            return "Invalid source file: \(reason)"
        }
    }
}
