import AppKit
import Foundation
import Shared

extension SimpleTimelineViewModel {
    public func refreshProcessingStatuses() async {
        let framesToRefresh = Array(frames.enumerated())

        guard !framesToRefresh.isEmpty else {
            return
        }

        let frameIDs = framesToRefresh.map { $0.element.frame.id.value }

        do {
            let updatedStatuses = try await fetchFrameProcessingStatusesForRefresh(frameIDs: frameIDs)

            var updatedCount = 0
            var currentFrameUpdated = false

            for (_, snapshotFrame) in framesToRefresh {
                let frameID = snapshotFrame.frame.id
                guard let newStatus = updatedStatuses[frameID.value] else {
                    continue
                }

                guard let liveIndex = frames.firstIndex(where: { $0.frame.id == frameID }) else {
                    continue
                }

                guard frames[liveIndex].processingStatus != newStatus else {
                    continue
                }

                if let updatedFrame = try await fetchFrameWithVideoInfoByIDForRefresh(id: frameID) {
                    guard let liveIndexAfterAwait = frames.firstIndex(where: { $0.frame.id == frameID }) else {
                        continue
                    }

                    frames[liveIndexAfterAwait] = TimelineFrame(frameWithVideoInfo: updatedFrame)
                } else {
                    guard let liveIndexAfterAwait = frames.firstIndex(where: { $0.frame.id == frameID }) else {
                        continue
                    }

                    let existingFrame = frames[liveIndexAfterAwait]
                    frames[liveIndexAfterAwait] = TimelineFrame(
                        frame: existingFrame.frame,
                        videoInfo: existingFrame.videoInfo,
                        processingStatus: newStatus,
                        videoCurrentTime: existingFrame.videoCurrentTime,
                        scrollY: existingFrame.scrollY
                    )
                }

                if let currentFrame = currentTimelineFrame,
                   currentFrame.frame.id.value == frameID.value {
                    currentFrameUpdated = true
                }

                updatedCount += 1
            }

            if updatedCount > 0, currentFrameUpdated {
                refreshCurrentFramePresentation()
            }
        } catch {
            Log.error("[TIMELINE-REFRESH] Failed to refresh processing statuses: \(error)", category: .ui)
        }
    }

    private func fetchFrameProcessingStatusesForRefresh(frameIDs: [Int64]) async throws -> [Int64: Int] {
#if DEBUG
        if let override = test_refreshProcessingStatusesHooks.getFrameProcessingStatuses {
            return try await override(frameIDs)
        }
#endif
        return try await coordinator.getFrameProcessingStatuses(frameIDs: frameIDs)
    }

    private func fetchFrameWithVideoInfoByIDForRefresh(id: FrameID) async throws -> FrameWithVideoInfo? {
#if DEBUG
        if let override = test_refreshProcessingStatusesHooks.getFrameWithVideoInfoByID {
            return try await override(id)
        }
#endif
        return try await coordinator.getFrameWithVideoInfoByID(id: id)
    }

    public func startPeriodicStatusRefresh() {
        stopPeriodicStatusRefresh()

        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshProcessingStatuses()
            }
        }
    }

    public func stopPeriodicStatusRefresh() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
    }

    func exitLiveMode() {
        guard isInLiveMode else { return }

        Log.info("[TIMELINE-LIVE] Exiting live mode, transitioning to historical frames", category: .ui)
        setLivePresentationState(isActive: false, screenshot: nil)
        isLiveOCRProcessing = false
        liveOCRDebounceTask?.cancel()
        liveOCRDebounceTask = nil
        isTapeHidden = false

        if !frames.isEmpty {
            currentIndex = frames.count - 1
            refreshCurrentFramePresentation()
        }
    }

    private func unavailableFrameFallbackCandidates(
        excluding frameID: FrameID,
        around index: Int
    ) -> [UnavailableFrameFallbackCandidate] {
        guard !frames.isEmpty else { return [] }
        guard index >= 0 && index < frames.count else { return [] }

        let lowerBound = max(0, index - Self.unavailableFrameFallbackSearchRadius)
        let upperBound = min(frames.count - 1, index + Self.unavailableFrameFallbackSearchRadius)
        var candidates: [UnavailableFrameFallbackCandidate] = []

        if index > lowerBound {
            for candidateIndex in stride(from: index - 1, through: lowerBound, by: -1) {
                let candidateFrame = frames[candidateIndex]
                guard candidateFrame.processingStatus == 4 else { continue }
                let candidateFrameID = candidateFrame.frame.id
                guard candidateFrameID != frameID else { continue }
                candidates.append(
                    UnavailableFrameFallbackCandidate(
                        frameID: candidateFrameID,
                        index: candidateIndex
                    )
                )
            }
        }

        if index < upperBound {
            for candidateIndex in (index + 1)...upperBound {
                let candidateFrame = frames[candidateIndex]
                guard candidateFrame.processingStatus == 4 else { continue }
                let candidateFrameID = candidateFrame.frame.id
                guard candidateFrameID != frameID else { continue }
                candidates.append(
                    UnavailableFrameFallbackCandidate(
                        frameID: candidateFrameID,
                        index: candidateIndex
                    )
                )
            }
        }

        return candidates
    }

    private func resolveUnavailableFrameNeighborFallback(
        currentFrameID: FrameID,
        lookupIndex: Int,
        expectedGeneration: UInt64
    ) async -> (image: NSImage, sourceFrameID: FrameID, sourceIndex: Int)? {
        let candidates = unavailableFrameFallbackCandidates(
            excluding: currentFrameID,
            around: lookupIndex
        )

        for candidate in candidates {
            guard canPublishPresentationResult(
                frameID: currentFrameID,
                expectedGeneration: expectedGeneration
            ) else {
                return nil
            }

            guard let bufferedData = await readFrameDataFromDiskFrameBuffer(frameID: candidate.frameID) else {
                continue
            }

            guard let image = NSImage(data: bufferedData) else {
                diskFrameBufferTelemetry.decodeFailures += 1
                removeDiskFrameBufferEntries(
                    [candidate.frameID],
                    reason: "unavailable-frame fallback decode failure",
                    removeExternalFiles: true
                )
                continue
            }

            diskFrameBufferTelemetry.decodeSuccesses += 1
            return (image: image, sourceFrameID: candidate.frameID, sourceIndex: candidate.index)
        }

        return nil
    }

    private func loadUnavailableFrameLookupResult(
        frameID: FrameID,
        lookupIndex: Int,
        expectedGeneration: UInt64
    ) async -> UnavailableFrameLookupResult {
        guard let bufferedData = await readFrameDataFromDiskFrameBuffer(frameID: frameID) else {
            if let fallback = await resolveUnavailableFrameNeighborFallback(
                currentFrameID: frameID,
                lookupIndex: lookupIndex,
                expectedGeneration: expectedGeneration
            ) {
                return .fallbackImage(
                    image: fallback.image,
                    sourceFrameID: fallback.sourceFrameID,
                    sourceIndex: fallback.sourceIndex
                )
            }
            return .miss
        }

        guard let image = NSImage(data: bufferedData) else {
            diskFrameBufferTelemetry.decodeFailures += 1
            removeDiskFrameBufferEntries(
                [frameID],
                reason: "unavailable-frame decode failure",
                removeExternalFiles: true
            )
            if Self.isTimelineStillLoggingEnabled {
                Log.warning(
                    "[Timeline-Still] DECODE-FAIL frameID=\(frameID.value) index=\(lookupIndex) bytes=\(bufferedData.count)",
                    category: .ui
                )
            }
            return .miss
        }

        diskFrameBufferTelemetry.decodeSuccesses += 1
        return .exactImage(image)
    }

    func scheduleUnavailableFrameDiskLookup(
        frameID: FrameID,
        expectedGeneration: UInt64
    ) {
        foregroundPresentationWorkState.unavailableFrameLookupTask?.cancel()
        foregroundPresentationWorkState.unavailableFrameLookupTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }

            guard self.canPublishPresentationResult(
                frameID: frameID,
                expectedGeneration: expectedGeneration
            ) else {
                return
            }
            let lookupIndex = self.currentIndex
            let lookupStatus = self.currentTimelineFrame?.processingStatus ?? -1

            switch await self.loadUnavailableFrameLookupResult(
                frameID: frameID,
                lookupIndex: lookupIndex,
                expectedGeneration: expectedGeneration
            ) {
            case .miss:
                if Self.isTimelineStillLoggingEnabled {
                    let fileURL = self.diskFrameBufferURL(for: frameID)
                    Log.info(
                        "[Timeline-Still] MISS frameID=\(frameID.value) index=\(lookupIndex) processingStatus=\(lookupStatus) path=\(fileURL.lastPathComponent) placeholder=true",
                        category: .ui
                    )
                }
                return

            case .fallbackImage(let image, let sourceFrameID, let sourceIndex):
                guard self.canPublishPresentationResult(
                    frameID: frameID,
                    expectedGeneration: expectedGeneration
                ) else {
                    return
                }
                self.setWaitingFallbackImage(image, frameID: sourceFrameID)
                if Self.isTimelineStillLoggingEnabled {
                    let direction = sourceIndex < lookupIndex ? "older" : "newer"
                    Log.info(
                        "[Timeline-Still] FALLBACK-HIT frameID=\(frameID.value) index=\(lookupIndex) processingStatus=\(lookupStatus) fallbackFrameID=\(sourceFrameID.value) fallbackIndex=\(sourceIndex) direction=\(direction)",
                        category: .ui
                    )
                }
                return

            case .exactImage(let image):
                if Self.isTimelineStillLoggingEnabled {
                    Log.info(
                        "[Timeline-Still] HIT frameID=\(frameID.value) index=\(lookupIndex) processingStatus=\(lookupStatus)",
                        category: .ui
                    )
                }

                guard self.canPublishPresentationResult(
                    frameID: frameID,
                    expectedGeneration: expectedGeneration
                ) else {
                    return
                }

                self.setCurrentImagePresentation(image, frameID: frameID)
                self.setFramePresentationState(isNotReady: false, hasLoadError: false)
            }
        }
    }

    func enqueueForegroundFrameLoad(
        _ timelineFrame: TimelineFrame,
        presentationGeneration: UInt64
    ) {
        if foregroundPresentationWorkState.pendingRequest != nil {
            diskFrameBufferTelemetry.foregroundLoadCancels += 1
        }
        foregroundPresentationWorkState.pendingRequest = ForegroundPresentationRequest(
            timelineFrame: timelineFrame,
            presentationGeneration: presentationGeneration
        )

        guard foregroundPresentationWorkState.loadTask == nil else { return }

        foregroundPresentationWorkState.loadTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runForegroundFrameLoadLoop()
        }
    }

    func runForegroundFrameLoadLoop() async {
        while !Task.isCancelled {
            guard let request = foregroundPresentationWorkState.pendingRequest else { break }
            foregroundPresentationWorkState.pendingRequest = nil
            foregroundPresentationWorkState.activeFrameID = request.timelineFrame.frame.id
            await executeForegroundPresentationRequest(request)
            foregroundPresentationWorkState.activeFrameID = nil
        }

        foregroundPresentationWorkState.loadTask = nil
    }

    private func loadFrameData(_ timelineFrame: TimelineFrame) async throws -> Data {
#if DEBUG
        if let override = test_foregroundFrameLoadHooks.loadFrameData {
            return try await override(timelineFrame)
        }
#endif

        let frame = timelineFrame.frame
        if let videoInfo = timelineFrame.videoInfo {
            return try await coordinator.getFrameImageFromPath(
                videoPath: videoInfo.videoPath,
                frameIndex: videoInfo.frameIndex
            )
        }

        return try await coordinator.getFrameImage(
            segmentID: frame.videoID,
            timestamp: frame.timestamp
        )
    }

#if DEBUG
    func test_loadForegroundPresentationImage(_ timelineFrame: TimelineFrame) async throws -> NSImage {
        let result = try await fetchForegroundPresentationLoadResult(timelineFrame)
        return result.image
    }
#endif

    func hasExternalCaptureStillInDiskFrameBuffer(frameID: FrameID) -> Bool {
        if let entry = diskFrameBufferIndex[frameID] {
            return entry.origin == .externalCapture
        }

        let fileURL = diskFrameBufferURL(for: frameID)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func isSuccessfulProcessingStatus(_ status: Int) -> Bool {
        status == 2 || status == 7
    }

    static func phraseLevelRedactionTooltipState(
        for processingStatus: Int,
        isRevealed: Bool
    ) -> PhraseLevelRedactionTooltipState? {
        switch processingStatus {
        case 5, 6:
            return .queued
        case 2, 7:
            return isRevealed ? .hide : .reveal
        default:
            return nil
        }
    }

    static func phraseLevelRedactionOutlineState(
        for processingStatus: Int,
        isTooltipActive: Bool
    ) -> PhraseLevelRedactionOutlineState {
        if isTooltipActive {
            return .active
        }

        switch processingStatus {
        case 5, 6:
            return .queued
        default:
            return .hidden
        }
    }

    func decodeBufferedFrameImage(_ data: Data, frameID: FrameID, errorCode: Int) throws -> NSImage {
        guard let image = NSImage(data: data) else {
            diskFrameBufferTelemetry.decodeFailures += 1
            removeDiskFrameBufferEntries(
                [frameID],
                reason: "decode failure",
                removeExternalFiles: true
            )
            throw NSError(
                domain: "SimpleTimelineViewModel",
                code: errorCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode buffered frame image"]
            )
        }

        diskFrameBufferTelemetry.decodeSuccesses += 1
        return image
    }

    func fetchForegroundPresentationLoadResult(_ timelineFrame: TimelineFrame) async throws -> ForegroundPresentationLoadResult {
        let frameID = timelineFrame.frame.id
        let lookupIndex = currentIndex
        let shouldPreferDecodedReadyFrame =
            Self.isSuccessfulProcessingStatus(timelineFrame.processingStatus)
            && hasExternalCaptureStillInDiskFrameBuffer(frameID: frameID)

        if shouldPreferDecodedReadyFrame, Self.isTimelineStillLoggingEnabled {
            Log.info(
                "[Timeline-Still] READY-DECODE-FIRST frameID=\(frameID.value) index=\(lookupIndex) processingStatus=\(timelineFrame.processingStatus)",
                category: .ui
            )
        }

        if !shouldPreferDecodedReadyFrame {
            if let bufferedData = await readFrameDataFromDiskFrameBuffer(frameID: frameID) {
                diskFrameBufferTelemetry.diskHits += 1
                let image = try decodeBufferedFrameImage(bufferedData, frameID: frameID, errorCode: -2)
                return ForegroundPresentationLoadResult(image: image, loadedFromDiskBuffer: true)
            }
        }

        diskFrameBufferTelemetry.diskMisses += 1
        diskFrameBufferTelemetry.storageReads += 1

        do {
            let imageData = try await loadFrameData(timelineFrame)
            await storeFrameDataInDiskFrameBuffer(frameID: frameID, data: imageData)
            let image = try decodeBufferedFrameImage(imageData, frameID: frameID, errorCode: -3)
            return ForegroundPresentationLoadResult(image: image, loadedFromDiskBuffer: false)
        } catch {
            guard shouldPreferDecodedReadyFrame else {
                throw error
            }

            if Self.isTimelineStillLoggingEnabled {
                Log.warning(
                    "[Timeline-Still] READY-DECODE-FAILED frameID=\(frameID.value) index=\(lookupIndex) processingStatus=\(timelineFrame.processingStatus) reason=\(error.localizedDescription) fallback=external-still",
                    category: .ui
                )
            }

            if let bufferedData = await readFrameDataFromDiskFrameBuffer(frameID: frameID) {
                diskFrameBufferTelemetry.diskHits += 1
                let image = try decodeBufferedFrameImage(bufferedData, frameID: frameID, errorCode: -4)
                if Self.isTimelineStillLoggingEnabled {
                    Log.info(
                        "[Timeline-Still] READY-FALLBACK-HIT frameID=\(frameID.value) index=\(lookupIndex) processingStatus=\(timelineFrame.processingStatus)",
                        category: .ui
                    )
                }
                return ForegroundPresentationLoadResult(image: image, loadedFromDiskBuffer: true)
            }

            if Self.isTimelineStillLoggingEnabled {
                Log.warning(
                    "[Timeline-Still] READY-FALLBACK-MISS frameID=\(frameID.value) index=\(lookupIndex) processingStatus=\(timelineFrame.processingStatus)",
                    category: .ui
                )
            }
            throw error
        }
    }

    func executeForegroundPresentationRequest(
        _ request: ForegroundPresentationRequest
    ) async {
        let timelineFrame = request.timelineFrame
        let expectedGeneration = request.presentationGeneration
        let frame = timelineFrame.frame
        guard canPublishPresentationResult(frameID: frame.id, expectedGeneration: expectedGeneration) else { return }
        let shouldEmitInteractiveSlowSampleAlerts = TimelineWindowController.shared.isVisible

        do {
            let loadStart = CFAbsoluteTimeGetCurrent()
            let imageLoadStart = CFAbsoluteTimeGetCurrent()
            let loadResult = try await fetchForegroundPresentationLoadResult(timelineFrame)
            let imageLoadMs = (CFAbsoluteTimeGetCurrent() - imageLoadStart) * 1000
            let image = loadResult.image
            let loadedFromDiskBuffer = loadResult.loadedFromDiskBuffer
            Log.recordLatency(
                loadedFromDiskBuffer ? "timeline.disk_buffer.read_ms" : "timeline.frame.storage_read_ms",
                valueMs: imageLoadMs,
                category: .ui,
                summaryEvery: 25,
                warningThresholdMs: loadedFromDiskBuffer ? 25 : (shouldEmitInteractiveSlowSampleAlerts ? 45 : nil),
                criticalThresholdMs: loadedFromDiskBuffer ? 80 : (shouldEmitInteractiveSlowSampleAlerts ? 150 : nil)
            )

            try Task.checkCancellation()
            guard canPublishPresentationResult(frameID: frame.id, expectedGeneration: expectedGeneration) else { return }

            let totalMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            Log.recordLatency(
                "timeline.frame.present_ms",
                valueMs: totalMs,
                category: .ui,
                summaryEvery: 20,
                warningThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? 80 : nil,
                criticalThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? 220 : nil
            )
            Log.recordLatency(
                loadedFromDiskBuffer ? "timeline.frame.present.disk_ms" : "timeline.frame.present.storage_ms",
                valueMs: totalMs,
                category: .ui,
                summaryEvery: 20,
                warningThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? (loadedFromDiskBuffer ? 45 : 100) : nil,
                criticalThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? (loadedFromDiskBuffer ? 120 : 260) : nil
            )

            if canPublishPresentationResult(frameID: frame.id, expectedGeneration: expectedGeneration) {
                applyForegroundPresentationSuccess(image, frameID: frame.id)
                if Self.isVerboseTimelineLoggingEnabled {
                    Log.debug(
                        "[TIMELINE-LOAD] Successfully loaded image for frame \(frame.id.value) source=\(loadedFromDiskBuffer ? "disk-buffer" : "storage-read")",
                        category: .ui
                    )
                }
            }
        } catch is CancellationError {
        } catch {
            diskFrameBufferTelemetry.storageReadFailures += 1
            let outcome = foregroundPresentationFailureOutcome(for: error, timelineFrame: timelineFrame)
            if let logMessage = outcome.logMessage {
                Log.info(logMessage, category: .app)
            } else {
                Log.error("[SimpleTimelineViewModel] Failed to load image: \(error)", category: .app)
            }
            if canPublishPresentationResult(frameID: frame.id, expectedGeneration: expectedGeneration) {
                applyForegroundPresentationUnavailable(
                    isNotReady: outcome.isNotReady,
                    hasLoadError: outcome.hasLoadError
                )
            }
        }
    }
}
