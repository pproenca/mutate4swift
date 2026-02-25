import Foundation

/// Maps a source file to its corresponding test file using SPM conventions.
/// E.g., Sources/MyLib/Foo.swift → Tests/MyLibTests/FooTests.swift
public struct TestFileMapper: Sendable {
    private let scopeResolver: any IndexStoreTestScopeResolving

    public init() {
        self.scopeResolver = IndexStoreTestScopeResolver.shared
    }

    init(scopeResolver: any IndexStoreTestScopeResolving) {
        self.scopeResolver = scopeResolver
    }

    /// Returns a test filter pattern for `swift test --filter` based on the source file.
    /// Resolution is semantic-index based and falls back to `nil` (full-suite tests) on failure.
    public func testFilter(forSourceFile sourceFile: String) -> String? {
        scopeResolver.resolveTestFilter(forSourceFile: sourceFile)
    }

    /// Returns the expected test file path for a source file.
    public func testFile(forSourceFile sourceFile: String, packagePath: String) -> String? {
        guard let mapping = sourceTargetMapping(forSourceFile: sourceFile) else {
            return nil
        }

        let testPath = (packagePath as NSString)
            .appendingPathComponent("Tests")
            .appending("/\(mapping.conventionalTestTargetName)/\(mapping.fileName)Tests.swift")

        return FileManager.default.fileExists(atPath: testPath) ? testPath : nil
    }

    private func sourceTargetMapping(forSourceFile sourceFile: String) -> (
        fileName: String,
        sourceTargetName: String,
        conventionalTestTargetName: String
    )? {
        let url = URL(fileURLWithPath: sourceFile)
        let fileName = url.deletingPathExtension().lastPathComponent
        guard !fileName.isEmpty else {
            return nil
        }

        // Walk up to find the target directory under Sources/
        let components = url.pathComponents
        guard let sourcesIdx = components.firstIndex(of: "Sources"),
              sourcesIdx + 1 < components.count else {
            return nil
        }

        let targetName = components[sourcesIdx + 1]
        guard !targetName.isEmpty else {
            return nil
        }

        return (fileName, targetName, targetName + "Tests")
    }
}
