import XCTest

extension XCTestCase {
    func printTestSeparator() {
        print("\n" + String(repeating: "=", count: 80))
        print("APP INTEGRATION TEST OUTPUT")
        print(String(repeating: "=", count: 80) + "\n")
    }
}
