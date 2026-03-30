import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class PhraseLevelRedactionInteractionTests: XCTestCase {
    func testPhraseLevelRedactionTooltipStateUsesCopyTextAfterReveal() {
        let state = SimpleTimelineViewModel.phraseLevelRedactionTooltipState(
            for: 7,
            isRevealed: true
        )

        XCTAssertEqual(state, .copyText)
        XCTAssertEqual(state?.title, "Copy text")
        XCTAssertEqual(state?.tooltipText, "Copy text")
    }

    func testPhraseLevelRedactionTooltipStateUsesInstructionalRevealCopy() {
        XCTAssertEqual(
            SimpleTimelineViewModel.PhraseLevelRedactionTooltipState.reveal.tooltipText,
            "Reveal"
        )
        XCTAssertEqual(
            SimpleTimelineViewModel.PhraseLevelRedactionTooltipState.copyText.tooltipText,
            "Copy text"
        )
    }

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

    func testCopyablePhraseLevelRedactionTextPrefersVisiblePlaintext() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let node = OCRNodeWithText(
            id: 101,
            nodeOrder: 0,
            frameId: 1,
            x: 0.20,
            y: 0.25,
            width: 0.18,
            height: 0.05,
            text: "revealed text",
            encryptedText: "rtx1.mock",
            isRedacted: true
        )

        viewModel.ocrNodes = [node]

        XCTAssertEqual(viewModel.copyablePhraseLevelRedactionText(for: node), "revealed text")
    }
}
