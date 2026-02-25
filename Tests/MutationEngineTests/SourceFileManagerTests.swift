import Foundation
import XCTest
@testable import MutationEngine

final class SourceFileManagerTests: XCTestCase {
    func testBackupAndRestoreFlow() throws {
        try withTemporaryFile(initial: "original") { fileURL in
            let manager = SourceFileManager(filePath: fileURL.path)

            let original = try manager.backup()
            XCTAssertEqual(original, "original")
            XCTAssertTrue(manager.hasStaleBackup)

            try manager.writeMutated("mutated")
            let mutated = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertEqual(mutated, "mutated")

            try manager.restore()
            let restored = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertEqual(restored, "original")
            XCTAssertFalse(manager.hasStaleBackup)
        }
    }

    func testRestoreIfNeededReturnsFalseWhenNoBackup() throws {
        try withTemporaryFile(initial: "source") { fileURL in
            let manager = SourceFileManager(filePath: fileURL.path)
            XCTAssertFalse(manager.restoreIfNeeded())
        }
    }

    func testRestoreIfNeededRestoresAndRemovesBackup() throws {
        try withTemporaryFile(initial: "source") { fileURL in
            let manager = SourceFileManager(filePath: fileURL.path)
            _ = try manager.backup()
            try manager.writeMutated("changed")

            XCTAssertTrue(manager.restoreIfNeeded())

            let restored = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertEqual(restored, "source")
            XCTAssertFalse(manager.hasStaleBackup)
        }
    }

    func testRestoreIfNeededReturnsFalseOnWriteFailure() throws {
        try withTemporaryDirectory { tempDir in
            let sourcePath = tempDir.appendingPathComponent("source.swift").path
            let backupPath = sourcePath + ".mutate4swift.backup"

            try FileManager.default.createDirectory(atPath: sourcePath, withIntermediateDirectories: true)
            try "backup".write(toFile: backupPath, atomically: true, encoding: .utf8)

            let manager = SourceFileManager(filePath: sourcePath)
            XCTAssertTrue(manager.hasStaleBackup)
            XCTAssertFalse(manager.restoreIfNeeded())
            XCTAssertTrue(manager.hasStaleBackup)
        }
    }

    func testCleanupBackupRemovesBackupFile() throws {
        try withTemporaryFile(initial: "source") { fileURL in
            let manager = SourceFileManager(filePath: fileURL.path)
            _ = try manager.backup()
            XCTAssertTrue(manager.hasStaleBackup)

            manager.cleanupBackup()
            XCTAssertFalse(manager.hasStaleBackup)
        }
    }

    private func withTemporaryFile(initial: String, body: (URL) throws -> Void) throws {
        try withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("Sample.swift")
            try initial.write(to: fileURL, atomically: true, encoding: .utf8)
            try body(fileURL)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceFileManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
