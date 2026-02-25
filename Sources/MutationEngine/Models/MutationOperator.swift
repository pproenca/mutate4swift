public enum MutationOperator: String, Sendable, Codable, CaseIterable {
    case arithmetic
    case comparison
    case logical
    case bitwise
    case compoundAssignment
    case boolean
    case unaryRemoval
    case unarySign
    case constant
    case returnValue
    case guardNegate
    case conditionNegate
    case range
    case tryMutation
    case ternarySwap
    case stringLiteral
    case nilCoalescing
    case statementDeletion
    case voidCallRemoval

    public var description: String {
        switch self {
        case .arithmetic: return "Arithmetic"
        case .comparison: return "Comparison"
        case .logical: return "Logical"
        case .bitwise: return "Bitwise"
        case .compoundAssignment: return "Compound Assignment"
        case .boolean: return "Boolean"
        case .unaryRemoval: return "Unary Removal"
        case .unarySign: return "Unary Sign"
        case .constant: return "Constant"
        case .returnValue: return "Return Value"
        case .guardNegate: return "Guard Negate"
        case .conditionNegate: return "Condition Negate"
        case .range: return "Range"
        case .tryMutation: return "Try Mutation"
        case .ternarySwap: return "Ternary Swap"
        case .stringLiteral: return "String Literal"
        case .nilCoalescing: return "Nil Coalescing"
        case .statementDeletion: return "Statement Deletion"
        case .voidCallRemoval: return "Void Call Removal"
        }
    }
}
