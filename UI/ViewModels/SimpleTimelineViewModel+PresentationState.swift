import AppKit
import Shared

enum CurrentFrameMediaDisplayMode: Equatable {
    case still
    case decodedVideo
    case noContent
}

enum CurrentFrameStillDisplayMode: Equatable {
    case currentImage
    case waitingFallback
    case none
}

extension SimpleTimelineViewModel {
    func clearCurrentImagePresentation() {
        mediaPresentationState.currentImage = nil
        mediaPresentationState.currentImageFrameID = nil
    }

    func clearWaitingFallbackImage() {
        mediaPresentationState.waitingFallbackImage = nil
        mediaPresentationState.waitingFallbackImageFrameID = nil
    }

    func setWaitingFallbackImage(
        _ image: NSImage,
        frameID: FrameID
    ) {
        mediaPresentationState.waitingFallbackImage = image
        mediaPresentationState.waitingFallbackImageFrameID = frameID
    }

    func clearPendingVideoPresentationState() {
        mediaPresentationState.pendingVideoPresentationFrameID = nil
        mediaPresentationState.isPendingVideoPresentationReady = false
    }

    func preserveWaitingFallbackImage(
        from previousTimelineFrame: TimelineFrame?,
        for nextTimelineFrame: TimelineFrame?
    ) {
        guard let nextTimelineFrame, nextTimelineFrame.videoInfo != nil else {
            clearWaitingFallbackImage()
            return
        }

        guard let previousFrameID = previousTimelineFrame?.frame.id else {
            clearWaitingFallbackImage()
            return
        }

        if let currentImage, currentImageFrameID == previousFrameID {
            setWaitingFallbackImage(currentImage, frameID: previousFrameID)
            return
        }

        guard waitingFallbackImageFrameID == previousFrameID else {
            clearWaitingFallbackImage()
            return
        }
    }

    func configurePendingVideoPresentationState(for timelineFrame: TimelineFrame?) {
        guard let timelineFrame, timelineFrame.videoInfo != nil else {
            clearPendingVideoPresentationState()
            clearWaitingFallbackImage()
            return
        }

        mediaPresentationState.pendingVideoPresentationFrameID = timelineFrame.frame.id
        mediaPresentationState.isPendingVideoPresentationReady = false
    }

    func prepareCurrentFramePresentationState(
        for timelineFrame: TimelineFrame?,
        previousTimelineFrame: TimelineFrame?
    ) {
        preserveWaitingFallbackImage(from: previousTimelineFrame, for: timelineFrame)
        clearCurrentImagePresentation()
        configurePendingVideoPresentationState(for: timelineFrame)
    }

    func clearCurrentFrameOverlayPresentation() {
        setURLBoundingBox(nil)
        clearHyperlinkMatches()
        setFrameMousePosition(nil)
        clearTextSelection()
        clearTemporaryRedactionReveals()
        setOCRNodes([])
        setOCRStatus(.unknown)
    }

    func setCurrentImagePresentation(
        _ image: NSImage,
        frameID: FrameID
    ) {
        mediaPresentationState.currentImage = image
        mediaPresentationState.currentImageFrameID = frameID
        clearWaitingFallbackImage()
    }

    func applyForegroundPresentationSuccess(
        _ image: NSImage,
        frameID: FrameID
    ) {
        setCurrentImagePresentation(image, frameID: frameID)
        setFramePresentationState(isNotReady: false, hasLoadError: false)
    }

    func applyForegroundPresentationUnavailable(
        isNotReady: Bool,
        hasLoadError: Bool
    ) {
        clearCurrentImagePresentation()
        setFramePresentationState(isNotReady: isNotReady, hasLoadError: hasLoadError)
    }

    func clearFrameMousePositionPresentation() {
        setFrameMousePosition(nil)
    }

    func clearUnavailableFrameLookup() {
        foregroundPresentationWorkState.unavailableFrameLookupTask?.cancel()
        foregroundPresentationWorkState.unavailableFrameLookupTask = nil
    }

    func clearForegroundPresentationForMissingFrame() {
        clearUnavailableFrameLookup()
        clearHyperlinkMatches()
        clearFrameMousePositionPresentation()
    }

    func refreshCurrentFrameOverlayForPresentationChange(
        presentationGeneration: UInt64
    ) {
        loadFrameMousePosition(expectedGeneration: presentationGeneration)

        if !isActivelyScrolling {
            schedulePresentationOverlayRefresh(expectedGeneration: presentationGeneration)
            return
        }

        overlayRefreshWorkState.idleTask?.cancel()
        overlayRefreshWorkState.idleTask = nil
        overlayRefreshWorkState.refreshTask?.cancel()
        overlayRefreshWorkState.refreshTask = nil
        setOCRNodes([])
        setOCRStatus(.unknown)
        overlayRefreshWorkState.ocrStatusPollingTask?.cancel()
        overlayRefreshWorkState.ocrStatusPollingTask = nil
        setURLBoundingBox(nil)
        clearHyperlinkMatches()
        clearTextSelection()
    }

    func markVideoPresentationReady(frameID: FrameID) {
        guard pendingVideoPresentationFrameID == frameID else { return }
        guard currentTimelineFrame?.frame.id == frameID else { return }
        mediaPresentationState.isPendingVideoPresentationReady = true
        clearWaitingFallbackImage()
    }

    func applyNavigationFrameWindow(
        _ framesWithVideoInfo: [FrameWithVideoInfo],
        clearDiskBufferReason: String,
        memoryLogContext: String? = nil
    ) {
        let oldCacheCount = diskFrameBufferIndex.count
        clearDiskFrameBuffer(reason: clearDiskBufferReason)
        if let memoryLogContext, oldCacheCount > 0 {
            Log.info(
                "[Memory] Cleared disk frame buffer on \(memoryLogContext) (\(oldCacheCount) frames removed)",
                category: .ui
            )
        }

        let timelineFrames = framesWithVideoInfo.map { TimelineFrame(frameWithVideoInfo: $0) }
        let preparedWindow = frameWindowStore.prepareNavigationWindowReplacement(
            reason: "applyNavigationFrameWindow",
            frames: timelineFrames,
            currentIndex: max(0, min(currentIndex, max(timelineFrames.count - 1, 0)))
        )
        frames = preparedWindow.frames
    }

    public func refreshStaticPresentationIfNeeded() {
        guard presentationWorkEnabled, !isInLiveMode else { return }

        if currentVideoInfo != nil {
            let generation = currentPresentationWorkGeneration()
            guard canPublishPresentationResult(expectedGeneration: generation) else { return }
            schedulePresentationOverlayRefresh(expectedGeneration: generation)
            return
        }

        guard currentImage == nil else { return }
        refreshCurrentFramePresentation()
    }

    @discardableResult
    func prepareHistoricalOpenStillFallbackIfNeeded() async -> Bool {
        guard presentationWorkEnabled, !isInLiveMode else { return false }
        guard let timelineFrame = currentTimelineFrame,
              timelineFrame.videoInfo != nil else {
            return false
        }
        guard currentImage == nil else { return false }

        let frameID = timelineFrame.frame.id
        let generation = currentPresentationWorkGeneration()
        guard canPublishPresentationResult(frameID: frameID, expectedGeneration: generation) else {
            return false
        }

        if pendingVideoPresentationFrameID == frameID, isPendingVideoPresentationReady {
            return false
        }

        if pendingVideoPresentationFrameID != frameID {
            clearWaitingFallbackImage()
            mediaPresentationState.pendingVideoPresentationFrameID = frameID
            mediaPresentationState.isPendingVideoPresentationReady = false
        }

        if waitingFallbackImage != nil, waitingFallbackImageFrameID == frameID {
            return true
        }

        if waitingFallbackImage != nil {
            clearWaitingFallbackImage()
        }

        guard let bufferedData = await readFrameDataFromDiskFrameBuffer(frameID: frameID) else {
            return false
        }

        do {
            let image = try decodeBufferedFrameImage(
                bufferedData,
                frameID: frameID,
                errorCode: -5
            )

            guard canPublishPresentationResult(frameID: frameID, expectedGeneration: generation) else {
                return false
            }
            guard pendingVideoPresentationFrameID == frameID, !isPendingVideoPresentationReady else {
                return false
            }

            setWaitingFallbackImage(image, frameID: frameID)
            setFramePresentationState(isNotReady: false, hasLoadError: false)
            return true
        } catch {
            Log.warning(
                "[Timeline-Reopen] Failed to decode disk-buffer still for frame \(frameID.value): \(error)",
                category: .ui
            )
            return false
        }
    }

    public func compactPresentationState(
        reason: String,
        purgeDiskFrameBuffer: Bool = true
    ) {
        setPresentationWorkEnabled(false, reason: "compactPresentationState.\(reason)")
        cancelDragStartStillFrameOCR(reason: "compactPresentationState.\(reason)")
        stopPeriodicStatusRefresh()
        stopPlayback()
        cancelDiskFrameBufferInactivityCleanup()
        cancelForegroundFrameLoad(reason: "compactPresentationState.\(reason)")
        cancelCacheExpansion(reason: "compactPresentationState.\(reason)")
        cancelPendingDirectDecodeGenerators(reason: "compactPresentationState.\(reason)")

        setLivePresentationState(isActive: false, screenshot: nil)
        clearCurrentImagePresentation()
        clearWaitingFallbackImage()
        clearPendingVideoPresentationState()
        shiftDragDisplaySnapshot = nil
        shiftDragDisplaySnapshotFrameID = nil
        shiftDragDisplayRequestID &+= 1
        activeShiftDragSessionID = 0
        shiftDragStartFrameID = nil
        shiftDragStartVideoInfo = nil
        setFramePresentationState(isNotReady: false, hasLoadError: false)
        forceVideoReload = false
        setURLBoundingBox(nil)
        isHoveringURL = false
        clearHyperlinkMatches()
        clearTextSelection()
        setOCRNodes([])
        previousOcrNodes = []
        setOCRStatus(.unknown)
        overlayRefreshWorkState.ocrStatusPollingTask?.cancel()
        overlayRefreshWorkState.ocrStatusPollingTask = nil
        clearPositionRecoveryHint(animated: false)

        if purgeDiskFrameBuffer {
            clearDiskFrameBuffer(reason: "compactPresentationState.\(reason)")
        } else {
            scheduleDiskFrameBufferInactivityCleanup()
        }
    }
}
