import Foundation
import SwiftSyntax
import SwiftParser

public final class MutationDiscoverer: SyntaxVisitor {
    private var sites: [MutationSite] = []
    private let source: String
    private let sourceLocationConverter: SourceLocationConverter
    private let identifierLiteralPool: [String]
    private var functionReturnTypeStack: [String?] = []

    public init(source: String, fileName: String = "<input>") {
        let tree = Parser.parse(source: source)
        self.source = source
        self.sourceLocationConverter = SourceLocationConverter(fileName: fileName, tree: tree)
        self.identifierLiteralPool = Self.collectIdentifierLiteralPool(tree: tree)
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
        } else if let value = parseDecimalIntegerLiteral(text) {
            let plusOne = value.addingReportingOverflow(1)
            if !plusOne.overflow {
                addSite(
                    token: node.literal,
                    originalText: text,
                    mutatedText: String(plusOne.partialValue),
                    operator: .constantBoundary
                )
            }

            let minusOne = value.subtractingReportingOverflow(1)
            if !minusOne.overflow {
                addSite(
                    token: node.literal,
                    originalText: text,
                    mutatedText: String(minusOne.partialValue),
                    operator: .constantBoundary
                )
            }
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

    // MARK: - Cast strength (as? ↔ as!)

    override public func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        addCastStrengthSite(marker: node.questionOrExclamationMark)
        return .visitChildren
    }

    override public func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
        addCastStrengthSite(marker: node.questionOrExclamationMark)
        return .visitChildren
    }

    // MARK: - Optional chaining strictness (?. → !.)

    override public func visit(_ node: OptionalChainingExprSyntax) -> SyntaxVisitorContinueKind {
        addSite(
            token: node.questionMark,
            originalText: "?",
            mutatedText: "!",
            operator: .optionalChaining
        )
        return .visitChildren
    }

    // MARK: - Function context tracking

    override public func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let returnType = node.signature.returnClause?.type.description.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        functionReturnTypeStack.append(returnType)
        return .visitChildren
    }

    override public func visitPost(_ node: FunctionDeclSyntax) {
        _ = functionReturnTypeStack.popLast()
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

        // Nil-coalescing appears as `lhs`, `BinaryOperatorExprSyntax("??")`, `rhs`.
        if elements.count >= 3 {
            for index in 1..<(elements.count - 1) {
                guard let op = elements[index].as(BinaryOperatorExprSyntax.self),
                      op.operator.text == "??" else {
                    continue
                }
                addNilCoalescingSites(lhs: elements[index - 1], rhs: elements[index + 1])
            }
        }

        return .visitChildren
    }

    // MARK: - Semantic call substitutions

    override public func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        addStdlibSemanticSite(calledExpression: node.calledExpression)
        addConcurrencyContextSite(calledExpression: node.calledExpression)
        return .visitChildren
    }

    // MARK: - Statement deletion and void call removal

    override public func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        guard let expr = node.item.as(ExprSyntax.self) else {
            return .visitChildren
        }

        if isStatementLevelCall(expr) {
            addStatementRemovalSite(node: node, expr: expr, operator: .voidCallRemoval)
            return .visitChildren
        }

        if isAssignmentStatement(expr) {
            addStatementRemovalSite(node: node, expr: expr, operator: .statementDeletion)
        }

        return .visitChildren
    }

    // MARK: - Defer and loop control

    override public func visit(_ node: DeferStmtSyntax) -> SyntaxVisitorContinueKind {
        let start = node.positionAfterSkippingLeadingTrivia
        let end = node.endPositionBeforeTrailingTrivia
        let originalText = sourceSlice(startOffset: start.utf8Offset, endOffset: end.utf8Offset)
        addSite(
            start: start,
            end: end,
            originalText: originalText,
            mutatedText: "",
            operator: .deferRemoval
        )
        return .visitChildren
    }

    override public func visit(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind {
        addSite(
            token: node.continueKeyword,
            originalText: "continue",
            mutatedText: "break",
            operator: .loopControl
        )
        return .visitChildren
    }

    override public func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind {
        guard isLoopBreak(node) else {
            return .visitChildren
        }

        addSite(
            token: node.breakKeyword,
            originalText: "break",
            mutatedText: "continue",
            operator: .loopControl
        )
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
        let content = node.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()

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

        addTailoredIdentifierLiteralSite(
            content: content,
            start: start,
            end: end,
            originalText: originalText
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
        let expressionText = expression.description.trimmingCharacters(in: .whitespacesAndNewlines)

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

        if let typedDefault = typedReturnDefaultValue(),
           expressionText != typedDefault {
            sites.append(MutationSite(
                mutationOperator: .typedReturnDefault,
                line: loc.line,
                column: loc.column,
                utf8Offset: returnStart,
                utf8Length: originalLength,
                originalText: originalText,
                mutatedText: "return \(typedDefault)"
            ))
        }

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

        addSite(
            start: start,
            end: end,
            originalText: originalText,
            mutatedText: "\(conditionText) ? \(elseText) : \(thenText)",
            operator: .ternarySwap
        )
    }

    private func addCastStrengthSite(marker: TokenSyntax?) {
        guard let marker else {
            return
        }

        let opText = marker.text
        guard opText == "?" || opText == "!" else {
            return
        }

        let mutated = opText == "?" ? "!" : "?"
        addSite(
            token: marker,
            originalText: opText,
            mutatedText: mutated,
            operator: .castStrength
        )
    }

    private func addStdlibSemanticSite(calledExpression: ExprSyntax) {
        guard let (name, token) = functionNameToken(in: calledExpression),
              let mutated = Self.stdlibSemanticMutations[name] else {
            return
        }

        addSite(
            token: token,
            originalText: name,
            mutatedText: mutated,
            operator: .stdlibSemantic
        )
    }

    private func addConcurrencyContextSite(calledExpression: ExprSyntax) {
        if let decl = calledExpression.as(DeclReferenceExprSyntax.self),
           decl.baseName.text == "Task" {
            addSite(
                token: decl.baseName,
                originalText: "Task",
                mutatedText: "Task.detached",
                operator: .concurrencyContext
            )
            return
        }

        guard let member = calledExpression.as(MemberAccessExprSyntax.self),
              let baseDecl = member.base?.as(DeclReferenceExprSyntax.self),
              baseDecl.baseName.text == "Task",
              member.declName.baseName.text == "detached" else {
            return
        }

        let start = calledExpression.positionAfterSkippingLeadingTrivia
        let end = calledExpression.endPositionBeforeTrailingTrivia
        let originalText = sourceSlice(startOffset: start.utf8Offset, endOffset: end.utf8Offset)
        addSite(
            start: start,
            end: end,
            originalText: originalText,
            mutatedText: "Task",
            operator: .concurrencyContext
        )
    }

    private func addTailoredIdentifierLiteralSite(
        content: String,
        start: AbsolutePosition,
        end: AbsolutePosition,
        originalText: String
    ) {
        guard Self.isIdentifierLikeText(content),
              let replacement = identifierLiteralPool.first(where: { $0 != content }) else {
            return
        }

        addSite(
            start: start,
            end: end,
            originalText: originalText,
            mutatedText: "\"\(replacement)\"",
            operator: .tailoredIdentifierLiteral
        )
    }

    private func addNilCoalescingSites(lhs: ExprSyntax, rhs: ExprSyntax) {
        let start = lhs.positionAfterSkippingLeadingTrivia
        let end = rhs.endPositionBeforeTrailingTrivia
        let lhsText = lhs.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsText = rhs.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = sourceSlice(startOffset: start.utf8Offset, endOffset: end.utf8Offset)

        addSite(
            start: start,
            end: end,
            originalText: originalText,
            mutatedText: rhsText,
            operator: .nilCoalescing
        )
        addSite(
            start: start,
            end: end,
            originalText: originalText,
            mutatedText: "(\(lhsText))!",
            operator: .nilCoalescing
        )
    }

    private func functionNameToken(in calledExpression: ExprSyntax) -> (String, TokenSyntax)? {
        if let decl = calledExpression.as(DeclReferenceExprSyntax.self) {
            return (decl.baseName.text, decl.baseName)
        }

        if let member = calledExpression.as(MemberAccessExprSyntax.self) {
            return (member.declName.baseName.text, member.declName.baseName)
        }

        return nil
    }

    private func addStatementRemovalSite(
        node: CodeBlockItemSyntax,
        expr: ExprSyntax,
        operator mutationOp: MutationOperator
    ) {
        let start = expr.positionAfterSkippingLeadingTrivia
        let end: AbsolutePosition
        if let semicolon = node.semicolon {
            end = semicolon.endPositionBeforeTrailingTrivia
        } else {
            end = expr.endPositionBeforeTrailingTrivia
        }

        let originalText = sourceSlice(startOffset: start.utf8Offset, endOffset: end.utf8Offset)

        addSite(
            start: start,
            end: end,
            originalText: originalText,
            mutatedText: "",
            operator: mutationOp
        )
    }

    private func isStatementLevelCall(_ expr: ExprSyntax) -> Bool {
        let unwrapped = unwrapTryAwait(expr)
        return unwrapped.is(FunctionCallExprSyntax.self)
    }

    private func unwrapTryAwait(_ expr: ExprSyntax) -> ExprSyntax {
        if let tryExpr = expr.as(TryExprSyntax.self) {
            return unwrapTryAwait(tryExpr.expression)
        }
        if let awaitExpr = expr.as(AwaitExprSyntax.self) {
            return unwrapTryAwait(awaitExpr.expression)
        }
        return expr
    }

    private func isAssignmentStatement(_ expr: ExprSyntax) -> Bool {
        if let sequence = expr.as(SequenceExprSyntax.self) {
            for element in sequence.elements {
                if element.is(AssignmentExprSyntax.self) {
                    return true
                }
                if let op = element.as(BinaryOperatorExprSyntax.self),
                   isAssignmentOperator(op.operator.text) {
                    return true
                }
            }
        }

        return false
    }

    private func isAssignmentOperator(_ opText: String) -> Bool {
        guard opText.hasSuffix("=") else {
            return false
        }
        switch opText {
        case "==", "!=", ">=", "<=", "===", "!==", "~=":
            return false
        default:
            return true
        }
    }

    private func typedReturnDefaultValue() -> String? {
        guard let rawType = functionReturnTypeStack.last ?? nil else {
            return nil
        }

        let compact = rawType.replacingOccurrences(of: " ", with: "")
        if compact.hasSuffix("?") || compact.hasSuffix("!") {
            return "nil"
        }

        switch compact {
        case "Bool", "Swift.Bool":
            return "false"
        case "String", "Swift.String":
            return "\"\""
        case
            "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Double", "Float", "CGFloat", "Decimal",
            "Swift.Int", "Swift.Int8", "Swift.Int16", "Swift.Int32", "Swift.Int64",
            "Swift.UInt", "Swift.UInt8", "Swift.UInt16", "Swift.UInt32", "Swift.UInt64",
            "Swift.Double", "Swift.Float":
            return "0"
        default:
            return nil
        }
    }

    private func parseDecimalIntegerLiteral(_ text: String) -> Int? {
        let sanitized = text.replacingOccurrences(of: "_", with: "")
        guard !sanitized.isEmpty,
              sanitized.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return Int(sanitized)
    }

    private func isLoopBreak(_ node: BreakStmtSyntax) -> Bool {
        var current = node.parent

        while let syntax = current {
            if syntax.is(SwitchExprSyntax.self) {
                return false
            }

            if syntax.is(ForStmtSyntax.self)
                || syntax.is(WhileStmtSyntax.self)
                || syntax.is(RepeatStmtSyntax.self) {
                return true
            }

            if syntax.is(FunctionDeclSyntax.self) || syntax.is(ClosureExprSyntax.self) {
                return false
            }

            current = syntax.parent
        }

        return false
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

    private func sourceSlice(startOffset: Int, endOffset: Int) -> String {
        let utf8View = source.utf8
        let startUTF8 = utf8View.index(utf8View.startIndex, offsetBy: startOffset)
        let endUTF8 = utf8View.index(utf8View.startIndex, offsetBy: endOffset)
        let startIndex = String.Index(startUTF8, within: source)!
        let endIndex = String.Index(endUTF8, within: source)!

        return String(source[startIndex..<endIndex])
    }

    private static func collectIdentifierLiteralPool(tree: SourceFileSyntax) -> [String] {
        final class Collector: SyntaxVisitor {
            private(set) var literals: [String] = []
            private var seen: Set<String> = []

            init() {
                super.init(viewMode: .sourceAccurate)
            }

            override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
                guard node.openingQuote.text == "\"",
                      node.closingQuote.text == "\"",
                      !node.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) else {
                    return .visitChildren
                }

                let content = node.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
                guard MutationDiscoverer.isIdentifierLikeText(content),
                      seen.insert(content).inserted else {
                    return .visitChildren
                }

                literals.append(content)
                return .visitChildren
            }
        }

        let collector = Collector()
        collector.walk(tree)
        return collector.literals
    }

    private static func isIdentifierLikeText(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else {
            return false
        }

        let identifierStart = CharacterSet.letters.union(CharacterSet(charactersIn: "_"))
        let identifierBody = identifierStart.union(.decimalDigits)
        guard identifierStart.contains(first) else {
            return false
        }

        for scalar in text.unicodeScalars.dropFirst() where !identifierBody.contains(scalar) {
            return false
        }
        return true
    }

    // MARK: - Mutation tables

    private static let stdlibSemanticMutations: [String: String] = [
        "min": "max",
        "max": "min",
    ]

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
