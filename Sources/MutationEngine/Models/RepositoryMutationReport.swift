public struct RepositoryMutationReport: Sendable, Codable {
    public let packagePath: String
    public let fileReports: [MutationReport]

    public init(packagePath: String, fileReports: [MutationReport]) {
        self.packagePath = packagePath
        self.fileReports = fileReports
    }

    public var filesAnalyzed: Int {
        fileReports.count
    }

    public var filesWithSurvivors: Int {
        fileReports.filter { $0.survived > 0 }.count
    }

    public var baselineDuration: Double {
        fileReports.reduce(0.0) { $0 + $1.baselineDuration }
    }

    public var totalMutations: Int {
        fileReports.reduce(0) { $0 + $1.totalMutations }
    }

    public var killed: Int {
        fileReports.reduce(0) { $0 + $1.killed }
    }

    public var survived: Int {
        fileReports.reduce(0) { $0 + $1.survived }
    }

    public var timedOut: Int {
        fileReports.reduce(0) { $0 + $1.timedOut }
    }

    public var buildErrors: Int {
        fileReports.reduce(0) { $0 + $1.buildErrors }
    }

    public var skipped: Int {
        fileReports.reduce(0) { $0 + $1.skipped }
    }

    /// Kill percentage excludes build errors and skipped mutations from the denominator.
    public var killPercentage: Double {
        let effective = killed + survived + timedOut
        guard effective > 0 else { return 100.0 }
        return Double(killed + timedOut) / Double(effective) * 100.0
    }
}
