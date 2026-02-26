import Foundation

/// Discovers Swift source files for repository-wide mutation runs.
public struct SourceFileDiscoverer: Sendable {
    private static let excludedPathComponents: Set<String> = [
        "generated",
        "vendor",
        "pods",
        "carthage",
    ]

    public init() {}

    /// Returns absolute paths of Swift files under `<packagePath>/Sources`.
    public func discoverSourceFiles(in packagePath: String) throws -> [String] {
        let sourcesURL = URL(fileURLWithPath: packagePath)
            .appendingPathComponent("Sources", isDirectory: true)
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: sourcesURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Mutate4SwiftError.invalidSourceFile("Missing Sources directory at \(sourcesURL.path)")
        }

        guard let enumerator = FileManager.default.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw Mutate4SwiftError.invalidSourceFile(
                "Unable to enumerate Sources directory at \(sourcesURL.path)"
            )
        }

        var files: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            let path = fileURL.path
            guard path.hasSuffix(".swift"),
                  !path.hasSuffix(".mutate4swift.backup") else {
                continue
            }

            let lowercasedComponents = Set(fileURL.pathComponents.map { $0.lowercased() })
            if !lowercasedComponents.isDisjoint(with: Self.excludedPathComponents) {
                continue
            }

            files.append(path)
        }

        return files.sorted()
    }
}
