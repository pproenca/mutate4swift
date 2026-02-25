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

    func testArithmeticModuloToMultiply() {
        let source = "let x = a % b"
        let sites = discover(source)
        let arithmetic = sites.filter { $0.mutationOperator == .arithmetic }
        XCTAssertEqual(arithmetic.count, 1)
        XCTAssertEqual(arithmetic[0].originalText, "%")
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

    // MARK: - Bitwise

    func testBitwiseOperators() {
        let pairs: [(String, String)] = [
            ("&", "|"),
            ("|", "&"),
            ("^", "&"),
            ("<<", ">>"),
            (">>", "<<"),
        ]

        for (original, expected) in pairs {
            let source = "let x = a \(original) b"
            let sites = discover(source).filter { $0.mutationOperator == .bitwise }
            XCTAssertEqual(sites.count, 1, "Expected 1 bitwise site for \(original)")
            XCTAssertEqual(sites[0].originalText, original)
            XCTAssertEqual(sites[0].mutatedText, expected)
        }
    }

    func testBitwisePrefixNotRemoval() {
        let source = "let x = ~mask"
        let sites = discover(source).filter { $0.mutationOperator == .bitwise }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "~")
        XCTAssertEqual(sites[0].mutatedText, "")
    }

    // MARK: - Compound assignment

    func testCompoundAssignmentOperators() {
        let pairs: [(String, String)] = [
            ("+=", "-="),
            ("-=", "+="),
            ("*=", "/="),
            ("/=", "*="),
            ("&=", "|="),
            ("|=", "&="),
            ("<<=", ">>="),
            (">>=", "<<="),
        ]

        for (original, expected) in pairs {
            let source = """
            func update() {
                var x = 1
                x \(original) 2
            }
            """
            let sites = discover(source).filter { $0.mutationOperator == .compoundAssignment }
            XCTAssertEqual(sites.count, 1, "Expected 1 compound assignment site for \(original)")
            XCTAssertEqual(sites[0].originalText, original)
            XCTAssertEqual(sites[0].mutatedText, expected)
        }
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

    // MARK: - Constant boundary

    func testConstantBoundaryProducesPlusAndMinusOneMutations() {
        let source = "let limit = 42"
        let sites = discover(source).filter { $0.mutationOperator == .constantBoundary }
        XCTAssertEqual(sites.count, 2)
        let mutated = Set(sites.map { $0.mutatedText })
        XCTAssertEqual(mutated, Set(["43", "41"]))
    }

    func testConstantBoundarySkipsZeroAndOne() {
        let source = """
        let a = 0
        let b = 1
        """
        let sites = discover(source).filter { $0.mutationOperator == .constantBoundary }
        XCTAssertEqual(sites.count, 0)
    }

    func testConstantBoundarySkipsNonDecimalLiterals() {
        let source = "let mask = 0x10"
        let sites = discover(source).filter { $0.mutationOperator == .constantBoundary }
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

    // MARK: - Typed return defaults

    func testTypedReturnDefaultForBoolReturnType() {
        let source = """
        func isReady() -> Bool {
            return shouldRun()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .typedReturnDefault }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].mutatedText, "return false")
    }

    func testTypedReturnDefaultForStringReturnType() {
        let source = """
        func displayName() -> String {
            return fullName()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .typedReturnDefault }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].mutatedText, "return \"\"")
    }

    func testTypedReturnDefaultForNumericReturnType() {
        let source = """
        func count() -> Int {
            return total()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .typedReturnDefault }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].mutatedText, "return 0")
    }

    func testTypedReturnDefaultForOptionalReturnType() {
        let source = """
        func maybeCount() -> Int? {
            return total()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .typedReturnDefault }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].mutatedText, "return nil")
    }

    func testTypedReturnDefaultSkipsUnsupportedTypes() {
        let source = """
        struct User {}
        func makeUser() -> User {
            return User()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .typedReturnDefault }
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

    func testGuardNegateSkipsMultipleConditions() {
        let source = """
        func foo(x: Bool, y: Bool) {
            guard x, y else { return }
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .guardNegate }
        XCTAssertEqual(sites.count, 0)
    }

    // MARK: - Condition negate (if/while)

    func testIfConditionNegate() {
        let source = """
        func foo(x: Bool) {
            if x {
                print("yes")
            }
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .conditionNegate }
        XCTAssertEqual(sites.count, 1)
        XCTAssertTrue(sites[0].mutatedText.contains("!("))
    }

    func testWhileConditionNegate() {
        let source = """
        func foo() {
            while running {
                step()
            }
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .conditionNegate }
        XCTAssertEqual(sites.count, 1)
        XCTAssertTrue(sites[0].mutatedText.contains("!("))
    }

    func testIfConditionNegateSkipsBangPrefix() {
        let source = """
        func foo(x: Bool) {
            if !x {
                print("no")
            }
        }
        """
        // Should NOT produce a conditionNegate (unaryRemoval covers the `!`)
        let sites = discover(source).filter { $0.mutationOperator == .conditionNegate }
        XCTAssertEqual(sites.count, 0)
    }

    // MARK: - Try mutation

    func testTryProducesTryOptionalAndTryForce() {
        let source = """
        func foo() throws -> Int {
            return try bar()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .tryMutation }
        XCTAssertEqual(sites.count, 2)
        let mutated = Set(sites.map { $0.mutatedText })
        XCTAssertEqual(mutated, Set(["try?", "try!"]))
    }

    func testTryOptionalToTryForce() {
        let source = """
        func foo() {
            _ = try? bar()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .tryMutation }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "?")
        XCTAssertEqual(sites[0].mutatedText, "!")
    }

    func testTryForceToTryOptional() {
        let source = """
        func foo() {
            _ = try! bar()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .tryMutation }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "!")
        XCTAssertEqual(sites[0].mutatedText, "?")
    }

    // MARK: - Cast strength

    func testCastStrengthOptionalToForced() {
        let source = "let dog = pet as? Dog"
        let sites = discover(source).filter { $0.mutationOperator == .castStrength }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "?")
        XCTAssertEqual(sites[0].mutatedText, "!")
    }

    func testCastStrengthForcedToOptional() {
        let source = "let dog = pet as! Dog"
        let sites = discover(source).filter { $0.mutationOperator == .castStrength }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "!")
        XCTAssertEqual(sites[0].mutatedText, "?")
    }

    func testCastStrengthSkipsPlainAsCast() {
        let source = "let dog = pet as Dog"
        let sites = discover(source).filter { $0.mutationOperator == .castStrength }
        XCTAssertEqual(sites.count, 0)
    }

    // MARK: - Optional chaining

    func testOptionalChainingToForceUnwrap() {
        let source = "let name = user?.name"
        let sites = discover(source).filter { $0.mutationOperator == .optionalChaining }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "?")
        XCTAssertEqual(sites[0].mutatedText, "!")
    }

    func testOptionalChainingFindsEachQuestionMarkInNestedChain() {
        let source = "let city = user?.address?.city"
        let sites = discover(source).filter { $0.mutationOperator == .optionalChaining }
        XCTAssertEqual(sites.count, 2)
        for site in sites {
            XCTAssertEqual(site.originalText, "?")
            XCTAssertEqual(site.mutatedText, "!")
        }
    }

    func testOptionalChainingSkipsOptionalTypeAnnotations() {
        let source = "let name: String? = nil"
        let sites = discover(source).filter { $0.mutationOperator == .optionalChaining }
        XCTAssertEqual(sites.count, 0)
    }

    // MARK: - Ternary swap

    func testTernarySwap() {
        let source = "let status = isActive ? \"on\" : \"off\""
        let sites = discover(source).filter { $0.mutationOperator == .ternarySwap }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "isActive ? \"on\" : \"off\"")
        XCTAssertEqual(sites[0].mutatedText, "isActive ? \"off\" : \"on\"")
    }

    // MARK: - String literal

    func testStringLiteralToEmptyString() {
        let source = "let key = \"user_id\""
        let sites = discover(source).filter { $0.mutationOperator == .stringLiteral }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "\"user_id\"")
        XCTAssertEqual(sites[0].mutatedText, "\"\"")
    }

    func testStringLiteralSkipsInterpolation() {
        let source = "let msg = \"hello \\(name)\""
        let sites = discover(source).filter { $0.mutationOperator == .stringLiteral }
        XCTAssertEqual(sites.count, 0)
    }

    func testStringLiteralSkipsMultiline() {
        let source = """
        let msg = \"\"\"
        hello
        \"\"\"
        """
        let sites = discover(source).filter { $0.mutationOperator == .stringLiteral }
        XCTAssertEqual(sites.count, 0)
    }

    func testStringLiteralSkipsAlreadyEmpty() {
        let source = "let msg = \"\""
        let sites = discover(source).filter { $0.mutationOperator == .stringLiteral }
        XCTAssertEqual(sites.count, 0)
    }

    // MARK: - Nil coalescing

    func testNilCoalescingMutations() {
        let source = "let name = user?.name ?? \"Anonymous\""
        let sites = discover(source).filter { $0.mutationOperator == .nilCoalescing }
        XCTAssertEqual(sites.count, 2)
        XCTAssertEqual(sites[0].originalText, "user?.name ?? \"Anonymous\"")
        let mutated = Set(sites.map { $0.mutatedText })
        XCTAssertEqual(mutated, Set(["\"Anonymous\"", "(user?.name)!"]))
    }

    // MARK: - Stdlib semantic

    func testStdlibSemanticMinToMax() {
        let source = "let best = min(a, b)"
        let sites = discover(source).filter { $0.mutationOperator == .stdlibSemantic }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "min")
        XCTAssertEqual(sites[0].mutatedText, "max")
    }

    func testStdlibSemanticMaxToMin() {
        let source = "let best = max(a, b)"
        let sites = discover(source).filter { $0.mutationOperator == .stdlibSemantic }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "max")
        XCTAssertEqual(sites[0].mutatedText, "min")
    }

    func testStdlibSemanticCollectionMinToMax() {
        let source = "let best = numbers.min()"
        let sites = discover(source).filter { $0.mutationOperator == .stdlibSemantic }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "min")
        XCTAssertEqual(sites[0].mutatedText, "max")
    }

    // MARK: - Statement deletion

    func testStatementDeletionForAssignment() {
        let source = """
        func bump() {
            count += 1
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .statementDeletion }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "count += 1")
        XCTAssertEqual(sites[0].mutatedText, "")
    }

    func testStatementDeletionForSimpleAssignment() {
        let source = """
        func bump() {
            count = 1
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .statementDeletion }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "count = 1")
    }

    func testStatementDeletionForAssignmentWithSemicolon() {
        let source = """
        func bump() {
            count += 1;
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .statementDeletion }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "count += 1;")
    }

    func testStatementDeletionSkipsDeclarations() {
        let source = """
        func bump() {
            let x = 1
            var y = 2
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .statementDeletion }
        XCTAssertEqual(sites.count, 0)
    }

    func testStatementDeletionSkipsNonAssignmentExpression() {
        let source = """
        func bump() {
            1 + 2
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .statementDeletion }
        XCTAssertEqual(sites.count, 0)
    }

    func testStatementDeletionSkipsComparisonExpression() {
        let source = """
        func bump() {
            isReady == true
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .statementDeletion }
        XCTAssertEqual(sites.count, 0)
    }

    // MARK: - Defer removal

    func testDeferRemoval() {
        let source = """
        func run() {
            defer { cleanup() }
            work()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .deferRemoval }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "defer { cleanup() }")
        XCTAssertEqual(sites[0].mutatedText, "")
    }

    // MARK: - Void call removal

    func testVoidCallRemovalForStatementLevelCall() {
        let source = """
        func run() {
            logger.warn("threshold exceeded")
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .voidCallRemoval }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "logger.warn(\"threshold exceeded\")")
        XCTAssertEqual(sites[0].mutatedText, "")
    }

    func testVoidCallRemovalForTryWrappedCall() {
        let source = """
        func run() {
            try? save()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .voidCallRemoval }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "try? save()")
    }

    func testVoidCallRemovalForAwaitWrappedCall() {
        let source = """
        func run() async {
            await save()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .voidCallRemoval }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "await save()")
    }

    func testVoidCallRemovalSkipsCallUsedInDeclaration() {
        let source = """
        func run() {
            let value = compute()
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .voidCallRemoval }
        XCTAssertEqual(sites.count, 0)
    }

    func testCallStatementOnlyProducesVoidCallRemoval() {
        let source = """
        func run() {
            log()
        }
        """
        let statementDeletion = discover(source).filter { $0.mutationOperator == .statementDeletion }
        let voidCallRemoval = discover(source).filter { $0.mutationOperator == .voidCallRemoval }
        XCTAssertEqual(statementDeletion.count, 0)
        XCTAssertEqual(voidCallRemoval.count, 1)
    }

    // MARK: - Loop control

    func testLoopControlContinueToBreak() {
        let source = """
        func run() {
            while active {
                continue
            }
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .loopControl }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "continue")
        XCTAssertEqual(sites[0].mutatedText, "break")
    }

    func testLoopControlBreakToContinueInsideLoop() {
        let source = """
        func run() {
            while active {
                break
            }
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .loopControl }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "break")
        XCTAssertEqual(sites[0].mutatedText, "continue")
    }

    func testLoopControlSkipsBreakInsideSwitch() {
        let source = """
        func run(x: Int) {
            switch x {
            case 1:
                break
            default:
                break
            }
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .loopControl }
        XCTAssertEqual(sites.count, 0)
    }

    // MARK: - Concurrency context

    func testConcurrencyContextTaskToDetached() {
        let source = """
        func run() {
            _ = Task { await work() }
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .concurrencyContext }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "Task")
        XCTAssertEqual(sites[0].mutatedText, "Task.detached")
    }

    func testConcurrencyContextDetachedToTask() {
        let source = """
        func run() {
            _ = Task.detached { await work() }
        }
        """
        let sites = discover(source).filter { $0.mutationOperator == .concurrencyContext }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].originalText, "Task.detached")
        XCTAssertEqual(sites[0].mutatedText, "Task")
    }

    // MARK: - Tailored identifier literal

    func testTailoredIdentifierLiteralSwapsWithinFileLiteralPool() {
        let source = """
        let userKey = "user_id"
        let fallback = "anonymous"
        """
        let sites = discover(source).filter { $0.mutationOperator == .tailoredIdentifierLiteral }
        XCTAssertEqual(sites.count, 2)
        XCTAssertEqual(sites[0].mutatedText, "\"anonymous\"")
        XCTAssertEqual(sites[1].mutatedText, "\"user_id\"")
    }

    func testTailoredIdentifierLiteralSkipsNonIdentifierLikeString() {
        let source = "let message = \"hello world\""
        let sites = discover(source).filter { $0.mutationOperator == .tailoredIdentifierLiteral }
        XCTAssertEqual(sites.count, 0)
    }

    func testIfMultipleConditionsSkipped() {
        let source = """
        func foo(a: Bool, b: Bool) {
            if a, b {
                print("both")
            }
        }
        """
        // Multi-condition ifs are skipped (too complex to negate safely)
        let sites = discover(source).filter { $0.mutationOperator == .conditionNegate }
        XCTAssertEqual(sites.count, 0)
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
