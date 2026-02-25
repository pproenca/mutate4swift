import XCTest
@testable import MutationEngine

final class RepositoryMutationReportTests: XCTestCase {
    func testAggregatesTotalsAcrossFiles() {
        let report = RepositoryMutationReport(
            packagePath: "/tmp/pkg",
            fileReports: [
                makeFileReport(
                    source: "A.swift",
                    outcomes: [.killed, .survived, .buildError],
                    baselineDuration: 1.2
                ),
                makeFileReport(
                    source: "B.swift",
                    outcomes: [.timeout, .killed, .skipped],
                    baselineDuration: 0.8
                ),
            ]
        )

        XCTAssertEqual(report.filesAnalyzed, 2)
        XCTAssertEqual(report.filesWithSurvivors, 1)
        XCTAssertEqual(report.totalMutations, 6)
        XCTAssertEqual(report.killed, 2)
        XCTAssertEqual(report.survived, 1)
        XCTAssertEqual(report.timedOut, 1)
        XCTAssertEqual(report.buildErrors, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.baselineDuration, 2.0, accuracy: 0.001)
        XCTAssertEqual(report.killPercentage, 75.0)
    }

    func testKillPercentageReturnsHundredWhenNoEffectiveMutations() {
        let report = RepositoryMutationReport(
            packagePath: "/tmp/pkg",
            fileReports: [
                makeFileReport(
                    source: "A.swift",
                    outcomes: [.buildError, .skipped],
                    baselineDuration: 1.0
                ),
            ]
        )

        XCTAssertEqual(report.killPercentage, 100.0)
    }

    func testCodableRoundTripRebuildsSummary() throws {
        let report = RepositoryMutationReport(
            packagePath: "/tmp/pkg",
            fileReports: [
                makeFileReport(
                    source: "A.swift",
                    outcomes: [.killed, .survived, .buildError],
                    baselineDuration: 1.25
                ),
                makeFileReport(
                    source: "B.swift",
                    outcomes: [.timeout, .killed, .skipped],
                    baselineDuration: 0.75
                ),
            ]
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(RepositoryMutationReport.self, from: data)

        XCTAssertEqual(decoded.packagePath, "/tmp/pkg")
        XCTAssertEqual(decoded.filesAnalyzed, 2)
        XCTAssertEqual(decoded.filesWithSurvivors, 1)
        XCTAssertEqual(decoded.baselineDuration, 2.0, accuracy: 0.001)
        XCTAssertEqual(decoded.totalMutations, 6)
        XCTAssertEqual(decoded.killed, 2)
        XCTAssertEqual(decoded.survived, 1)
        XCTAssertEqual(decoded.timedOut, 1)
        XCTAssertEqual(decoded.buildErrors, 1)
        XCTAssertEqual(decoded.skipped, 1)
        XCTAssertEqual(decoded.killPercentage, 75.0)
    }

    private func makeFileReport(
        source: String,
        outcomes: [MutationOutcome],
        baselineDuration: Double
    ) -> MutationReport {
        let site = MutationSite(
            mutationOperator: .arithmetic,
            line: 1, column: 1,
            utf8Offset: 0, utf8Length: 1,
            originalText: "+", mutatedText: "-"
        )

        return MutationReport(
            results: outcomes.map { MutationResult(site: site, outcome: $0) },
            sourceFile: source,
            baselineDuration: baselineDuration
        )
    }
}
