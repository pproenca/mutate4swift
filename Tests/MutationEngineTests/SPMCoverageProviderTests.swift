import Foundation
import XCTest
@testable import MutationEngine

final class SPMCoverageProviderTests: XCTestCase {
    func testParseCoverageExtractsCoveredLines() throws {
        let provider = SPMCoverageProvider()
        let filePath = "/tmp/File.swift"

        let json = """
        {
          "data": [{
            "files": [{
              "filename": "\(filePath)",
              "segments": [
                [1, 0, 3, 0, 0],
                [2, 0, 0, 0, 0],
                [4, 0, 1, 0, 0]
              ]
            }]
          }]
        }
        """

        let coverageFile = try temporaryFile(named: "coverage.json", contents: json)
        defer { try? FileManager.default.removeItem(at: coverageFile) }

        let covered = try provider.parseCoverage(codecovPath: coverageFile.path, filePath: filePath)
        XCTAssertEqual(covered, [1, 4])
    }

    func testParseCoverageReturnsEmptyForUnmatchedFile() throws {
        let provider = SPMCoverageProvider()
        let json = """
        { "data": [{ "files": [{ "filename": "/tmp/Other.swift", "segments": [[1,0,1,0,0]] }] }] }
        """

        let coverageFile = try temporaryFile(named: "coverage.json", contents: json)
        defer { try? FileManager.default.removeItem(at: coverageFile) }

        let covered = try provider.parseCoverage(codecovPath: coverageFile.path, filePath: "/tmp/File.swift")
        XCTAssertTrue(covered.isEmpty)
    }

    func testParseCoverageThrowsOnInvalidJSON() throws {
        let provider = SPMCoverageProvider()
        let coverageFile = try temporaryFile(named: "coverage.json", contents: "{}")
        defer { try? FileManager.default.removeItem(at: coverageFile) }

        XCTAssertThrowsError(
            try provider.parseCoverage(codecovPath: coverageFile.path, filePath: "/tmp/File.swift")
        ) { error in
            guard case .coverageDataUnavailable = error as? Mutate4SwiftError else {
                XCTFail("Expected coverageDataUnavailable, got \(error)")
                return
            }
        }
    }

    func testFindCodecovJSONThrowsWhenProfdataMissing() throws {
        let provider = SPMCoverageProvider()
        try withTemporaryDirectory { packagePath in
            XCTAssertThrowsError(
                try provider.findCodecovJSON(
                    buildPath: packagePath.appendingPathComponent(".build").path,
                    packagePath: packagePath.path
                )
            ) { error in
                guard case .coverageDataUnavailable = error as? Mutate4SwiftError else {
                    XCTFail("Expected coverageDataUnavailable, got \(error)")
                    return
                }
            }
        }
    }

    func testFindCodecovJSONThrowsWhenNoTestBinaryExists() throws {
        let provider = SPMCoverageProvider()
        try withTemporaryDirectory { packagePath in
            let buildPath = packagePath.appendingPathComponent(".build")
            let profdata = buildPath.appendingPathComponent("debug/codecov/default.profdata")
            try write("", to: profdata)

            XCTAssertThrowsError(
                try provider.findCodecovJSON(
                    buildPath: buildPath.path,
                    packagePath: packagePath.path
                )
            ) { error in
                guard case .coverageDataUnavailable = error as? Mutate4SwiftError else {
                    XCTFail("Expected coverageDataUnavailable, got \(error)")
                    return
                }
            }
        }
    }

    func testFindCodecovJSONUsesAltBinaryAndFailsExportForInvalidBinary() throws {
        let provider = SPMCoverageProvider()
        try withTemporaryDirectory { packagePath in
            let buildPath = packagePath.appendingPathComponent(".build")
            let profdata = buildPath.appendingPathComponent("debug/codecov/default.profdata")
            try write("", to: profdata)

            let packageName = packagePath.lastPathComponent
            let altBinary = buildPath.appendingPathComponent("debug/\(packageName)PackageTests")
            try write("not a Mach-O binary", to: altBinary)

            XCTAssertThrowsError(
                try provider.findCodecovJSON(
                    buildPath: buildPath.path,
                    packagePath: packagePath.path
                )
            ) { error in
                guard case .coverageDataUnavailable = error as? Mutate4SwiftError else {
                    XCTFail("Expected coverageDataUnavailable, got \(error)")
                    return
                }
            }
        }
    }

    func testCoveredLinesFailsForInvalidPackagePath() {
        let provider = SPMCoverageProvider()
        XCTAssertThrowsError(
            try provider.coveredLines(forFile: "/tmp/Nope.swift", packagePath: "/tmp/does-not-exist-\(UUID().uuidString)")
        ) { error in
            guard case .coverageDataUnavailable = error as? Mutate4SwiftError else {
                XCTFail("Expected coverageDataUnavailable, got \(error)")
                return
            }
        }
    }

    func testCoveredLinesIntegrationReturnsNonEmptyCoverage() throws {
        try withTemporarySwiftPackage { packagePath, sourceFile in
            let provider = SPMCoverageProvider()
            let covered = try provider.coveredLines(
                forFile: sourceFile.path,
                packagePath: packagePath.path
            )

            XCTAssertFalse(covered.isEmpty)
            XCTAssertFalse(covered.intersection([2, 3, 4]).isEmpty)
        }
    }

    private func withTemporarySwiftPackage(
        _ body: (URL, URL) throws -> Void
    ) throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        let packageName = "SPMCov\(suffix)"
        let packagePath = URL(fileURLWithPath: "/tmp").appendingPathComponent(packageName)
        try? FileManager.default.removeItem(at: packagePath)
        try FileManager.default.createDirectory(at: packagePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packagePath) }

        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(packageName)",
            products: [
                .library(name: "\(packageName)", targets: ["\(packageName)"]),
            ],
            targets: [
                .target(name: "\(packageName)"),
                .testTarget(name: "\(packageName)Tests", dependencies: ["\(packageName)"]),
            ]
        )
        """

        let sourceFile = packagePath.appendingPathComponent("Sources/\(packageName)/\(packageName).swift")
        let source = """
        public enum \(packageName) {
            public static func value() -> Int {
                42
            }
        }
        """

        let tests = """
        import XCTest
        @testable import \(packageName)

        final class \(packageName)Tests: XCTestCase {
            func testValue() {
                XCTAssertEqual(\(packageName).value(), 42)
            }
        }
        """

        try write(packageSwift, to: packagePath.appendingPathComponent("Package.swift"))
        try write(source, to: sourceFile)
        try write(tests, to: packagePath.appendingPathComponent("Tests/\(packageName)Tests/\(packageName)Tests.swift"))

        try body(packagePath, sourceFile)
    }

    private func temporaryFile(named name: String, contents: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPMCoverageProviderTests-\(UUID().uuidString)-\(name)")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPMCoverageProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func write(_ content: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: path, atomically: true, encoding: .utf8)
    }
}
