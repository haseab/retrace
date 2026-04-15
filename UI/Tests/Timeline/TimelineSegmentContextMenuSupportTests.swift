import CoreGraphics
import XCTest
@testable import Retrace

final class TimelineSegmentContextMenuSupportTests: XCTestCase {
    func testShouldShowAboveWhenMenuWouldOverflowBottomEdge() {
        XCTAssertTrue(
            TimelineSegmentContextMenuSupport.shouldShowAbove(
                location: CGPoint(x: 100, y: 240),
                containerSize: CGSize(width: 500, height: 400)
            )
        )
    }

    func testAdjustedMenuPositionClampsToVisibleBounds() {
        let position = TimelineSegmentContextMenuSupport.adjustedMenuPosition(
            location: CGPoint(x: 10, y: 10),
            containerSize: CGSize(width: 300, height: 250)
        )

        XCTAssertEqual(position, CGPoint(x: 120, y: 102))
    }

    func testAdjustedMenuPositionUsesAbovePlacementNearBottom() {
        let position = TimelineSegmentContextMenuSupport.adjustedMenuPosition(
            location: CGPoint(x: 150, y: 360),
            containerSize: CGSize(width: 500, height: 420)
        )

        XCTAssertEqual(position, CGPoint(x: 254, y: 274))
    }

    func testSubmenuPositionFlipsToLeftWhenRightEdgeWouldOverflow() {
        let menuPosition = CGPoint(x: 380, y: 200)
        let position = TimelineSegmentContextMenuSupport.submenuPosition(
            menuPosition: menuPosition,
            containerSize: CGSize(width: 500, height: 400),
            submenuWidth: TimelineSegmentContextMenuSupport.tagSubmenuWidth,
            rowOffset: TimelineSegmentContextMenuSupport.tagRowOffset
        )

        XCTAssertEqual(position, CGPoint(x: 178, y: 154))
    }
}
