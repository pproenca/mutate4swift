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
        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestFileMapperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageRoot) }

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
