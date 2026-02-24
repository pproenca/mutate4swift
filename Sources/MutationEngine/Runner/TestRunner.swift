import Foundation

public enum TestRunResult: Sendable {
    case passed
    case failed
    case timeout
    case buildError
}

public protocol TestRunner: Sendable {
    func runTests(packagePath: String, filter: String?, timeout: TimeInterval) throws -> TestRunResult
}
