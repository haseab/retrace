import CoreGraphics
import XCTest
import Shared
@testable import Processing

final class ReadingOrderTests: XCTestCase {

    private func region(_ text: String, _ x: CGFloat, _ y: CGFloat, width: CGFloat = 200, height: CGFloat = 20) -> TextRegion {
        TextRegion(frameID: FrameID(value: 1), text: text, bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    private func window(_ id: UInt32, _ z: Int, _ rect: CGRect) -> CapturedWindow {
        CapturedWindow(
            windowID: id, zOrder: z, bundleID: nil, appName: nil, title: nil,
            bounds: rect, layer: 0, isFocused: z == 0
        )
    }

    /// The old global top-to-bottom sort interleaved a sidebar with the paragraph beside it.
    func testSidebarIsReadBeforeMainColumnInsteadOfInterleaved() {
        let regions = [
            region("Sidebar one", 10, 100),
            region("Main line one", 500, 105, width: 600),
            region("Sidebar two", 10, 130),
            region("Main line two", 500, 132, width: 600),
            region("Sidebar three", 10, 160),
            region("Main line three", 500, 158, width: 600)
        ]

        let ordered = ReadingOrder.order(regions, windows: []).map(\.region.text)

        XCTAssertEqual(ordered, [
            "Sidebar one", "Sidebar two", "Sidebar three",
            "Main line one", "Main line two", "Main line three"
        ])
    }

    func testWordsOnOneLineStayInLeftToRightOrder() {
        let regions = [
            region("world", 220, 101, width: 100),
            region("Hello", 100, 100, width: 100),
            region("Next line", 100, 125, width: 300)
        ]

        let ordered = ReadingOrder.order(regions, windows: []).map(\.region.text)

        XCTAssertEqual(ordered, ["Hello", "world", "Next line"])
    }

    func testFrontWindowIsReadBeforeWindowBehindIt() {
        let back = window(1, 1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        let front = window(2, 0, CGRect(x: 300, y: 300, width: 400, height: 200))
        let regions = [
            region("Back top", 50, 50),
            region("Front dialog", 350, 350),
            region("Back bottom", 50, 700)
        ]

        let ordered = ReadingOrder.order(regions, windows: [front, back])

        XCTAssertEqual(ordered.map(\.region.text), ["Front dialog", "Back top", "Back bottom"])
        XCTAssertEqual(ordered.map(\.windowIndex), [0, 1, 1])
    }

    func testRegionsOutsideEveryWindowComeLast() {
        let only = window(1, 0, CGRect(x: 0, y: 0, width: 500, height: 500))
        let regions = [
            region("Outside", 800, 10),
            region("Inside", 10, 400)
        ]

        let ordered = ReadingOrder.order(regions, windows: [only])

        XCTAssertEqual(ordered.map(\.region.text), ["Inside", "Outside"])
        XCTAssertEqual(ordered.map(\.windowIndex), [0, nil])
    }

    func testTallGapSplitsSectionsBeforeColumns() {
        // A full-width heading over two columns: the heading must come first.
        let regions = [
            region("Heading spanning both columns", 10, 10, width: 1000),
            region("Left body", 10, 100),
            region("Right body", 600, 100)
        ]

        let ordered = ReadingOrder.order(regions, windows: []).map(\.region.text)

        XCTAssertEqual(ordered, ["Heading spanning both columns", "Left body", "Right body"])
    }

    func testWidestGapFindsEmptyIntervalBetweenUnionOfSpans() {
        let gap = ReadingOrder.widestGap(in: [(0, 10), (5, 20), (50, 60), (25, 30)])
        XCTAssertEqual(gap?.width, 20)
        XCTAssertEqual(gap?.position, 40)
        XCTAssertNil(ReadingOrder.widestGap(in: [(0, 10), (5, 20)]))
    }

    func testApplyReadingOrderRebuildsFullTextFromReorderedRegions() {
        let extracted = ExtractedText(
            frameID: FrameID(value: 1),
            timestamp: Date(),
            regions: [
                region("Main", 500, 100, width: 600),
                region("Side", 10, 100)
            ]
        )

        let ordered = FrameProcessingQueue.applyReadingOrder(to: extracted, windows: [])

        XCTAssertEqual(ordered.regions.map(\.text), ["Side", "Main"])
        XCTAssertEqual(ordered.fullText, "Side Main")
    }

    func testApplyReadingOrderLeavesMergedTextUntouched() {
        let extracted = ExtractedText(
            frameID: FrameID(value: 1),
            timestamp: Date(),
            regions: [
                region("Main", 500, 100, width: 600),
                region("Side", 10, 100)
            ],
            fullText: "accessibility text\nMain Side"
        )

        let ordered = FrameProcessingQueue.applyReadingOrder(to: extracted, windows: [])

        XCTAssertEqual(ordered.regions.map(\.text), ["Main", "Side"])
        XCTAssertEqual(ordered.fullText, "accessibility text\nMain Side")
    }
}
