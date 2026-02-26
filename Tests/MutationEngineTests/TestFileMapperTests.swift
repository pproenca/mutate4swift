import Foundation
import XCTest
@testable import MutationEngine

final class TestFileMapperTests: XCTestCase {
    private let mapper = TestFileMapper()

    func testResolvesSingleTargetFromIndexedReferences() throws {
        try withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            let testFile = packageRoot.appendingPathComponent("Tests/MyLibTests/CalculatorTests.swift")

            try writeFile(
                at: sourceFile,
                contents: """
                public enum Calculator {
                    public static func value() -> Int { 42 }
                }
                """
            )
            try writeFile(
                at: testFile,
                contents: """
                import XCTest
                @testable import MyLib

                final class CalculatorTests: XCTestCase {
                    func testValue() {
                        XCTAssertEqual(Calculator.value(), 42)
                    }
                }
                """
            )

            try runSwiftBuild(packageRoot: packageRoot)

            let filter = mapper.testFilter(forSourceFile: sourceFile.path)
            XCTAssertEqual(filter, "MyLibTests")
        }
    }

    func testResolvesMultiTargetRegexFromIndexedReferences() throws {
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
            let alphaFile = packageRoot.appendingPathComponent("Tests/AlphaSpecs/AlphaTests.swift")
            let betaFile = packageRoot.appendingPathComponent("Tests/BetaSpecs/BetaTests.swift")

            try writeFile(
                at: sourceFile,
                contents: """
                public enum Calculator {
                    public static func value() -> Int { 7 }
                }
                """
            )
            try writeFile(
                at: alphaFile,
                contents: """
                import XCTest
                @testable import MyLib

                final class AlphaTests: XCTestCase {
                    func testAlpha() {
                        XCTAssertEqual(Calculator.value(), 7)
                    }
                }
                """
            )
            try writeFile(
                at: betaFile,
                contents: """
                import XCTest
                @testable import MyLib

                final class BetaTests: XCTestCase {
                    func testBeta() {
                        XCTAssertEqual(Calculator.value(), 7)
                    }
                }
                """
            )

            try runSwiftBuild(packageRoot: packageRoot)

            let filter = mapper.testFilter(forSourceFile: sourceFile.path)
            XCTAssertEqual(filter, "^(AlphaSpecs|BetaSpecs)\\.")
        }
    }

    func testReturnsNilWhenNoIndexedUnitTestReferences() throws {
        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "TmpPkg",
            targets: [
                .target(name: "MyLib"),
                .target(name: "OtherLib"),
                .testTarget(name: "OtherLibTests", dependencies: ["OtherLib"]),
            ]
        )
        """

        try withTemporaryPackage(packageSwift: packageSwift) { packageRoot in
            let myLibSource = packageRoot.appendingPathComponent("Sources/MyLib/Untested.swift")
            let otherLibSource = packageRoot.appendingPathComponent("Sources/OtherLib/Helpers.swift")
            let testFile = packageRoot.appendingPathComponent("Tests/OtherLibTests/OtherLibTests.swift")

            try writeFile(
                at: myLibSource,
                contents: """
                public enum Untested {
                    public static func value() -> Int { 123 }
                }
                """
            )
            try writeFile(
                at: otherLibSource,
                contents: """
                public enum Helpers {
                    public static func ping() -> Bool { true }
                }
                """
            )
            try writeFile(
                at: testFile,
                contents: """
                import XCTest
                @testable import OtherLib

                final class OtherLibTests: XCTestCase {
                    func testPing() {
                        XCTAssertTrue(Helpers.ping())
                    }
                }
                """
            )

            try runSwiftBuild(packageRoot: packageRoot)

            let filter = mapper.testFilter(forSourceFile: myLibSource.path)
            XCTAssertNil(filter)
        }
    }

    func testReturnsNilOutsideSwiftPackage() {
        let filter = mapper.testFilter(forSourceFile: "/path/to/Sources/MyLib/Calculator.swift")
        XCTAssertNil(filter)
    }

    func testBootstrapsIndexWhenMissing() throws {
        try withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            let testFile = packageRoot.appendingPathComponent("Tests/MyLibTests/CalculatorTests.swift")

            try writeFile(
                at: sourceFile,
                contents: """
                public enum Calculator {
                    public static func value() -> Int { 42 }
                }
                """
            )
            try writeFile(
                at: testFile,
                contents: """
                import XCTest
                @testable import MyLib

                final class CalculatorTests: XCTestCase {
                    func testValue() {
                        XCTAssertEqual(Calculator.value(), 42)
                    }
                }
                """
            )

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(".build").path)
            )

            let filter = mapper.testFilter(forSourceFile: sourceFile.path)
            XCTAssertEqual(filter, "MyLibTests")
            XCTAssertFalse(discoverIndexStorePaths(packageRoot: packageRoot).isEmpty)
        }
    }

    func testFallsBackToNilWhenToolchainLibraryNotResolvable() throws {
        try withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            let testFile = packageRoot.appendingPathComponent("Tests/MyLibTests/CalculatorTests.swift")

            try writeFile(
                at: sourceFile,
                contents: """
                public enum Calculator {
                    public static func value() -> Int { 42 }
                }
                """
            )
            try writeFile(
                at: testFile,
                contents: """
                import XCTest
                @testable import MyLib

                final class CalculatorTests: XCTestCase {
                    func testValue() {
                        XCTAssertEqual(Calculator.value(), 42)
                    }
                }
                """
            )

            try runSwiftBuild(packageRoot: packageRoot)

            let resolver = IndexStoreTestScopeResolver(
                forcedIndexStoreLibraryPath: "/tmp/non-existent-libIndexStore-\(UUID().uuidString).dylib",
                allowAutomaticLibraryResolution: false
            )
            let mapper = TestFileMapper(scopeResolver: resolver)

            let filter = mapper.testFilter(forSourceFile: sourceFile.path)
            XCTAssertNil(filter)
        }
    }

    func testRefreshesIndexWhenSourceIsNewerThanIndexedUnit() throws {
        try withTemporaryPackage { packageRoot in
            let sourceFile = packageRoot.appendingPathComponent("Sources/MyLib/Calculator.swift")
            let testFile = packageRoot.appendingPathComponent("Tests/MyLibTests/CalculatorTests.swift")

            try writeFile(
                at: sourceFile,
                contents: """
                public enum Calculator {
                    public static func value() -> Int { 42 }
                }
                """
            )
            try writeFile(
                at: testFile,
                contents: """
                import XCTest
                @testable import MyLib

                final class CalculatorTests: XCTestCase {
                    func testValue() {
                        XCTAssertEqual(Calculator.value(), 42)
                    }
                }
                """
            )

            try runSwiftBuild(packageRoot: packageRoot)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)],
                ofItemAtPath: sourceFile.path
            )

            let resolver = IndexStoreTestScopeResolver()
            let mapper = TestFileMapper(scopeResolver: resolver)
            let filter = mapper.testFilter(forSourceFile: sourceFile.path)
            XCTAssertEqual(filter, "MyLibTests")
        }
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

    private func writeFile(at path: URL, contents: String = "") throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: path, atomically: true, encoding: .utf8)
    }

    private func runSwiftBuild(packageRoot: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["build", "--package-path", packageRoot.path, "--build-tests"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TestFileMapperTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "swift build failed for \(packageRoot.path)"]
            )
        }
    }

    private func discoverIndexStorePaths(packageRoot: URL) -> [String] {
        let buildURL = packageRoot.appendingPathComponent(".build", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: buildURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let candidateURL as URL in enumerator {
            guard candidateURL.lastPathComponent == "store",
                  candidateURL.deletingLastPathComponent().lastPathComponent == "index" else {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                paths.append(candidateURL.path)
            }
        }

        return paths
    }
}
