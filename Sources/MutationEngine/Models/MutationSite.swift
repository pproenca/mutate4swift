public struct MutationSite: Sendable, Codable {
    public let mutationOperator: MutationOperator
    public let line: Int
    public let column: Int
    public let utf8Offset: Int
    public let utf8Length: Int
    public let originalText: String
    public let mutatedText: String

    public init(
        mutationOperator: MutationOperator,
        line: Int,
        column: Int,
        utf8Offset: Int,
        utf8Length: Int,
        originalText: String,
        mutatedText: String
    ) {
        self.mutationOperator = mutationOperator
        self.line = line
        self.column = column
        self.utf8Offset = utf8Offset
        self.utf8Length = utf8Length
        self.originalText = originalText
        self.mutatedText = mutatedText
    }
}
