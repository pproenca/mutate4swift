public struct MutationReport: Sendable, Codable {
    public let results: [MutationResult]
    public let sourceFile: String
    public let baselineDuration: Double

    public init(results: [MutationResult], sourceFile: String, baselineDuration: Double) {
        self.results = results
        self.sourceFile = sourceFile
        self.baselineDuration = baselineDuration
    }

    public var totalMutations: Int {
        results.count
    }

    public var killed: Int {
        results.filter { $0.outcome == .killed }.count
    }

    public var survived: Int {
        results.filter { $0.outcome == .survived }.count
    }

    public var timedOut: Int {
        results.filter { $0.outcome == .timeout }.count
    }

    public var buildErrors: Int {
        results.filter { $0.outcome == .buildError }.count
    }

    public var skipped: Int {
        results.filter { $0.outcome == .skipped }.count
    }

    /// Kill percentage excludes build errors and skipped mutations from the denominator
    public var killPercentage: Double {
        let effective = killed + survived + timedOut
        guard effective > 0 else { return 100.0 }
        return Double(killed + timedOut) / Double(effective) * 100.0
    }
}
