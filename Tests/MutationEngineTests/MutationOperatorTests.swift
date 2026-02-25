import XCTest
@testable import MutationEngine

final class MutationOperatorTests: XCTestCase {
    func testDescriptionsForAllOperators() {
        let expected: [MutationOperator: String] = [
            .arithmetic: "Arithmetic",
            .comparison: "Comparison",
            .logical: "Logical",
            .bitwise: "Bitwise",
            .compoundAssignment: "Compound Assignment",
            .boolean: "Boolean",
            .unaryRemoval: "Unary Removal",
            .unarySign: "Unary Sign",
            .constant: "Constant",
            .returnValue: "Return Value",
            .guardNegate: "Guard Negate",
            .conditionNegate: "Condition Negate",
            .range: "Range",
            .tryMutation: "Try Mutation",
            .ternarySwap: "Ternary Swap",
            .stringLiteral: "String Literal",
            .nilCoalescing: "Nil Coalescing",
            .statementDeletion: "Statement Deletion",
            .voidCallRemoval: "Void Call Removal",
        ]

        XCTAssertEqual(Set(expected.keys), Set(MutationOperator.allCases))
        for op in MutationOperator.allCases {
            XCTAssertEqual(op.description, expected[op])
        }
    }
}
