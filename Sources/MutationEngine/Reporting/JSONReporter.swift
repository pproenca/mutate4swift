import Foundation

public struct JSONReporter: Sendable {
    public init() {}

    public func report(_ report: MutationReport) -> String {
        encode(report)
    }

    public func report(_ report: RepositoryMutationReport) -> String {
        encode(report)
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
