import Foundation

/// Applies a mutation to source text using UTF-8 byte offsets.
public struct MutationApplicator: Sendable {
    public init() {}

    /// Returns new source with the mutation applied at the given site.
    public func apply(_ site: MutationSite, to source: String) -> String {
        var bytes = Array(source.utf8)
        let start = site.utf8Offset
        let end = start + site.utf8Length

        guard start >= 0, end <= bytes.count else {
            return source
        }

        let replacement = Array(site.mutatedText.utf8)
        bytes.replaceSubrange(start..<end, with: replacement)

        return String(decoding: bytes, as: UTF8.self)
    }
}
