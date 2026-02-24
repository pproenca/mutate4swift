/// Filters out mutations that are known to produce equivalent programs
/// (i.e., the mutation cannot change observable behavior).
public struct EquivalentMutationFilter: Sendable {
    public init() {}

    public func filter(_ sites: [MutationSite], source: String) -> [MutationSite] {
        return sites.filter { !isEquivalent($0, source: source) }
    }

    private func isEquivalent(_ site: MutationSite, source: String) -> Bool {
        // 0 ↔ 1 inside array index subscript: arr[0] → arr[1] is not equivalent
        // but 0 * expr → 1 * expr IS equivalent if the result is unused.
        // For now, filter conservatively:

        // Constant mutation where 0/1 appears as a multiplication factor with 0:
        // e.g., `0 * x` mutated to `1 * x` — these have different semantics, so keep them.
        // The only safe filter: if original == mutated (should never happen, but guard)
        if site.originalText == site.mutatedText {
            return true
        }

        return false
    }
}
