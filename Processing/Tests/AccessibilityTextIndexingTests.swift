import CoreGraphics
import XCTest
import Shared
@testable import Processing

final class AccessibilityTextIndexingTests: XCTestCase {

    private func snapshot(_ root: AXNodeSnapshot) -> AXTreeSnapshot {
        AXTreeSnapshot(bundleID: "com.example", processID: 1, root: root, nodeCount: 1, isTruncated: false, walkMilliseconds: 1)
    }

    private func ocr(_ main: [String], chrome: [String] = []) -> ExtractedText {
        ExtractedText(
            frameID: FrameID(value: 9),
            timestamp: Date(),
            regions: main.enumerated().map { index, text in
                TextRegion(frameID: FrameID(value: 9), text: text, bounds: CGRect(x: 0, y: CGFloat(index) * 30, width: 300, height: 20))
            },
            chromeRegions: chrome.map {
                TextRegion(frameID: FrameID(value: 9), text: $0, bounds: CGRect(x: 0, y: 0, width: 100, height: 10))
            }
        )
    }

    // MARK: - AXTreeSnapshot.textLines

    func testTextLinesReadValuesTitlesAndLabelsInTreeOrderWithoutDuplicates() {
        let root = AXNodeSnapshot(
            role: "AXWindow",
            title: "Inbox",
            children: [
                AXNodeSnapshot(role: "AXButton", title: "Compose", label: "Compose"),
                AXNodeSnapshot(role: "AXStaticText", value: "  Meeting at noon  "),
                AXNodeSnapshot(role: "AXImage", label: "Avatar"),
                AXNodeSnapshot(role: "AXStaticText", value: "Meeting at noon"),
                AXNodeSnapshot(role: "AXGroup", value: "ignored: groups have no text value")
            ]
        )

        let lines = snapshot(root).textLines().map(\.text)

        XCTAssertEqual(lines, ["Inbox", "Meeting at noon", "Avatar"])
    }

    func testTextLinesSkipControlLabelsButKeepTextInsideThem() {
        let root = AXNodeSnapshot(
            role: "AXWindow",
            title: "ledger.py",
            children: [
                AXNodeSnapshot(role: "AXButton", label: "Toggle Panel (⌘J)"),
                AXNodeSnapshot(role: "AXMenuItem", title: "Split Editor Right"),
                AXNodeSnapshot(
                    role: "AXButton",
                    children: [AXNodeSnapshot(role: "AXStaticText", value: "Continue without Signing In")]
                ),
                AXNodeSnapshot(role: "AXGroup", label: "Explorer Section: quokka-ws"),
                AXNodeSnapshot(role: "AXRadioButton", title: "shipping.py")
            ]
        )

        let lines = snapshot(root).textLines().map(\.text)

        XCTAssertEqual(lines, ["ledger.py", "Continue without Signing In", "Explorer Section: quokka-ws", "shipping.py"])
    }

    // MARK: - appendingAccessibilityText

    func testAddsOnlyLinesOCRMissedAfterChromeText() {
        let extracted = ocr(["Quarterly report draft"], chrome: ["File Edit"])
        let root = AXNodeSnapshot(
            role: "AXWindow",
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Quarterly report draft"),
                AXNodeSnapshot(
                    role: "AXStaticText",
                    value: "Hidden tooltip text",
                    bounds: CGRect(x: 10, y: 400, width: 200, height: 18)
                )
            ]
        )

        let result = FrameProcessingQueue.appendingAccessibilityText(to: extracted, snapshot: snapshot(root))

        XCTAssertEqual(result.fullText, extracted.fullText)
        XCTAssertEqual(result.regions, extracted.regions)
        XCTAssertEqual(result.chromeRegions.map(\.text), ["File Edit", "Hidden tooltip text"])
        XCTAssertEqual(result.chromeText, "File Edit Hidden tooltip text")
        XCTAssertEqual(result.chromeRegions.last?.bounds, CGRect(x: 10, y: 400, width: 200, height: 18))
    }

    func testLineMostlyMatchedByOCRIsTreatedAsCovered() {
        // OCR misread one word of five ("0" for "O"); 4/5 = 0.8 counts as covered.
        let extracted = ocr(["plaid transaction ZzjQM1JOeof as example"])
        let root = AXNodeSnapshot(
            role: "AXStaticText",
            value: "plaid transaction ZzjQM1J0eof as example"
        )

        let result = FrameProcessingQueue.appendingAccessibilityText(to: extracted, snapshot: snapshot(root))

        XCTAssertEqual(result.chromeRegions, extracted.chromeRegions)
    }

    func testMultilineValueIsJudgedLineByLine() {
        // A text area exposes the whole document as one value. Its one line OCR could
        // not read must still be added even though most of the value is covered.
        let extracted = ocr([
            "Main paragraph one about kumquat logistics",
            "Main paragraph two about kumquat logistics",
            "Main paragraph three about kumquat logistics"
        ])
        let root = AXNodeSnapshot(
            role: "AXTextArea",
            value: """
                Main paragraph one about kumquat logistics
                Main paragraph two about kumquat logistics
                Main paragraph three about kumquat logistics
                zephyrine axolotl microprint marker
                """
        )

        let result = FrameProcessingQueue.appendingAccessibilityText(to: extracted, snapshot: snapshot(root))

        XCTAssertEqual(result.chromeRegions.map(\.text), ["zephyrine axolotl microprint marker"])
        XCTAssertEqual(result.chromeRegions.first?.bounds, .zero)
    }

    func testLinesOfSingleCharacterTokensAreKeptUnlessOCRHasThem() {
        let extracted = ocr(["Grade B"])
        let root = AXNodeSnapshot(
            role: "AXWindow",
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "A B C"),
                AXNodeSnapshot(role: "AXStaticText", value: "7"),
                AXNodeSnapshot(role: "AXStaticText", value: "B")
            ]
        )

        let result = FrameProcessingQueue.appendingAccessibilityText(to: extracted, snapshot: snapshot(root))

        XCTAssertEqual(result.chromeRegions.map(\.text), ["A B C", "7"])
    }

    func testNoSnapshotLeavesTextUnchanged() {
        let extracted = ocr(["Hello"], chrome: ["Menu"])
        let result = FrameProcessingQueue.appendingAccessibilityText(to: extracted, snapshot: nil)
        XCTAssertEqual(result.chromeText, "Menu")
        XCTAssertEqual(result.chromeRegions, extracted.chromeRegions)
    }
}
