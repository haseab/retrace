import App
import AppKit
import Foundation
import Shared
import SwiftUI

extension SimpleTimelineViewModel {
    /// Refresh still/video presentation for the current frame.
    func refreshCurrentFramePresentation() {
        // Skip during live mode - live screenshot is already displayed and OCR is handled separately
        guard !isInLiveMode else {
            applyCurrentFramePresentationAction(.clearForLiveMode)
            return
        }
        guard presentationWorkEnabled else { return }
        cancelDiskFrameBufferInactivityCleanup()

        guard let timelineFrame = currentTimelineFrame else {
            applyCurrentFramePresentationAction(.clearForMissingFrame)
            return
        }

        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug(
                "[TIMELINE-LOAD] refreshCurrentFramePresentation() START for frame \(timelineFrame.frame.id.value), currentFrameNotReady=\(frameNotReady), processingStatus=\(timelineFrame.processingStatus)",
                category: .ui
            )
        }

        let presentationGeneration = currentPresentationWorkGeneration()
        refreshCurrentFrameOverlayForPresentationChange(
            presentationGeneration: presentationGeneration
        )
        let action = plannedCurrentFramePresentationAction(
            for: timelineFrame,
            presentationGeneration: presentationGeneration
        )
        applyCurrentFramePresentationAction(action)
    }

    func clearOverlayPresentationForMissingFrame() {
        overlayRefreshWorkState.refreshTask?.cancel()
        overlayRefreshWorkState.refreshTask = nil
        overlayRefreshWorkState.ocrStatusPollingTask?.cancel()
        overlayRefreshWorkState.ocrStatusPollingTask = nil
        setURLBoundingBox(nil)
        clearHyperlinkMatches()
        clearTextSelection()
        clearTemporaryRedactionReveals()
        setOCRNodes([])
        setOCRStatus(.unknown)
        clearFrameMousePositionPresentation()
        isHoveringURL = false
    }

    private func plannedCurrentFramePresentationAction(
        for timelineFrame: TimelineFrame,
        presentationGeneration: UInt64
    ) -> CurrentFramePresentationAction {
        let frame = timelineFrame.frame

        if timelineFrame.processingStatus == 4 {
            if Self.isVerboseTimelineLoggingEnabled {
                Log.info(
                    "[TIMELINE-LOAD] Frame \(frame.id.value) has processingStatus=4 (NOT_YET_READABLE), setting frameNotReady=true",
                    category: .ui
                )
            }
            if Self.isTimelineStillLoggingEnabled {
                Log.info(
                    "[Timeline-Still] p4 frameID=\(frame.id.value) index=\(currentIndex) processingStatus=\(timelineFrame.processingStatus) scheduling disk lookup",
                    category: .ui
                )
            }
            return .showUnavailablePlaceholder(
                frameID: frame.id,
                generation: presentationGeneration
            )
        }

        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug(
                "[TIMELINE-LOAD] Frame \(frame.id.value) has processingStatus=\(timelineFrame.processingStatus) (!= 4), setting frameNotReady=false",
                category: .ui
            )
        }

        guard foregroundPresentationWorkState.activeFrameID != frame.id,
              foregroundPresentationWorkState.pendingRequest?.timelineFrame.frame.id != frame.id else {
            return .skipDuplicateForegroundLoad(frameID: frame.id)
        }

        return .enqueueForegroundLoad(
            timelineFrame,
            generation: presentationGeneration
        )
    }

    private func applyCurrentFramePresentationAction(_ action: CurrentFramePresentationAction) {
        switch action {
        case .clearForLiveMode:
            cancelPresentationOverlayTasks()
            clearUnavailableFrameLookup()
            clearHyperlinkMatches()
            clearFrameMousePositionPresentation()

        case .clearForMissingFrame:
            if Self.isVerboseTimelineLoggingEnabled {
                Log.debug("[TIMELINE-LOAD] refreshCurrentFramePresentation() called but currentTimelineFrame is nil", category: .ui)
            }
            clearForegroundPresentationForMissingFrame()
            clearOverlayPresentationForMissingFrame()

        case .showUnavailablePlaceholder(let frameID, let generation):
            clearCurrentImagePresentation()
            setFramePresentationState(isNotReady: true, hasLoadError: false)
            scheduleUnavailableFrameDiskLookup(
                frameID: frameID,
                expectedGeneration: generation
            )
            ensureDiskHotWindowCoverage(reason: "frame-not-yet-readable")

        case .enqueueForegroundLoad(let timelineFrame, let generation):
            clearUnavailableFrameLookup()
            setFramePresentationState(isNotReady: false, hasLoadError: false)
            diskFrameBufferTelemetry.frameRequests += 1
            enqueueForegroundFrameLoad(
                timelineFrame,
                presentationGeneration: generation
            )
            ensureDiskHotWindowCoverage(reason: "foreground request")

        case .skipDuplicateForegroundLoad(let frameID):
            setFramePresentationState(isNotReady: false, hasLoadError: false)
            if Self.isVerboseTimelineLoggingEnabled {
                Log.debug(
                    "[TIMELINE-LOAD] Frame \(frameID.value) foreground load already in-flight/pending; skipping duplicate request",
                    category: .ui
                )
            }
            ensureDiskHotWindowCoverage(reason: "duplicate foreground request")
        }
    }

    func foregroundPresentationFailureOutcome(
        for error: Error,
        timelineFrame: TimelineFrame
    ) -> ForegroundPresentationFailureOutcome {
        if case StorageError.fileReadFailed(_, let underlying) = error,
           underlying.contains("still being written") {
            return ForegroundPresentationFailureOutcome(
                isNotReady: !Self.isSuccessfulProcessingStatus(timelineFrame.processingStatus),
                hasLoadError: false,
                logMessage: Self.isVerboseTimelineLoggingEnabled
                    ? "[TIMELINE-LOAD] Frame \(timelineFrame.frame.id.value) video still being written (processingStatus=\(timelineFrame.processingStatus))"
                    : nil
            )
        }

        if case StorageError.fileReadFailed(_, let underlying) = error,
           underlying.contains("out of range") {
            let isSuccessful = Self.isSuccessfulProcessingStatus(timelineFrame.processingStatus)
            return ForegroundPresentationFailureOutcome(
                isNotReady: !isSuccessful,
                hasLoadError: isSuccessful,
                logMessage: Self.isVerboseTimelineLoggingEnabled
                    ? "[TIMELINE-LOAD] Frame \(timelineFrame.frame.id.value) not yet in video file (still encoding, processingStatus=\(timelineFrame.processingStatus))"
                    : nil
            )
        }

        let nsError = error as NSError
        if nsError.domain == "AVFoundationErrorDomain", nsError.code == -11829 {
            return ForegroundPresentationFailureOutcome(
                isNotReady: !Self.isSuccessfulProcessingStatus(timelineFrame.processingStatus),
                hasLoadError: false,
                logMessage: Self.isVerboseTimelineLoggingEnabled
                    ? "[TIMELINE-LOAD] Frame \(timelineFrame.frame.id.value) video not ready yet (no fragments, processingStatus=\(timelineFrame.processingStatus))"
                    : nil
            )
        }

        return ForegroundPresentationFailureOutcome(
            isNotReady: false,
            hasLoadError: timelineFrame.videoInfo == nil,
            logMessage: nil
        )
    }

    func executePresentationOverlayRefresh(
        _ request: OverlayPresentationRequest
    ) async {
        guard canPublishPresentationResult(
            frameID: request.frame.id,
            expectedGeneration: request.generation
        ) else { return }

        let result = await fetchPresentationOverlayRefreshResult(
            for: request.frame,
            expectedGeneration: request.generation
        )

        guard canPublishPresentationResult(
            frameID: request.frame.id,
            expectedGeneration: request.generation
        ) else { return }

        setURLBoundingBox(result.urlBoundingBox)
        setOCRStatus(result.ocrStatus)
        setOCRNodes(result.nodes)
        endInPageURLHoverTracking()
        setHyperlinkMatches(result.hyperlinkMatches)

        overlayRefreshWorkState.ocrStatusPollingTask?.cancel()
        overlayRefreshWorkState.ocrStatusPollingTask = nil
        if result.ocrStatus.isInProgress {
            startOCRStatusPolling(
                for: request.frame.id,
                expectedGeneration: request.generation
            )
        }
    }

    private func fetchPresentationOverlayRefreshResult(
        for frame: FrameReference,
        expectedGeneration: UInt64
    ) async -> OverlayPresentationFetchResult {
        async let urlBoundingBoxTask = fetchPresentationURLBoundingBox(
            for: frame,
            expectedGeneration: expectedGeneration
        )
        async let ocrTask = fetchPresentationOCRContent(
            for: frame,
            expectedGeneration: expectedGeneration
        )

        let (urlBoundingBox, ocrResult) = await (urlBoundingBoxTask, ocrTask)
        let hyperlinkMatches = await fetchPresentationHyperlinkMatches(
            for: frame,
            nodes: ocrResult.nodes,
            expectedGeneration: expectedGeneration
        )

        return OverlayPresentationFetchResult(
            urlBoundingBox: urlBoundingBox,
            ocrStatus: ocrResult.status,
            nodes: ocrResult.nodes,
            hyperlinkMatches: hyperlinkMatches
        )
    }

    private func fetchPresentationURLBoundingBox(
        for frame: FrameReference,
        expectedGeneration: UInt64
    ) async -> URLBoundingBox? {
        guard canPublishPresentationResult(
            frameID: frame.id,
            expectedGeneration: expectedGeneration
        ) else { return nil }

        do {
            return try await fetchURLBoundingBoxForPresentation(
                timestamp: frame.timestamp,
                source: frame.source
            )
        } catch is CancellationError {
            return nil
        } catch {
            Log.error("[SimpleTimelineViewModel] Failed to load URL bounding box: \(error)", category: .app)
            return nil
        }
    }

    private func fetchPresentationOCRContent(
        for frame: FrameReference,
        expectedGeneration: UInt64
    ) async -> OverlayPresentationOCRFetchResult {
        guard canPublishPresentationResult(
            frameID: frame.id,
            expectedGeneration: expectedGeneration
        ) else {
            return OverlayPresentationOCRFetchResult(status: .unknown, nodes: [])
        }

        do {
            async let statusTask = fetchOCRStatusForPresentation(frameID: frame.id)
            async let nodesTask = fetchAllOCRNodesForPresentation(
                frameID: frame.id,
                source: frame.source
            )

            let (status, nodes) = try await (statusTask, nodesTask)
            return OverlayPresentationOCRFetchResult(
                status: status,
                nodes: Self.filteredPresentationOCRNodes(nodes)
            )
        } catch is CancellationError {
            return OverlayPresentationOCRFetchResult(status: .unknown, nodes: [])
        } catch {
            Log.error("[SimpleTimelineViewModel] Failed to load OCR nodes: \(error)", category: .app)
            return OverlayPresentationOCRFetchResult(status: .unknown, nodes: [])
        }
    }
}
