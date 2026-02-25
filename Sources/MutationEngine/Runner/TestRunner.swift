import Foundation

public enum TestRunResult: Sendable, Equatable {
    case passed
    case failed
    case timeout
    case buildError
    case noTests
}

public protocol TestRunner: Sendable {
    func runTests(packagePath: String, filter: String?, timeout: TimeInterval) throws -> TestRunResult
}

public protocol BaselineCapableTestRunner: TestRunner {
    func runBaseline(packagePath: String, filter: String?) throws -> BaselineResult
}
