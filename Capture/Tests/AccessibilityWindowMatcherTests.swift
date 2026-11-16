import XCTest
import CoreGraphics
@testable import Capture

final class AccessibilityWindowMatcherTests: XCTestCase {
    // Window geometries recorded from the failing live TextEdit capture.
    private let focused = CGRect(x: 338, y: 132, width: 807, height: 1085)
    private let captured = CGRect(x: 309, y: 103, width: 603, height: 505)

    func testFindsCapturedDocumentInsteadOfDifferentFocusedDocument() {
        XCTAssertEqual(AccessibilityWindowMatcher.uniqueIndex(
            bounds: [focused, captured], titles: ["Other", "Fixture"],
            expectedBounds: captured, expectedTitle: "Fixture"), 1)
    }

    func testRejectsAmbiguousOrMissingWindow() {
        XCTAssertNil(AccessibilityWindowMatcher.uniqueIndex(
            bounds: [captured, captured], titles: ["Fixture", "Fixture"],
            expectedBounds: captured, expectedTitle: "Fixture"))
        XCTAssertNil(AccessibilityWindowMatcher.uniqueIndex(
            bounds: [focused], titles: ["Fixture"],
            expectedBounds: captured, expectedTitle: "Fixture"))
    }

    func testRejectsSameBoundsWithDifferentTitle() {
        XCTAssertNil(AccessibilityWindowMatcher.uniqueIndex(
            bounds: [captured], titles: ["Other"],
            expectedBounds: captured, expectedTitle: "Fixture"))
    }
}
