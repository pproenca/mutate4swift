import SwiftSyntax
import SwiftParser

public final class MutationDiscoverer: SyntaxVisitor {
    private var sites: [MutationSite] = []
    private let source: String
    private let sourceLocationConverter: SourceLocationConverter

    public init(source: String, fileName: String = "<input>") {
        let tree = Parser.parse(source: source)
        self.source = source
        self.sourceLocationConverter = SourceLocationConverter(fileName: fileName, tree: tree)
        super.init(viewMode: .sourceAccurate)
        walk(tree)
    }

    public func discoverSites() -> [MutationSite] {
        return sites
    }

    // MARK: - Binary operators (arithmetic, comparison, logical, bitwise, range, compound assignment)
    // SwiftSyntax 600 produces SequenceExprSyntax with BinaryOperatorExprSyntax children.

    override public func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        let opText = node.operator.text
        let mutations = Self.infixMutations[opText] ?? []

        for (mutated, category) in mutations {
            addSite(
                token: node.operator,
                originalText: opText,
                mutatedText: mutated,
                operator: category
            )
        }

        return .visitChildren
    }

    // MARK: - Boolean literals

    override public func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let text = node.literal.text
        let mutated = text == "true" ? "false" : "true"
        addSite(
            token: node.literal,
            originalText: text,
            mutatedText: mutated,
            operator: .boolean
        )
        return .visitChildren
    }

    // MARK: - Integer literal constants (0 ↔ 1)

    override public func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let text = node.literal.text
        if text == "0" {
            addSite(token: node.literal, originalText: "0", mutatedText: "1", operator: .constant)
        } else if text == "1" {
            addSite(token: node.literal, originalText: "1", mutatedText: "0", operator: .constant)
        }
        return .visitChildren
    }

    // MARK: - Prefix operators (! removal, +/- sign swap, ~ removal)

    override public func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        let opText = node.operator.text
        if opText == "!" {
            addSite(
                token: node.operator,
                originalText: "!",
                mutatedText: "",
                operator: .unaryRemoval
            )
        } else if opText == "+" {
            addSite(
                token: node.operator,
                originalText: "+",
                mutatedText: "-",
                operator: .unarySign
            )
        } else if opText == "-" {
            addSite(
                token: node.operator,
                originalText: "-",
                mutatedText: "+",
                operator: .unarySign
            )
        } else if opText == "~" {
            addSite(
                token: node.operator,
                originalText: "~",
                mutatedText: "",
                operator: .bitwise
            )
        }
        return .visitChildren
    }

    // MARK: - Try mutation (try/try?/try!)

    override public func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if let marker = node.questionOrExclamationMark {
            let opText = marker.text
            let mutated = opText == "?" ? "!" : "?"
            addSite(
                token: marker,
                originalText: opText,
                mutatedText: mutated,
                operator: .tryMutation
            )
        } else {
            addSite(
                token: node.tryKeyword,
                originalText: "try",
                mutatedText: "try?",
                operator: .tryMutation
            )
            addSite(
                token: node.tryKeyword,
                originalText: "try",
                mutatedText: "try!",
                operator: .tryMutation
            )
        }

        return .visitChildren
    }

    // MARK: - Ternary swap

    override public func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        addTernarySwapSite(
            condition: node.condition,
            thenExpression: node.thenExpression,
            elseExpression: node.elseExpression
        )
        return .visitChildren
    }

    override public func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        // Parser trees contain unresolved ternaries in sequence expressions:
        // `condition`, `UnresolvedTernaryExprSyntax`, `elseExpression`.
        let elements = Array(node.elements)
        if elements.count == 3,
           let unresolved = elements[1].as(UnresolvedTernaryExprSyntax.self) {
            addTernarySwapSite(
                condition: elements[0],
                thenExpression: unresolved.thenExpression,
                elseExpression: elements[2]
            )
        }
        return .visitChildren
    }

    // MARK: - String literal mutation

    override public func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.openingQuote.text == "\"",
              node.closingQuote.text == "\"",
              !node.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) else {
            return .visitChildren
        }

        let start = node.positionAfterSkippingLeadingTrivia
        let end = node.endPositionBeforeTrailingTrivia
        let originalText = sourceSlice(startOffset: start.utf8Offset, endOffset: end.utf8Offset)
            ?? node.description.trimmingCharacters(in: .whitespacesAndNewlines)

        guard originalText != "\"\"" else {
            return .visitChildren
        }

        addSite(
            start: start,
            end: end,
            originalText: originalText,
            mutatedText: "\"\"",
            operator: .stringLiteral
        )

        return .visitChildren
    }

    // MARK: - Return value mutation

    override public func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        guard let expression = node.expression else {
            return .visitChildren
        }

        let returnKeyword = node.returnKeyword
        let expressionStart = expression.positionAfterSkippingLeadingTrivia.utf8Offset
        let expressionEnd = expression.endPositionBeforeTrailingTrivia.utf8Offset
        let returnStart = returnKeyword.positionAfterSkippingLeadingTrivia.utf8Offset

        let originalLength = expressionEnd - returnStart
        let loc = sourceLocationConverter.location(for: returnKeyword.positionAfterSkippingLeadingTrivia)

        let originalText = "return" + String(repeating: " ", count: expressionStart - returnStart - 6) + expression.description.trimmingCharacters(in: .whitespaces)
        sites.append(MutationSite(
            mutationOperator: .returnValue,
            line: loc.line,
            column: loc.column,
            utf8Offset: returnStart,
            utf8Length: originalLength,
            originalText: originalText,
            mutatedText: "return"
        ))

        return .visitChildren
    }

    // MARK: - Guard negate

    override public func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        let conditions = node.conditions
        guard conditions.count == 1,
              let condition = conditions.first,
              let expr = condition.condition.as(ExprSyntax.self) else {
            return .visitChildren
        }

        let conditionText = expr.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = expr.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = expr.endPositionBeforeTrailingTrivia.utf8Offset
        let loc = sourceLocationConverter.location(for: expr.positionAfterSkippingLeadingTrivia)

        sites.append(MutationSite(
            mutationOperator: .guardNegate,
            line: loc.line,
            column: loc.column,
            utf8Offset: start,
            utf8Length: end - start,
            originalText: conditionText,
            mutatedText: "!(\(conditionText))"
        ))

        return .visitChildren
    }

    // MARK: - If/while condition negate (Swift equivalent of clj-mutate's if ↔ if-not)

    override public func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        addConditionNegateSite(conditions: node.conditions)
        return .visitChildren
    }

    override public func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        addConditionNegateSite(conditions: node.conditions)
        return .visitChildren
    }

    private func addConditionNegateSite(conditions: ConditionElementListSyntax) {
        guard conditions.count == 1,
              let condition = conditions.first,
              let expr = condition.condition.as(ExprSyntax.self) else {
            return
        }

        // Skip if the condition is already a prefix `!` — unaryRemoval covers that
        if expr.is(PrefixOperatorExprSyntax.self) {
            return
        }

        let conditionText = expr.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = expr.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = expr.endPositionBeforeTrailingTrivia.utf8Offset
        let loc = sourceLocationConverter.location(for: expr.positionAfterSkippingLeadingTrivia)

        sites.append(MutationSite(
            mutationOperator: .conditionNegate,
            line: loc.line,
            column: loc.column,
            utf8Offset: start,
            utf8Length: end - start,
            originalText: conditionText,
            mutatedText: "!(\(conditionText))"
        ))
    }

    private func addTernarySwapSite(
        condition: ExprSyntax,
        thenExpression: ExprSyntax,
        elseExpression: ExprSyntax
    ) {
        let start = condition.positionAfterSkippingLeadingTrivia
        let end = elseExpression.endPositionBeforeTrailingTrivia
        let conditionText = condition.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let thenText = thenExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let elseText = elseExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = sourceSlice(startOffset: start.utf8Offset, endOffset: end.utf8Offset)
            ?? "\(conditionText) ? \(thenText) : \(elseText)"

        addSite(
            start: start,
            end: end,
            originalText: originalText,
            mutatedText: "\(conditionText) ? \(elseText) : \(thenText)",
            operator: .ternarySwap
        )
    }

    // MARK: - Helpers

    private func addSite(
        token: TokenSyntax,
        originalText: String,
        mutatedText: String,
        operator mutationOp: MutationOperator
    ) {
        let position = token.positionAfterSkippingLeadingTrivia
        let loc = sourceLocationConverter.location(for: position)

        sites.append(MutationSite(
            mutationOperator: mutationOp,
            line: loc.line,
            column: loc.column,
            utf8Offset: position.utf8Offset,
            utf8Length: token.text.utf8.count,
            originalText: originalText,
            mutatedText: mutatedText
        ))
    }

    private func addSite(
        start: AbsolutePosition,
        end: AbsolutePosition,
        originalText: String,
        mutatedText: String,
        operator mutationOp: MutationOperator
    ) {
        let loc = sourceLocationConverter.location(for: start)

        sites.append(MutationSite(
            mutationOperator: mutationOp,
            line: loc.line,
            column: loc.column,
            utf8Offset: start.utf8Offset,
            utf8Length: end.utf8Offset - start.utf8Offset,
            originalText: originalText,
            mutatedText: mutatedText
        ))
    }

    private func sourceSlice(startOffset: Int, endOffset: Int) -> String? {
        guard startOffset >= 0,
              endOffset >= startOffset,
              endOffset <= source.utf8.count else {
            return nil
        }

        let utf8View = source.utf8
        guard let startUTF8 = utf8View.index(utf8View.startIndex, offsetBy: startOffset, limitedBy: utf8View.endIndex),
              let endUTF8 = utf8View.index(utf8View.startIndex, offsetBy: endOffset, limitedBy: utf8View.endIndex),
              let startIndex = String.Index(startUTF8, within: source),
              let endIndex = String.Index(endUTF8, within: source) else {
            return nil
        }

        return String(source[startIndex..<endIndex])
    }

    // MARK: - Mutation tables

    private static let infixMutations: [String: [(String, MutationOperator)]] = [
        // Arithmetic
        "+": [("-", .arithmetic)],
        "-": [("+", .arithmetic)],
        "*": [("/", .arithmetic)],
        "/": [("*", .arithmetic)],
        "%": [("*", .arithmetic)],
        // Comparison
        ">": [(">=", .comparison)],
        ">=": [(">", .comparison)],
        "<": [("<=", .comparison)],
        "<=": [("<", .comparison)],
        "==": [("!=", .comparison)],
        "!=": [("==", .comparison)],
        // Logical
        "&&": [("||", .logical)],
        "||": [("&&", .logical)],
        // Bitwise
        "&": [("|", .bitwise)],
        "|": [("&", .bitwise)],
        "^": [("&", .bitwise)],
        "<<": [(">>", .bitwise)],
        ">>": [("<<", .bitwise)],
        // Compound assignment
        "+=": [("-=", .compoundAssignment)],
        "-=": [("+=", .compoundAssignment)],
        "*=": [("/=", .compoundAssignment)],
        "/=": [("*=", .compoundAssignment)],
        "&=": [("|=", .compoundAssignment)],
        "|=": [("&=", .compoundAssignment)],
        "<<=": [(">>=", .compoundAssignment)],
        ">>=": [("<<=", .compoundAssignment)],
        // Range
        "..<": [("...", .range)],
        "...": [("..<", .range)],
    ]
}
