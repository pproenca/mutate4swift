import XCTest
@testable import MutationEngine

final class BaselineResultTests: XCTestCase {
    func testTimeoutUsesMinimumOfThirtySeconds() {
        let result = BaselineResult(duration: 1.0, timeoutMultiplier: 10.0)
        XCTAssertEqual(result.timeout, 30.0)
    }

    func testTimeoutUsesDurationMultiplierWhenAboveMinimum() {
        let result = BaselineResult(duration: 5.0, timeoutMultiplier: 10.0)
        XCTAssertEqual(result.timeout, 50.0)
    }
}
