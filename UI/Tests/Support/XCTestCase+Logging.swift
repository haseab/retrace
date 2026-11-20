import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

extension XCTestCase {
    func printTestSeparator() {
        print("\n" + String(repeating: "=", count: 80))
        print("UI TEST OUTPUT")
        print(String(repeating: "=", count: 80) + "\n")
    }
}
