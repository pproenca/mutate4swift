import Foundation

/// Manages backup/restore of source files during mutation testing.
public final class SourceFileManager: Sendable {
    private let filePath: String
    private var backupPath: String { filePath + ".mutate4swift.backup" }

    public init(filePath: String) {
        self.filePath = filePath
    }

    /// Creates a backup of the source file. Returns the original content.
    public func backup() throws -> String {
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        try content.write(toFile: backupPath, atomically: true, encoding: .utf8)
        return content
    }

    /// Restores from backup if one exists. Returns true if restored.
    @discardableResult
    public func restoreIfNeeded() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath) else { return false }
        do {
            let content = try String(contentsOfFile: backupPath, encoding: .utf8)
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            try fm.removeItem(atPath: backupPath)
            return true
        } catch {
            return false
        }
    }

    /// Writes mutated source to the file.
    public func writeMutated(_ source: String) throws {
        try source.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    /// Restores from backup, removing the backup file.
    public func restore() throws {
        let content = try String(contentsOfFile: backupPath, encoding: .utf8)
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: backupPath)
    }

    /// Removes the backup file.
    public func cleanupBackup() {
        try? FileManager.default.removeItem(atPath: backupPath)
    }

    /// Whether a stale backup exists (from a crashed run).
    public var hasStaleBackup: Bool {
        FileManager.default.fileExists(atPath: backupPath)
    }
}
