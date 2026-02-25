public struct MutationReport: Sendable, Codable {
    public let results: [MutationResult]
    public let sourceFile: String
    public let baselineDuration: Double
    private let summary: Summary

    public init(results: [MutationResult], sourceFile: String, baselineDuration: Double) {
        self.results = results
        self.sourceFile = sourceFile
        self.baselineDuration = baselineDuration
        self.summary = Summary(results: results)
    }

    public var totalMutations: Int {
        summary.totalMutations
    }

    public var killed: Int {
        summary.killed
    }

    public var survived: Int {
        summary.survived
    }

    public var timedOut: Int {
        summary.timedOut
    }

    public var buildErrors: Int {
        summary.buildErrors
    }

    public var skipped: Int {
        summary.skipped
    }

    /// Kill percentage excludes build errors and skipped mutations from the denominator
    public var killPercentage: Double {
        summary.killPercentage
    }

    private enum CodingKeys: String, CodingKey {
        case results
        case sourceFile
        case baselineDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let results = try container.decode([MutationResult].self, forKey: .results)
        self.results = results
        self.sourceFile = try container.decode(String.self, forKey: .sourceFile)
        self.baselineDuration = try container.decode(Double.self, forKey: .baselineDuration)
        self.summary = Summary(results: results)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(results, forKey: .results)
        try container.encode(sourceFile, forKey: .sourceFile)
        try container.encode(baselineDuration, forKey: .baselineDuration)
    }

    private struct Summary: Sendable {
        let totalMutations: Int
        let killed: Int
        let survived: Int
        let timedOut: Int
        let buildErrors: Int
        let skipped: Int

        init(results: [MutationResult]) {
            var killed = 0
            var survived = 0
            var timedOut = 0
            var buildErrors = 0
            var skipped = 0

            for result in results {
                switch result.outcome {
                case .killed:
                    killed += 1
                case .survived:
                    survived += 1
                case .timeout:
                    timedOut += 1
                case .buildError:
                    buildErrors += 1
                case .skipped:
                    skipped += 1
                }
            }

            self.totalMutations = results.count
            self.killed = killed
            self.survived = survived
            self.timedOut = timedOut
            self.buildErrors = buildErrors
            self.skipped = skipped
        }

        var killPercentage: Double {
            let effective = killed + survived + timedOut
            guard effective > 0 else { return 100.0 }
            return Double(killed + timedOut) / Double(effective) * 100.0
        }
    }
}
