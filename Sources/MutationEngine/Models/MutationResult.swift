public enum MutationOutcome: String, Sendable, Codable {
    case killed
    case survived
    case timeout
    case buildError
    case skipped
}

public struct MutationResult: Sendable, Codable {
    public let site: MutationSite
    public let outcome: MutationOutcome

    public init(site: MutationSite, outcome: MutationOutcome) {
        self.site = site
        self.outcome = outcome
    }
}
