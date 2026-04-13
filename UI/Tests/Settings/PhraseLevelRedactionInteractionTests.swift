import XCTest
import AppKit
@testable import Retrace

@MainActor
final class PhraseLevelRedactionInteractionTests: XCTestCase {
    func testRedactedNodesUsePointingHandCursorInTextSelectionOverlay() {
        let mode = TextSelectionView.preferredCursorMode(
            at: CGPoint(x: 40, y: 24),
            nodeData: [
                TextSelectionView.NodeData(
                    id: 1,
                    rect: NSRect(x: 20, y: 10, width: 40, height: 20),
                    text: "secret",
                    selectionRange: nil,
                    isRedacted: true
                )
            ],
            hyperlinkEntries: []
        )

        XCTAssertEqual(mode, .pointingHand)
    }

    func testVisibleNodesKeepIBeamCursorInTextSelectionOverlay() {
        let mode = TextSelectionView.preferredCursorMode(
            at: CGPoint(x: 40, y: 24),
            nodeData: [
                TextSelectionView.NodeData(
                    id: 1,
                    rect: NSRect(x: 20, y: 10, width: 40, height: 20),
                    text: "visible",
                    selectionRange: nil,
                    isRedacted: false
                )
            ],
            hyperlinkEntries: []
        )

        XCTAssertEqual(mode, .iBeam)
    }

    func testRedactedNodesUsePointingHandCursorInZoomedSelectionOverlay() {
        let mode = ZoomedSelectionView.preferredCursorMode(
            at: CGPoint(x: 40, y: 24),
            nodeData: [
                ZoomedSelectionView.NodeData(
                    id: 1,
                    rect: NSRect(x: 20, y: 10, width: 40, height: 20),
                    text: "secret",
                    selectionRange: nil,
                    isRedacted: true,
                    visibleCharOffset: 0,
                    originalX: 0.1,
                    originalY: 0.2,
                    originalW: 0.3,
                    originalH: 0.1
                )
            ]
        )

        XCTAssertEqual(mode, .pointingHand)
    }
}
