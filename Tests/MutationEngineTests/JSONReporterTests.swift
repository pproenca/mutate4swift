import XCTest
@testable import MutationEngine

final class JSONReporterTests: XCTestCase {
    let reporter = JSONReporter()

    func testRepositoryReportEncodesFileReports() {
        let site = MutationSite(
            mutationOperator: .arithmetic,
            line: 1, column: 1,
            utf8Offset: 0, utf8Length: 1,
            originalText: "+", mutatedText: "-"
        )

        let repositoryReport = RepositoryMutationReport(
            packagePath: "/tmp/pkg",
            fileReports: [
                MutationReport(
                    results: [MutationResult(site: site, outcome: .survived)],
                    sourceFile: "Sources/Foo.swift",
                    baselineDuration: 0.5
                ),
            ]
        )

        let json = reporter.report(repositoryReport)

        XCTAssertTrue(json.contains("\"packagePath\""))
        XCTAssertTrue(json.contains("\"fileReports\""))
        XCTAssertTrue(json.contains("\"sourceFile\""))
        XCTAssertTrue(json.contains("\"survived\""))
    }

    func testReportReturnsEmptyObjectWhenEncodingFails() {
        let report = MutationReport(
            results: [],
            sourceFile: "Sources/Foo.swift",
            baselineDuration: .nan
        )

        XCTAssertEqual(reporter.report(report), "{}")
    }
}
