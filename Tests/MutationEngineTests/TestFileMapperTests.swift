import Foundation
import XCTest
@testable import MutationEngine

final class TestFileMapperTests: XCTestCase {
    let mapper = TestFileMapper()

    func testTestFilterFromSourceFile() {
        let filter = mapper.testFilter(forSourceFile: "/path/to/Sources/MyLib/Calculator.swift")
        XCTAssertEqual(filter, "CalculatorTests")
    }

    func testTestFilterFromNestedSourceFile() {
        let filter = mapper.testFilter(forSourceFile: "/path/to/Sources/MyLib/Utils/Helper.swift")
        XCTAssertEqual(filter, "HelperTests")
    }

    func testTestFilterStripsExtension() {
        let filter = mapper.testFilter(forSourceFile: "Foo.swift")
        XCTAssertEqual(filter, "FooTests")
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
