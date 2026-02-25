public struct RepositoryMutationReport: Sendable, Codable {
    public let packagePath: String
    public let fileReports: [MutationReport]
    private let summary: Summary

    public init(packagePath: String, fileReports: [MutationReport]) {
        self.packagePath = packagePath
        self.fileReports = fileReports
        self.summary = Summary(fileReports: fileReports)
    }

    public var filesAnalyzed: Int {
        summary.filesAnalyzed
    }

    public var filesWithSurvivors: Int {
        summary.filesWithSurvivors
    }

    public var baselineDuration: Double {
        summary.baselineDuration
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

    /// Kill percentage excludes build errors and skipped mutations from the denominator.
    public var killPercentage: Double {
        summary.killPercentage
    }

    private enum CodingKeys: String, CodingKey {
        case packagePath
        case fileReports
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.packagePath = try container.decode(String.self, forKey: .packagePath)
        let fileReports = try container.decode([MutationReport].self, forKey: .fileReports)
        self.fileReports = fileReports
        self.summary = Summary(fileReports: fileReports)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packagePath, forKey: .packagePath)
        try container.encode(fileReports, forKey: .fileReports)
    }

    private struct Summary: Sendable {
        let filesAnalyzed: Int
        let filesWithSurvivors: Int
        let baselineDuration: Double
        let totalMutations: Int
        let killed: Int
        let survived: Int
        let timedOut: Int
        let buildErrors: Int
        let skipped: Int

        init(fileReports: [MutationReport]) {
            var filesWithSurvivors = 0
            var baselineDuration = 0.0
            var totalMutations = 0
            var killed = 0
            var survived = 0
            var timedOut = 0
            var buildErrors = 0
            var skipped = 0

            for fileReport in fileReports {
                if fileReport.survived > 0 {
                    filesWithSurvivors += 1
                }
                baselineDuration += fileReport.baselineDuration
                totalMutations += fileReport.totalMutations
                killed += fileReport.killed
                survived += fileReport.survived
                timedOut += fileReport.timedOut
                buildErrors += fileReport.buildErrors
                skipped += fileReport.skipped
            }

            self.filesAnalyzed = fileReports.count
            self.filesWithSurvivors = filesWithSurvivors
            self.baselineDuration = baselineDuration
            self.totalMutations = totalMutations
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
