import CoreGraphics
import XCTest
import Shared
@testable import Capture

final class AXTreeSnapshotterTests: XCTestCase {

    private func window(title: String?, bounds: CGRect) -> CapturedWindow {
        CapturedWindow(
            windowID: 1, zOrder: 0, bundleID: "com.example", appName: "Example", title: title,
            bounds: bounds, layer: 0, isFocused: true
        )
    }

    func testFocusedWindowMatchesWindowMapEntryWithinTolerance() {
        let expected = window(title: "Notes", bounds: CGRect(x: 100, y: 80, width: 800, height: 600))

        XCTAssertTrue(AXTreeSnapshotter.matches(
            windowFrame: CGRect(x: 103, y: 78, width: 799, height: 604), title: "Notes", expected: expected
        ))
    }

    func testDifferentWindowDoesNotMatch() {
        let expected = window(title: "Notes", bounds: CGRect(x: 100, y: 80, width: 800, height: 600))

        // Same app, another window opened in the gap between capture and snapshot.
        XCTAssertFalse(AXTreeSnapshotter.matches(
            windowFrame: CGRect(x: 300, y: 200, width: 800, height: 600), title: "Notes", expected: expected
        ))
        XCTAssertFalse(AXTreeSnapshotter.matches(
            windowFrame: CGRect(x: 100, y: 80, width: 800, height: 600), title: "Private Browsing", expected: expected
        ))
    }

    func testUntitledWindowMapEntryMatchesOnBoundsAlone() {
        let expected = window(title: nil, bounds: CGRect(x: 0, y: 0, width: 500, height: 400))

        XCTAssertTrue(AXTreeSnapshotter.matches(
            windowFrame: CGRect(x: 0, y: 0, width: 500, height: 400), title: "Anything", expected: expected
        ))
    }

    func testTitlePatternsMatchCaseAndDiacriticInsensitively() {
        XCTAssertTrue(AXTreeSnapshotter.titleMatchesAnyPattern("Bank — Statement", patterns: ["bank"]))
        XCTAssertTrue(AXTreeSnapshotter.titleMatchesAnyPattern("Résumé draft", patterns: ["resume"]))
        XCTAssertFalse(AXTreeSnapshotter.titleMatchesAnyPattern("Notes", patterns: ["bank", "  "]))
        XCTAssertFalse(AXTreeSnapshotter.titleMatchesAnyPattern("Notes", patterns: []))
    }
}
