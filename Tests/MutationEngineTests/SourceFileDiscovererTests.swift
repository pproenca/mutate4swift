import Foundation
import XCTest
@testable import MutationEngine

final class SourceFileDiscovererTests: XCTestCase {
    let discoverer = SourceFileDiscoverer()

    func testDiscoverSourceFilesReturnsSortedSwiftFiles() throws {
        try withTemporaryDirectory { packageRoot in
            let first = packageRoot.appendingPathComponent("Sources/Beta/Second.swift")
            let second = packageRoot.appendingPathComponent("Sources/Alpha/First.swift")
            let backup = packageRoot.appendingPathComponent("Sources/Alpha/First.swift.mutate4swift.backup")
            let nonSwift = packageRoot.appendingPathComponent("Sources/Alpha/Note.txt")

            try writeFile(at: first)
            try writeFile(at: second)
            try writeFile(at: backup)
            try writeFile(at: nonSwift)

            let files = try discoverer.discoverSourceFiles(in: packageRoot.path)
            let fileNames = files.map { URL(fileURLWithPath: $0).lastPathComponent }

            XCTAssertEqual(fileNames, ["First.swift", "Second.swift"])
            XCTAssertFalse(files.contains { $0.hasSuffix(".mutate4swift.backup") })
            XCTAssertFalse(files.contains { $0.hasSuffix(".txt") })
        }
    }

    func testDiscoverSourceFilesThrowsWhenSourcesDirectoryMissing() throws {
        try withTemporaryDirectory { packageRoot in
            XCTAssertThrowsError(try discoverer.discoverSourceFiles(in: packageRoot.path)) { error in
                guard case .invalidSourceFile(let reason) = error as? Mutate4SwiftError else {
                    XCTFail("Expected invalidSourceFile, got \(error)")
                    return
                }
                XCTAssertTrue(reason.contains("Missing Sources directory"))
            }
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceFileDiscovererTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try body(tempDir)
    }

    private func writeFile(at path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: path)
    }
}
