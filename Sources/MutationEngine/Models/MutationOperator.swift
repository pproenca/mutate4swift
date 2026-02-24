public enum MutationOperator: String, Sendable, Codable, CaseIterable {
    case arithmetic
    case comparison
    case logical
    case boolean
    case unaryRemoval
    case unarySign
    case constant
    case returnValue
    case guardNegate
    case conditionNegate
    case range

    public var description: String {
        switch self {
        case .arithmetic: return "Arithmetic"
        case .comparison: return "Comparison"
        case .logical: return "Logical"
        case .boolean: return "Boolean"
        case .unaryRemoval: return "Unary Removal"
        case .unarySign: return "Unary Sign"
        case .constant: return "Constant"
        case .returnValue: return "Return Value"
        case .guardNegate: return "Guard Negate"
        case .conditionNegate: return "Condition Negate"
        case .range: return "Range"
        }
    }
}
