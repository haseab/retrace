import XCTest
@testable import Retrace
import Shared

final class SearchHighlightTooltipTests: XCTestCase {
    func testTooltipSafeZoneIncludesBridgeBetweenHighlightAndTooltip() {
        let tooltipFrame = CGRect(x: 120, y: 60, width: 210, height: 34)
        let sourceRect = CGRect(x: 180, y: 120, width: 80, height: 24)

        let safeZone = SearchHighlightOverlay.tooltipInteractionSafeZone(
            tooltipFrame: tooltipFrame,
            sourceRect: sourceRect
        )

        XCTAssertTrue(safeZone.contains(CGPoint(x: 220, y: 100)))
    }

    func testTooltipSafeZoneDoesNotExtendAcrossWholeHighlightedRow() {
        let tooltipFrame = CGRect(x: 120, y: 60, width: 210, height: 34)
        let sourceRect = CGRect(x: 180, y: 120, width: 80, height: 24)

        let safeZone = SearchHighlightOverlay.tooltipInteractionSafeZone(
            tooltipFrame: tooltipFrame,
            sourceRect: sourceRect
        )

        XCTAssertFalse(safeZone.contains(CGPoint(x: sourceRect.maxX + 8, y: sourceRect.midY)))
    }

    func testTooltipDismissesOutsideClicks() {
        let tooltipFrame = CGRect(x: 120, y: 60, width: 210, height: 34)
        let highlightedRects = [
            CGRect(x: 180, y: 120, width: 80, height: 24)
        ]

        XCTAssertTrue(
            SearchHighlightOverlay.shouldDismissTooltip(
                for: CGPoint(x: 40, y: 40),
                highlightedRects: highlightedRects,
                tooltipFrame: tooltipFrame
            )
        )
    }

    func testTooltipStaysVisibleForClicksInsideHighlightOrTooltip() {
        let tooltipFrame = CGRect(x: 120, y: 60, width: 210, height: 34)
        let highlightedRects = [
            CGRect(x: 180, y: 120, width: 80, height: 24)
        ]

        XCTAssertFalse(
            SearchHighlightOverlay.shouldDismissTooltip(
                for: CGPoint(x: 200, y: 132),
                highlightedRects: highlightedRects,
                tooltipFrame: tooltipFrame
            )
        )
        XCTAssertFalse(
            SearchHighlightOverlay.shouldDismissTooltip(
                for: CGPoint(x: 180, y: 76),
                highlightedRects: highlightedRects,
                tooltipFrame: tooltipFrame
            )
        )
    }

    @MainActor
    func testPhraseLevelRedactionTooltipStateIsQueuedWhileRewriteIsPending() {
        XCTAssertEqual(
            SimpleTimelineViewModel.phraseLevelRedactionTooltipState(for: 5, isRevealed: false),
            .queued
        )
        XCTAssertEqual(
            SimpleTimelineViewModel.phraseLevelRedactionTooltipState(for: 6, isRevealed: true),
            .queued
        )
    }

    @MainActor
    func testPhraseLevelRedactionTooltipStateSupportsRevealAndCopyTextAfterRewriteCompletes() {
        XCTAssertEqual(
            SimpleTimelineViewModel.phraseLevelRedactionTooltipState(for: 7, isRevealed: false),
            .reveal
        )
        XCTAssertEqual(
            SimpleTimelineViewModel.phraseLevelRedactionTooltipState(for: 7, isRevealed: true),
            .copyText
        )
    }

    @MainActor
    func testPhraseLevelRedactionTooltipStateIsUnavailableForFailedFrames() {
        XCTAssertNil(
            SimpleTimelineViewModel.phraseLevelRedactionTooltipState(for: 8, isRevealed: false)
        )
    }

    @MainActor
    func testPhraseLevelRedactionOutlineStateKeepsQueuedOutlineOnlyWhileRewriteIsPending() {
        XCTAssertEqual(
            SimpleTimelineViewModel.phraseLevelRedactionOutlineState(
                for: 5,
                isTooltipActive: false
            ),
            .queued
        )
        XCTAssertEqual(
            SimpleTimelineViewModel.phraseLevelRedactionOutlineState(
                for: 7,
                isTooltipActive: false
            ),
            .hidden
        )
    }

    @MainActor
    func testPhraseLevelRedactionOutlineStateShowsHoverOutlineForCompletedFrames() {
        XCTAssertEqual(
            SimpleTimelineViewModel.phraseLevelRedactionOutlineState(
                for: 7,
                isTooltipActive: true
            ),
            .active
        )
        XCTAssertEqual(
            SimpleTimelineViewModel.phraseLevelRedactionOutlineState(
                for: 2,
                isTooltipActive: true
            ),
            .active
        )
    }

    @MainActor
    func testRedactionTooltipFrameCentersAboveNodeWhenThereIsRoom() {
        let nodeRect = CGRect(x: 120, y: 140, width: 80, height: 24)
        let tooltipFrame = RedactionTooltipOverlay.tooltipFrame(
            for: nodeRect,
            state: .reveal,
            containerSize: CGSize(width: 400, height: 300)
        )

        XCTAssertEqual(tooltipFrame.midX, nodeRect.midX, accuracy: 0.5)
        XCTAssertLessThan(tooltipFrame.maxY, nodeRect.maxY)
    }

    @MainActor
    func testRedactionTooltipFrameFallsBelowNodeNearTopEdge() {
        let nodeRect = CGRect(x: 120, y: 8, width: 80, height: 24)
        let tooltipFrame = RedactionTooltipOverlay.tooltipFrame(
            for: nodeRect,
            state: .queued,
            containerSize: CGSize(width: 400, height: 300)
        )

        XCTAssertEqual(tooltipFrame.midX, nodeRect.midX, accuracy: 0.5)
        XCTAssertGreaterThan(tooltipFrame.minY, nodeRect.minY)
    }

    @MainActor
    func testCmdFHighlightModeReturnsSubstringRanges() {
        let node = OCRNodeWithText(
            id: 1,
            frameId: 42,
            x: 0.2,
            y: 0.3,
            width: 0.4,
            height: 0.1,
            text: "hello sohrab there"
        )

        let matches = SimpleTimelineViewModel.searchHighlightMatches(
            in: [node],
            query: "sohrab",
            mode: .matchedTextRanges
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].node.id, node.id)
        XCTAssertEqual(matches[0].ranges.count, 1)
        XCTAssertEqual(String(node.text.lowercased()[matches[0].ranges[0]]), "sohrab")
    }

    @MainActor
    func testSearchResultHighlightModeReturnsWholeNodeWithoutSubstringRanges() {
        let matchingNode = OCRNodeWithText(
            id: 1,
            frameId: 42,
            x: 0.2,
            y: 0.3,
            width: 0.4,
            height: 0.1,
            text: "hello sohrab there"
        )
        let nonMatchingNode = OCRNodeWithText(
            id: 2,
            frameId: 42,
            x: 0.1,
            y: 0.45,
            width: 0.3,
            height: 0.08,
            text: "goodbye world"
        )

        let matches = SimpleTimelineViewModel.searchHighlightMatches(
            in: [matchingNode, nonMatchingNode],
            query: "sohrab",
            mode: .matchedNodes
        )

        XCTAssertEqual(matches.map(\.node.id), [matchingNode.id])
        XCTAssertTrue(matches[0].ranges.isEmpty)
    }
}
