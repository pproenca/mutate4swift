import XCTest
@testable import MutationEngine

final class TestFileMapperTests: XCTestCase {
    let mapper = TestFileMapper()

    func testTestFilterFromSourceFile() {
        let filter = mapper.testFilter(forSourceFile: "/path/to/Sources/MyLib/Calculator.swift")
        XCTAssertEqual(filter, "CalculatorTests")
    }

    func testTestFilterFromNestedSourceFile() {
        let filter = mapper.testFilter(forSourceFile: "/path/to/Sources/MyLib/Utils/Helper.swift")
        XCTAssertEqual(filter, "HelperTests")
    }

    func testTestFilterStripsExtension() {
        let filter = mapper.testFilter(forSourceFile: "Foo.swift")
        XCTAssertEqual(filter, "FooTests")
    }
}
