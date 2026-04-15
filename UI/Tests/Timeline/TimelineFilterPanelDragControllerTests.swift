import XCTest
@testable import Retrace

@MainActor
final class TimelineFilterPanelDragControllerTests: XCTestCase {
    func testUpdateDragChangesResolvedOffsetWithoutChangingStoredPosition() {
        let controller = TimelineFilterPanelDragController()

        controller.updateDrag(translation: CGSize(width: 12, height: -8))

        XCTAssertEqual(controller.panelPosition, .zero)
        XCTAssertEqual(controller.dragOffset, CGSize(width: 12, height: -8))
        XCTAssertEqual(controller.resolvedOffset, CGSize(width: 12, height: -8))
    }

    func testEndDragAccumulatesPanelPositionAndClearsLiveOffset() {
        let controller = TimelineFilterPanelDragController()
        controller.updateDrag(translation: CGSize(width: 10, height: 20))

        controller.endDrag(translation: CGSize(width: 10, height: 20))

        XCTAssertEqual(controller.panelPosition, CGSize(width: 10, height: 20))
        XCTAssertEqual(controller.dragOffset, .zero)
        XCTAssertEqual(controller.resolvedOffset, CGSize(width: 10, height: 20))
    }

    func testEndDragAccumulatesOverExistingPanelPosition() {
        let controller = TimelineFilterPanelDragController()
        controller.endDrag(translation: CGSize(width: 10, height: 20))

        controller.endDrag(translation: CGSize(width: -3, height: 5))

        XCTAssertEqual(controller.panelPosition, CGSize(width: 7, height: 25))
        XCTAssertEqual(controller.resolvedOffset, CGSize(width: 7, height: 25))
    }
}
