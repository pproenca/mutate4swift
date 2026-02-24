import Foundation

/// Maps a source file to its corresponding test file using SPM conventions.
/// E.g., Sources/MyLib/Foo.swift → Tests/MyLibTests/FooTests.swift
public struct TestFileMapper: Sendable {
    public init() {}

    /// Returns a test filter pattern for `swift test --filter` based on the source file.
    public func testFilter(forSourceFile sourceFile: String) -> String? {
        let url = URL(fileURLWithPath: sourceFile)
        let fileName = url.deletingPathExtension().lastPathComponent
        return "\(fileName)Tests"
    }

    /// Returns the expected test file path for a source file.
    public func testFile(forSourceFile sourceFile: String, packagePath: String) -> String? {
        let url = URL(fileURLWithPath: sourceFile)
        let fileName = url.deletingPathExtension().lastPathComponent

        // Walk up to find the target directory under Sources/
        let components = url.pathComponents
        guard let sourcesIdx = components.firstIndex(of: "Sources"),
              sourcesIdx + 1 < components.count else {
            return nil
        }

        let targetName = components[sourcesIdx + 1]
        let testTargetName = targetName + "Tests"
        let testFileName = fileName + "Tests.swift"

        let testPath = (packagePath as NSString)
            .appendingPathComponent("Tests")
            .appending("/\(testTargetName)/\(testFileName)")

        return FileManager.default.fileExists(atPath: testPath) ? testPath : nil
    }
}
