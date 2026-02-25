import Foundation
import XCTest
@testable import MutationEngine

final class TestFileMapperTests: XCTestCase {
    let mapper = TestFileMapper()

    func testTestFilterReturnsFilterWhenMatchingTestFileExists() throws {
        try withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            let testFile = packageRoot.appendingPathComponent("Tests/MyLibTests/CalculatorTests.swift")
            try writeFile(at: sourceFile)
            try writeFile(at: testFile)

            let filter = mapper.testFilter(forSourceFile: sourceFile.path)
            XCTAssertEqual(filter, "CalculatorTests")
        }
    }

    func testTestFilterFallsBackToTargetWhenMatchingTestFileDoesNotExist() throws {
        try withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            let testFile = packageRoot.appendingPathComponent("Tests/MyLibTests/SmokeTests.swift")
            try writeFile(at: sourceFile)
            try writeFile(at: testFile)

            let filter = mapper.testFilter(forSourceFile: sourceFile.path)
            XCTAssertEqual(filter, "MyLibTests")
        }
    }

    func testTestFilterUsesManifestMappedTargetWhenConventionDoesNotExist() throws {
        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "TmpPkg",
            targets: [
                .target(name: "MyLib"),
                .testTarget(name: "LibrarySpecs", dependencies: ["MyLib"]),
            ]
        )
        """

        try withTemporaryPackage(packageSwift: packageSwift) { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            let testFile = packageRoot.appendingPathComponent("Tests/LibrarySpecs/SmokeTests.swift")
            try writeFile(at: sourceFile)
            try writeFile(at: testFile)

            let filter = mapper.testFilter(forSourceFile: sourceFile.path)
            XCTAssertEqual(filter, "LibrarySpecs")
        }
    }

    func testTestFilterBuildsRegexForMultipleManifestTargets() throws {
        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "TmpPkg",
            targets: [
                .target(name: "MyLib"),
                .testTarget(name: "AlphaSpecs", dependencies: ["MyLib"]),
                .testTarget(name: "BetaSpecs", dependencies: ["MyLib"]),
            ]
        )
        """

        try withTemporaryPackage(packageSwift: packageSwift) { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            let alphaFile = packageRoot.appendingPathComponent("Tests/AlphaSpecs/SmokeTests.swift")
            let betaFile = packageRoot.appendingPathComponent("Tests/BetaSpecs/RegressionTests.swift")
            try writeFile(at: sourceFile)
            try writeFile(at: alphaFile)
            try writeFile(at: betaFile)

            let filter = mapper.testFilter(forSourceFile: sourceFile.path)
            XCTAssertEqual(filter, "^(AlphaSpecs|BetaSpecs)\\.")
        }
    }

    func testTestFilterReturnsNilWhenTestFileDoesNotExist() throws {
        try withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            try writeFile(at: sourceFile)

            let filter = mapper.testFilter(forSourceFile: sourceFile.path)
            XCTAssertNil(filter)
        }
    }

    func testTestFilterReturnsNilOutsideSwiftPackage() {
        let filter = mapper.testFilter(forSourceFile: "/path/to/Sources/MyLib/Calculator.swift")
        XCTAssertNil(filter)
    }

    func testTestFileReturnsExpectedPathWhenTestFileExists() throws {
        try withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            let expectedTestFile = packageRoot.appendingPathComponent("Tests/MyLibTests/CalculatorTests.swift")
            try writeFile(at: sourceFile)
            try writeFile(at: expectedTestFile)

            let mappedPath = mapper.testFile(
                forSourceFile: sourceFile.path,
                packagePath: packageRoot.path
            )

            XCTAssertEqual(mappedPath, expectedTestFile.path)
        }
    }

    func testTestFileReturnsNilWhenSourcePathHasNoSourcesComponent() throws {
        try withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Modules/MyLib/Calculator.swift")
            try writeFile(at: sourceFile)

            let mappedPath = mapper.testFile(
                forSourceFile: sourceFile.path,
                packagePath: packageRoot.path
            )

            XCTAssertNil(mappedPath)
        }
    }

    func testTestFileReturnsNilWhenSourcePathEndsAtSourcesDirectory() throws {
        try withTemporaryPackage { packageRoot in
            let sourcesDirectory = packageRoot.appendingPathComponent("Sources")
            try FileManager.default.createDirectory(
                at: sourcesDirectory,
                withIntermediateDirectories: true
            )

            let mappedPath = mapper.testFile(
                forSourceFile: sourcesDirectory.path,
                packagePath: packageRoot.path
            )

            XCTAssertNil(mappedPath)
        }
    }

    func testTestFileReturnsNilWhenExpectedTestFileDoesNotExist() throws {
        try withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            try writeFile(at: sourceFile)

            let mappedPath = mapper.testFile(
                forSourceFile: sourceFile.path,
                packagePath: packageRoot.path
            )

            XCTAssertNil(mappedPath)
        }
    }

    private func withTemporaryPackage(_ body: (URL) throws -> Void) throws {
        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "TmpPkg",
            targets: [
                .target(name: "MyLib"),
                .testTarget(name: "MyLibTests", dependencies: ["MyLib"]),
            ]
        )
        """
        try withTemporaryPackage(packageSwift: packageSwift, body)
    }

    private func withTemporaryPackage(
        packageSwift: String,
        _ body: (URL) throws -> Void
    ) throws {
        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestFileMapperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        try packageSwift.write(
            to: packageRoot.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        try body(packageRoot)
    }

    private func writeFile(at path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: path)
    }
}
