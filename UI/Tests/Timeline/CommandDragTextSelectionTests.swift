import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class CommandDragTextSelectionTests: XCTestCase {
    func testCommandDragSelectsIntersectingNodesWithFullRanges() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Alpha", x: 0.10, y: 0.10, width: 0.20, height: 0.08),
            makeNode(id: 2, text: "Beta", x: 0.36, y: 0.12, width: 0.22, height: 0.08),
            makeNode(id: 3, text: "Gamma", x: 0.70, y: 0.12, width: 0.18, height: 0.08)
        ]

        viewModel.startDragSelection(at: CGPoint(x: 0.18, y: 0.09), mode: .box)
        viewModel.updateDragSelection(to: CGPoint(x: 0.56, y: 0.24), mode: .box)
        viewModel.endDragSelection()

        XCTAssertEqual(viewModel.boxSelectedNodeIDs, Set([1, 2]))

        let firstRange = viewModel.getSelectionRange(for: 1)
        let secondRange = viewModel.getSelectionRange(for: 2)
        let thirdRange = viewModel.getSelectionRange(for: 3)

        XCTAssertEqual(firstRange?.start, 0)
        XCTAssertEqual(firstRange?.end, "Alpha".count)
        XCTAssertEqual(secondRange?.start, 0)
        XCTAssertEqual(secondRange?.end, "Beta".count)
        XCTAssertNil(thirdRange)
        XCTAssertEqual(viewModel.selectedText, "Alpha Beta")
    }

    func testCommandDragIncludesNodeTouchingSelectionBoundary() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 9, text: "Edge", x: 0.60, y: 0.20, width: 0.20, height: 0.10)
        ]

        // Rectangle maxX/maxY land exactly on node minX/minY, which should still count as touching.
        viewModel.startDragSelection(at: CGPoint(x: 0.20, y: 0.10), mode: .box)
        viewModel.updateDragSelection(to: CGPoint(x: 0.60, y: 0.20), mode: .box)

        XCTAssertEqual(viewModel.boxSelectedNodeIDs, Set([9]))
        XCTAssertEqual(viewModel.getSelectionRange(for: 9)?.start, 0)
        XCTAssertEqual(viewModel.getSelectionRange(for: 9)?.end, "Edge".count)
    }

    func testClearTextSelectionResetsCommandDragSelection() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 4, text: "Reset me", x: 0.25, y: 0.25, width: 0.30, height: 0.10)
        ]

        viewModel.startDragSelection(at: CGPoint(x: 0.20, y: 0.20), mode: .box)
        viewModel.updateDragSelection(to: CGPoint(x: 0.40, y: 0.30), mode: .box)
        XCTAssertTrue(viewModel.hasSelection)

        viewModel.clearTextSelection()

        XCTAssertTrue(viewModel.boxSelectedNodeIDs.isEmpty)
        XCTAssertFalse(viewModel.hasSelection)
        XCTAssertEqual(viewModel.selectedText, "")
    }

    private func makeNode(
        id: Int,
        text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> OCRNodeWithText {
        OCRNodeWithText(
            id: id,
            frameId: 1,
            x: x,
            y: y,
            width: width,
            height: height,
            text: text
        )
    }
}
