import XCTest
@testable import MutationEngine

final class MutationReportTests: XCTestCase {

    // MARK: - Helpers

    private func site() -> MutationSite {
        MutationSite(
            mutationOperator: .arithmetic,
            line: 1, column: 1,
            utf8Offset: 0, utf8Length: 1,
            originalText: "+", mutatedText: "-"
        )
    }

    private func report(_ outcomes: [MutationOutcome]) -> MutationReport {
        MutationReport(
            results: outcomes.map { MutationResult(site: site(), outcome: $0) },
            sourceFile: "Test.swift",
            baselineDuration: 1.0
        )
    }

    // MARK: - Count properties

    func testKilledCount() {
        let r = report([.killed, .killed, .survived])
        XCTAssertEqual(r.killed, 2)
    }

    func testSurvivedCount() {
        let r = report([.killed, .survived, .survived])
        XCTAssertEqual(r.survived, 2)
    }

    func testTimedOutCount() {
        let r = report([.killed, .timeout, .timeout])
        XCTAssertEqual(r.timedOut, 2)
    }

    func testBuildErrorsCount() {
        let r = report([.buildError, .buildError, .killed])
        XCTAssertEqual(r.buildErrors, 2)
    }

    func testSkippedCount() {
        let r = report([.skipped, .killed, .skipped])
        XCTAssertEqual(r.skipped, 2)
    }

    func testTotalMutations() {
        let r = report([.killed, .survived, .timeout, .buildError, .skipped])
        XCTAssertEqual(r.totalMutations, 5)
    }

    // MARK: - Kill percentage

    func testKillPercentageAllKilled() {
        let r = report([.killed, .killed, .killed])
        XCTAssertEqual(r.killPercentage, 100.0)
    }

    func testKillPercentageNoneKilled() {
        let r = report([.survived, .survived])
        XCTAssertEqual(r.killPercentage, 0.0)
    }

    func testKillPercentageHalf() {
        let r = report([.killed, .survived])
        XCTAssertEqual(r.killPercentage, 50.0)
    }

    func testKillPercentageTimeoutsCountAsKilled() {
        // 1 killed + 1 timeout = 2 effective kills, 1 survived = 3 total effective
        let r = report([.killed, .timeout, .survived])
        XCTAssertEqual(r.killPercentage, 2.0 / 3.0 * 100.0)
    }

    func testKillPercentageExcludesBuildErrors() {
        // build errors don't count in denominator
        let r = report([.killed, .buildError])
        XCTAssertEqual(r.killPercentage, 100.0)
    }

    func testKillPercentageExcludesSkipped() {
        // skipped don't count in denominator
        let r = report([.survived, .skipped])
        XCTAssertEqual(r.killPercentage, 0.0)
    }

    func testKillPercentageEmptyReturns100() {
        let r = report([])
        XCTAssertEqual(r.killPercentage, 100.0)
    }

    func testKillPercentageOnlyBuildErrorsReturns100() {
        // no effective mutations → 100% by convention
        let r = report([.buildError, .buildError])
        XCTAssertEqual(r.killPercentage, 100.0)
    }

    func testKillPercentageMixedAll() {
        // 2 killed + 1 timeout + 1 survived = 4 effective, 3 kill-equivalent
        let r = report([.killed, .killed, .timeout, .survived, .buildError, .skipped])
        XCTAssertEqual(r.killPercentage, 3.0 / 4.0 * 100.0)
    }

    // MARK: - Counts distinguish outcomes correctly

    func testEachOutcomeCountedSeparately() {
        let r = report([.killed, .survived, .timeout, .buildError, .skipped])
        XCTAssertEqual(r.killed, 1)
        XCTAssertEqual(r.survived, 1)
        XCTAssertEqual(r.timedOut, 1)
        XCTAssertEqual(r.buildErrors, 1)
        XCTAssertEqual(r.skipped, 1)
    }

    func testCodableRoundTripRebuildsSummary() throws {
        let original = report([.killed, .survived, .timeout, .buildError, .skipped])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MutationReport.self, from: data)

        XCTAssertEqual(decoded.sourceFile, "Test.swift")
        XCTAssertEqual(decoded.baselineDuration, 1.0)
        XCTAssertEqual(decoded.totalMutations, 5)
        XCTAssertEqual(decoded.killed, 1)
        XCTAssertEqual(decoded.survived, 1)
        XCTAssertEqual(decoded.timedOut, 1)
        XCTAssertEqual(decoded.buildErrors, 1)
        XCTAssertEqual(decoded.skipped, 1)
        XCTAssertEqual(decoded.killPercentage, 2.0 / 3.0 * 100.0)
    }
}
