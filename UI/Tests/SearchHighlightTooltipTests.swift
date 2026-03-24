import XCTest
@testable import Retrace
import Shared
import App

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

    func testPaddedHighlightRectExpandsBeyondOriginalBounds() {
        let frameRect = CGRect(x: 0, y: 0, width: 400, height: 240)
        let originalRect = CGRect(x: 120, y: 80, width: 90, height: 24)

        let paddedRect = SearchHighlightOverlay.paddedHighlightRect(originalRect, within: frameRect)

        XCTAssertLessThan(paddedRect.minX, originalRect.minX)
        XCTAssertGreaterThan(paddedRect.maxX, originalRect.maxX)
        XCTAssertLessThan(paddedRect.minY, originalRect.minY)
        XCTAssertGreaterThan(paddedRect.maxY, originalRect.maxY)
    }

    func testPaddedHighlightRectClipsToFrameBounds() {
        let frameRect = CGRect(x: 0, y: 0, width: 400, height: 240)
        let originalRect = CGRect(x: 2, y: 1, width: 60, height: 20)

        let paddedRect = SearchHighlightOverlay.paddedHighlightRect(originalRect, within: frameRect)

        XCTAssertEqual(paddedRect.minX, frameRect.minX, accuracy: 0.001)
        XCTAssertEqual(paddedRect.minY, frameRect.minY, accuracy: 0.001)
        XCTAssertLessThanOrEqual(paddedRect.maxX, frameRect.maxX)
        XCTAssertLessThanOrEqual(paddedRect.maxY, frameRect.maxY)
    }

    func testTextSpanEstimatorShiftsSpanForWideVsNarrowPrefixes() {
        let widePrefixText = "WWW padding tail"
        let narrowPrefixText = "iii padding tail"
        let wideRange = widePrefixText.range(of: "padding")!
        let narrowRange = narrowPrefixText.range(of: "padding")!

        let wideFractions = OCRTextLayoutEstimator.spanFractions(in: widePrefixText, range: wideRange)
        let narrowFractions = OCRTextLayoutEstimator.spanFractions(in: narrowPrefixText, range: narrowRange)

        XCTAssertGreaterThan(wideFractions.start, narrowFractions.start)
        XCTAssertGreaterThan(wideFractions.end, narrowFractions.end)
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
        XCTAssertEqual(String(node.text[matches[0].ranges[0]]).lowercased(), "sohrab")
    }

    @MainActor
    func testCmdFHighlightModeKeepsRangesOnOriginalStringForCaseInsensitiveMatches() {
        let node = OCRNodeWithText(
            id: 1,
            frameId: 42,
            x: 0.2,
            y: 0.3,
            width: 0.4,
            height: 0.1,
            text: "hello SOHRAB there"
        )

        let matches = SimpleTimelineViewModel.searchHighlightMatches(
            in: [node],
            query: "sohrab",
            mode: .matchedTextRanges
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(String(node.text[matches[0].ranges[0]]), "SOHRAB")
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

    @MainActor
    func testCmdHHideArmsControlsRestoreGuidance() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        viewModel.toggleControlsVisibility(showRestoreHint: true)

        XCTAssertTrue(viewModel.areControlsHidden)
        XCTAssertTrue(viewModel.showControlsHiddenRestoreHintBanner)
        XCTAssertTrue(viewModel.highlightShowControlsContextMenuRow)
    }

    @MainActor
    func testNonShortcutHideDoesNotArmControlsRestoreGuidance() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        viewModel.toggleControlsVisibility()

        XCTAssertTrue(viewModel.areControlsHidden)
        XCTAssertFalse(viewModel.showControlsHiddenRestoreHintBanner)
        XCTAssertFalse(viewModel.highlightShowControlsContextMenuRow)
    }

    @MainActor
    func testShowingControlsClearsControlsRestoreGuidance() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.toggleControlsVisibility(showRestoreHint: true)

        viewModel.openSearchOverlay()

        XCTAssertFalse(viewModel.areControlsHidden)
        XCTAssertFalse(viewModel.showControlsHiddenRestoreHintBanner)
        XCTAssertFalse(viewModel.highlightShowControlsContextMenuRow)
    }

    @MainActor
    func testDismissingControlsRestoreBannerKeepsContextMenuGuidanceArmed() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.toggleControlsVisibility(showRestoreHint: true)

        viewModel.dismissControlsHiddenRestoreHint()

        XCTAssertTrue(viewModel.areControlsHidden)
        XCTAssertFalse(viewModel.showControlsHiddenRestoreHintBanner)
        XCTAssertTrue(viewModel.highlightShowControlsContextMenuRow)
    }
}
