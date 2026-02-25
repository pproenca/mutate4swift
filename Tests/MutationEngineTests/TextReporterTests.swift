import XCTest
@testable import MutationEngine

final class TextReporterTests: XCTestCase {
    let reporter = TextReporter()

    func testReportContainsSummary() {
        let report = MutationReport(
            results: [
                MutationResult(
                    site: MutationSite(
                        mutationOperator: .arithmetic,
                        line: 5, column: 10,
                        utf8Offset: 40, utf8Length: 1,
                        originalText: "+", mutatedText: "-"
                    ),
                    outcome: .killed
                ),
                MutationResult(
                    site: MutationSite(
                        mutationOperator: .boolean,
                        line: 10, column: 15,
                        utf8Offset: 80, utf8Length: 4,
                        originalText: "true", mutatedText: "false"
                    ),
                    outcome: .survived
                ),
            ],
            sourceFile: "Calculator.swift",
            baselineDuration: 1.5
        )

        let output = reporter.report(report)

        XCTAssertTrue(output.contains("Mutation Testing Report"))
        XCTAssertTrue(output.contains("Calculator.swift"))
        XCTAssertTrue(output.contains("Total mutations:  2"))
        XCTAssertTrue(output.contains("Killed:           1"))
        XCTAssertTrue(output.contains("Survived:         1"))
        XCTAssertTrue(output.contains("Kill percentage:  50.0%"))
        XCTAssertTrue(output.contains("SURVIVING MUTATIONS"))
    }

    func testReportAllKilled() {
        let report = MutationReport(
            results: [
                MutationResult(
                    site: MutationSite(
                        mutationOperator: .arithmetic,
                        line: 5, column: 10,
                        utf8Offset: 40, utf8Length: 1,
                        originalText: "+", mutatedText: "-"
                    ),
                    outcome: .killed
                ),
            ],
            sourceFile: "Foo.swift",
            baselineDuration: 0.5
        )

        let output = reporter.report(report)
        XCTAssertTrue(output.contains("Kill percentage:  100.0%"))
        XCTAssertFalse(output.contains("SURVIVING MUTATIONS"))
    }

    func testReportBuildErrorsExcludedFromPercentage() {
        let report = MutationReport(
            results: [
                MutationResult(
                    site: MutationSite(
                        mutationOperator: .returnValue,
                        line: 3, column: 5,
                        utf8Offset: 20, utf8Length: 10,
                        originalText: "return 42", mutatedText: "return"
                    ),
                    outcome: .buildError
                ),
                MutationResult(
                    site: MutationSite(
                        mutationOperator: .arithmetic,
                        line: 5, column: 10,
                        utf8Offset: 40, utf8Length: 1,
                        originalText: "+", mutatedText: "-"
                    ),
                    outcome: .killed
                ),
            ],
            sourceFile: "Foo.swift",
            baselineDuration: 0.5
        )

        // Build errors excluded: 1 killed / 1 effective = 100%
        XCTAssertEqual(report.killPercentage, 100.0)
    }

    func testRepositoryReportContainsAggregateSummary() {
        let site = MutationSite(
            mutationOperator: .arithmetic,
            line: 5, column: 10,
            utf8Offset: 40, utf8Length: 1,
            originalText: "+", mutatedText: "-"
        )

        let repositoryReport = RepositoryMutationReport(
            packagePath: "/tmp/mutate4swift",
            fileReports: [
                MutationReport(
                    results: [MutationResult(site: site, outcome: .killed)],
                    sourceFile: "Sources/A.swift",
                    baselineDuration: 1.0
                ),
                MutationReport(
                    results: [MutationResult(site: site, outcome: .survived)],
                    sourceFile: "Sources/B.swift",
                    baselineDuration: 2.0
                ),
            ]
        )

        let output = reporter.report(repositoryReport)

        XCTAssertTrue(output.contains("Mutation Testing Report (Repository)"))
        XCTAssertTrue(output.contains("Package: /tmp/mutate4swift"))
        XCTAssertTrue(output.contains("Files analyzed: 2"))
        XCTAssertTrue(output.contains("[SURVIVED] Sources/B.swift"))
        XCTAssertTrue(output.contains("Total mutations:  2"))
        XCTAssertTrue(output.contains("Kill percentage:  50.0%"))
        XCTAssertTrue(output.contains("Files with survivors: 1"))
        XCTAssertTrue(output.contains("SURVIVING MUTATIONS"))
    }
}
