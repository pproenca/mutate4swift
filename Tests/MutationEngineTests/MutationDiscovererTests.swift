import XCTest
@testable import MutationEngine

final class MutationDiscovererTests: XCTestCase {

    // MARK: - Arithmetic

    func testArithmeticPlusToMinus() {
        let source = "let x = a + b"
        let sites = discover(source)
        let arithmetic = sites.filter { $0.mutationOperator == .arithmetic }
        XCTAssertEqual(arithmetic.count, 1)
        XCTAssertEqual(arithmetic[0].originalText, "+")
        XCTAssertEqual(arithmetic[0].mutatedText, "-")
    }

    func testArithmeticMinusToPlus() {
        let source = "let x = a - b"
        let sites = discover(source)
        let arithmetic = sites.filter { $0.mutationOperator == .arithmetic }
        XCTAssertEqual(arithmetic.count, 1)
        XCTAssertEqual(arithmetic[0].originalText, "-")
        XCTAssertEqual(arithmetic[0].mutatedText, "+")
    }

    func testArithmeticMultiplyToDivide() {
        let source = "let x = a * b"
        let sites = discover(source)
        let arithmetic = sites.filter { $0.mutationOperator == .arithmetic }
        XCTAssertEqual(arithmetic.count, 1)
        XCTAssertEqual(arithmetic[0].originalText, "*")
        XCTAssertEqual(arithmetic[0].mutatedText, "/")
    }

    func testArithmeticDivideToMultiply() {
        let source = "let x = a / b"
        let sites = discover(source)
        let arithmetic = sites.filter { $0.mutationOperator == .arithmetic }
        XCTAssertEqual(arithmetic.count, 1)
        XCTAssertEqual(arithmetic[0].originalText, "/")
        XCTAssertEqual(arithmetic[0].mutatedText, "*")
    }

    // MARK: - Comparison

    func testComparisonOperators() {
        let pairs: [(String, String)] = [
            (">", ">="), (">=", ">"),
            ("<", "<="), ("<=", "<"),
            ("==", "!="), ("!=", "=="),
        ]
        for (original, expected) in pairs {
            let source = "let x = a \(original) b"
            let sites = discover(source).filter { $0.mutationOperator == .comparison }
            XCTAssertEqual(sites.count, 1, "Expected 1 comparison site for \(original)")
            XCTAssertEqual(sites[0].originalText, original)
            XCTAssertEqual(sites[0].mutatedText, expected)
        }
    }

    // MARK: - Logical

    func testLogicalAndToOr() {
        let source = "let x = a && b"
        let sites = discover(source).filter { $0.mutationOperator == .logical }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "&&")
        XCTAssertEqual(sites[0].mutatedText, "||")
    }

    func testLogicalOrToAnd() {
        let source = "let x = a || b"
        let sites = discover(source).filter { $0.mutationOperator == .logical }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "||")
        XCTAssertEqual(sites[0].mutatedText, "&&")
    }

    // MARK: - Boolean

    func testBooleanTrueToFalse() {
        let source = "let x = true"
        let sites = discover(source).filter { $0.mutationOperator == .boolean }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "true")
        XCTAssertEqual(sites[0].mutatedText, "false")
    }

    func testBooleanFalseToTrue() {
        let source = "let x = false"
        let sites = discover(source).filter { $0.mutationOperator == .boolean }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "false")
        XCTAssertEqual(sites[0].mutatedText, "true")
    }

    // MARK: - Constants

    func testConstantZeroToOne() {
        let source = "let x = 0"
        let sites = discover(source).filter { $0.mutationOperator == .constant }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "0")
        XCTAssertEqual(sites[0].mutatedText, "1")
    }

    func testConstantOneToZero() {
        let source = "let x = 1"
        let sites = discover(source).filter { $0.mutationOperator == .constant }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "1")
        XCTAssertEqual(sites[0].mutatedText, "0")
    }

    func testNoConstantMutationForOtherNumbers() {
        let source = "let x = 42"
        let sites = discover(source).filter { $0.mutationOperator == .constant }
        XCTAssertEqual(sites.count, 0)
    }

    // MARK: - Unary

    func testUnaryRemovalBang() {
        let source = "let x = !flag"
        let sites = discover(source).filter { $0.mutationOperator == .unaryRemoval }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "!")
        XCTAssertEqual(sites[0].mutatedText, "")
    }

    func testUnarySignPlusToMinus() {
        let source = "let x = +value"
        let sites = discover(source).filter { $0.mutationOperator == .unarySign }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "+")
        XCTAssertEqual(sites[0].mutatedText, "-")
    }

    func testUnarySignMinusToPlus() {
        let source = "let x = -value"
        let sites = discover(source).filter { $0.mutationOperator == .unarySign }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "-")
        XCTAssertEqual(sites[0].mutatedText, "+")
    }

    // MARK: - Return value

    func testReturnValueMutation() {
        let source = """
        func foo() -> Int {
            return 42
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .returnValue }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].mutatedText, "return")
    }

    func testNoReturnValueMutationForVoidReturn() {
        let source = """
        func foo() {
            return
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .returnValue }
        XCTAssertEqual(sites.count, 0)
    }

    // MARK: - Guard negate

    func testGuardNegate() {
        let source = """
        func foo(x: Bool) {
            guard x else { return }
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .guardNegate }
        XCTAssertEqual(sites.count, 1)
        XCTAssertTrue(sites[0].mutatedText.contains("!("))
    }

    // MARK: - Multiple mutations in one file

    func testMultipleMutations() {
        let source = """
        func calc(a: Int, b: Int) -> Int {
            if a > 0 && b > 0 {
                return a + b
            }
            return 0
        }
        """
        let sites = discover(source)
        // Should find: >, &&, >, +, return a + b, return 0, 0 (constant), 0 (constant), 0 (constant)
        XCTAssertTrue(sites.count >= 5, "Expected at least 5 mutation sites, got \(sites.count)")
    }

    // MARK: - Line tracking

    func testLineNumbers() {
        let source = """
        let a = true
        let b = false
        """
        let sites = discover(source).filter { $0.mutationOperator == .boolean }
        XCTAssertEqual(sites.count, 2)
        XCTAssertEqual(sites[0].line, 1)
        XCTAssertEqual(sites[1].line, 2)
    }

    // MARK: - Range operator

    func testRangeHalfOpenToClosed() {
        let source = "let r = 0..<10"
        let sites = discover(source).filter { $0.mutationOperator == .range }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "..<")
        XCTAssertEqual(sites[0].mutatedText, "...")
    }

    func testRangeClosedToHalfOpen() {
        let source = "let r = 0...10"
        let sites = discover(source).filter { $0.mutationOperator == .range }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "...")
        XCTAssertEqual(sites[0].mutatedText, "..<")
    }

    // MARK: - Helpers

    private func discover(_ source: String) -> [MutationSite] {
        let discoverer = MutationDiscoverer(source: source)
        return discoverer.discoverSites()
    }
}
