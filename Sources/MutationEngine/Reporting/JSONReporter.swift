import Foundation

public struct JSONReporter: Sendable {
    public init() {}

    public func report(_ report: MutationReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(report),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
