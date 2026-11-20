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
    func testKnownApplicationSuffixDoesNotChangeWindowIdentity() {
        for name in ["Google Chrome", "TextEdit", "Example App"] {
            for separator in [" - ", " – ", " — "] {
                XCTAssertEqual(AccessibilityWindowMatcher.uniqueIndex(
                    bounds: [captured], titles: ["Invoice - November" + separator + name],
                    expectedBounds: captured, expectedTitle: "Invoice - November", applicationName: name), 0)
                XCTAssertEqual(AccessibilityWindowMatcher.uniqueIndex(
                    bounds: [captured], titles: ["Invoice - November"], expectedBounds: captured,
                    expectedTitle: "Invoice - November" + separator + name, applicationName: name), 0)
            }
        }
    }

    func testDifferentDocumentOrUnknownSuffixStillRejects() {
        for title in ["Invoice - October - Google Chrome", "Invoice - November - Other App"] {
            XCTAssertNil(AccessibilityWindowMatcher.uniqueIndex(bounds: [captured], titles: [title],
                expectedBounds: captured, expectedTitle: "Invoice - November", applicationName: "Google Chrome"))
        }
    }

    func testNormalizedTitlesStillRequireUniqueGeometry() {
        XCTAssertNil(AccessibilityWindowMatcher.uniqueIndex(bounds: [captured, captured],
            titles: ["Invoice", "Invoice - Google Chrome"], expectedBounds: captured,
            expectedTitle: "Invoice", applicationName: "Google Chrome"))
        XCTAssertNil(AccessibilityWindowMatcher.uniqueIndex(bounds: [focused],
            titles: ["Invoice - Google Chrome"], expectedBounds: captured,
            expectedTitle: "Invoice", applicationName: "Google Chrome"))
    }
}
