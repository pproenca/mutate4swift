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
            Mutate4SwiftError.noTestsExecuted(nil).errorDescription,
            "No tests were executed."
        )
        XCTAssertEqual(
            Mutate4SwiftError.noTestsExecuted("FooTests").errorDescription,
            "No tests were executed for filter 'FooTests'."
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
        XCTAssertEqual(
            Mutate4SwiftError.workingTreeDirty("/tmp/project").errorDescription,
            "Git working tree is dirty at /tmp/project. Commit or stash changes first."
        )
        XCTAssertEqual(
            Mutate4SwiftError.buildErrorRatioExceeded(actual: 0.4, limit: 0.2).errorDescription,
            "Build error ratio 40.00% exceeded limit 20.00%"
        )
    }
}
