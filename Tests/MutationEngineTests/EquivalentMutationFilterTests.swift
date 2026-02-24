import XCTest
@testable import MutationEngine

final class EquivalentMutationFilterTests: XCTestCase {
    let filter = EquivalentMutationFilter()

    func testDoesNotFilterDistinctMutations() {
        let sites = [
            MutationSite(
                mutationOperator: .arithmetic,
                line: 1, column: 10,
                utf8Offset: 9, utf8Length: 1,
                originalText: "+", mutatedText: "-"
            ),
        ]
        let filtered = filter.filter(sites, source: "let x = a + b")
        XCTAssertEqual(filtered.count, 1)
    }

    func testFiltersIdenticalMutation() {
        let sites = [
            MutationSite(
                mutationOperator: .arithmetic,
                line: 1, column: 10,
                utf8Offset: 9, utf8Length: 1,
                originalText: "+", mutatedText: "+"
            ),
        ]
        let filtered = filter.filter(sites, source: "let x = a + b")
        XCTAssertEqual(filtered.count, 0)
    }
}
