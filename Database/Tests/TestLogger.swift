import Foundation
import XCTest

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                           TEST LOGGER                                        ║
// ║                                                                              ║
// ║  Provides clean test output with visual separator                           ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

// MARK: - XCTestCase Extension

extension XCTestCase {

    /// Print a separator between XCTest output and custom output
    func printTestSeparator() {
        print("\n" + String(repeating: "=", count: 80))
        print("DATABASE TEST OUTPUT")
        print(String(repeating: "=", count: 80) + "\n")
    }
}
