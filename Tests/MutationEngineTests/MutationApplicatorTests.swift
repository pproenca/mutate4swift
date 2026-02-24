import XCTest
@testable import MutationEngine

final class MutationApplicatorTests: XCTestCase {
    let applicator = MutationApplicator()

    func testApplyArithmeticMutation() {
        let source = "let x = a + b"
        let discoverer = MutationDiscoverer(source: source)
        let sites = discoverer.discoverSites().filter { $0.mutationOperator == .arithmetic }
        XCTAssertEqual(sites.count, 1)

        let mutated = applicator.apply(sites[0], to: source)
        XCTAssertEqual(mutated, "let x = a - b")
    }

    func testApplyBooleanMutation() {
        let source = "let flag = true"
        let discoverer = MutationDiscoverer(source: source)
        let sites = discoverer.discoverSites().filter { $0.mutationOperator == .boolean }
        XCTAssertEqual(sites.count, 1)

        let mutated = applicator.apply(sites[0], to: source)
        XCTAssertEqual(mutated, "let flag = false")
    }

    func testApplyComparisonMutation() {
        let source = "if x > 5 {}"
        let discoverer = MutationDiscoverer(source: source)
        let sites = discoverer.discoverSites().filter { $0.mutationOperator == .comparison }
        XCTAssertEqual(sites.count, 1)

        let mutated = applicator.apply(sites[0], to: source)
        XCTAssertEqual(mutated, "if x >= 5 {}")
    }

    func testApplyConstantMutation() {
        let source = "let x = 0"
        let discoverer = MutationDiscoverer(source: source)
        let sites = discoverer.discoverSites().filter { $0.mutationOperator == .constant }
        XCTAssertEqual(sites.count, 1)

        let mutated = applicator.apply(sites[0], to: source)
        XCTAssertEqual(mutated, "let x = 1")
    }

    func testApplyUnaryRemovalMutation() {
        let source = "let x = !flag"
        let discoverer = MutationDiscoverer(source: source)
        let sites = discoverer.discoverSites().filter { $0.mutationOperator == .unaryRemoval }
        XCTAssertEqual(sites.count, 1)

        let mutated = applicator.apply(sites[0], to: source)
        XCTAssertEqual(mutated, "let x = flag")
    }

    func testApplyDoesNotCorruptMultibyteUTF8() {
        // Use true in actual code, not in a comment
        let source = "let emoji = \"🎉\"; let flag = true"
        let discoverer = MutationDiscoverer(source: source)
        let sites = discoverer.discoverSites().filter { $0.mutationOperator == .boolean }
        XCTAssertEqual(sites.count, 1)

        let mutated = applicator.apply(sites[0], to: source)
        XCTAssertTrue(mutated.contains("🎉"))
        XCTAssertTrue(mutated.contains("false"))
    }

    func testApplyAtOffsetZero() {
        // Mutation at the very start of the file (offset 0)
        let site = MutationSite(
            mutationOperator: .boolean,
            line: 1,
            column: 1,
            utf8Offset: 0,
            utf8Length: 4,
            originalText: "true",
            mutatedText: "false"
        )
        let source = "true && other"
        let result = applicator.apply(site, to: source)
        XCTAssertEqual(result, "false && other")
    }

    func testApplyNegativeOffsetReturnsOriginal() {
        let site = MutationSite(
            mutationOperator: .boolean,
            line: 1,
            column: 1,
            utf8Offset: -1,
            utf8Length: 4,
            originalText: "true",
            mutatedText: "false"
        )
        let source = "let x = true"
        let result = applicator.apply(site, to: source)
        XCTAssertEqual(result, source)
    }

    func testApplyOutOfBoundsReturnsOriginal() {
        let site = MutationSite(
            mutationOperator: .boolean,
            line: 1,
            column: 1,
            utf8Offset: 9999,
            utf8Length: 4,
            originalText: "true",
            mutatedText: "false"
        )
        let source = "let x = true"
        let result = applicator.apply(site, to: source)
        XCTAssertEqual(result, source)
    }
}
