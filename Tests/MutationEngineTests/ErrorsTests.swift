import XCTest
@testable import MutationEngine

final class ErrorsTests: XCTestCase {
    func testErrorDescriptions() {
        XCTAssertEqual(
            Mutate4SwiftError.sourceFileNotFound("/tmp/A.swift").errorDescription,
            "Source file not found: /tmp/A.swift"
        )
        XCTAssertEqual(
            Mutate4SwiftError.packagePathNotFound("/tmp/pkg").errorDescription,
            "Package path not found: /tmp/pkg"
        )
        XCTAssertEqual(
            Mutate4SwiftError.baselineTestsFailed.errorDescription,
            "Baseline tests failed — all tests must pass before mutation testing"
        )
        XCTAssertEqual(
            Mutate4SwiftError.backupRestoreFailed("/tmp/A.swift").errorDescription,
            "Failed to restore backup: /tmp/A.swift"
        )
        XCTAssertEqual(
            Mutate4SwiftError.coverageDataUnavailable.errorDescription,
            "Code coverage data is unavailable"
        )
        XCTAssertEqual(
            Mutate4SwiftError.invalidSourceFile("bad").errorDescription,
            "Invalid source file: bad"
        )
    }
}
