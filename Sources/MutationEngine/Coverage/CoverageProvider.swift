import Foundation

public protocol CoverageProvider: Sendable {
    /// Returns the set of line numbers that are covered by tests for the given file.
    func coveredLines(forFile filePath: String, packagePath: String) throws -> Set<Int>
}
