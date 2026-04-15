import Foundation
import Shared

extension SimpleTimelineViewModel {
    private func oneMillisecondAfter(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int64(date.timeIntervalSince1970 * 1000) + 1) / 1000.0)
    }

    private func oneMillisecondBefore(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int64(date.timeIntervalSince1970 * 1000) - 1) / 1000.0)
    }

    @discardableResult
    func checkAndLoadMoreFrames(
        reason: String = "unspecified",
        cmdFTrace: CmdFQuickFilterLatencyTrace? = nil
    ) -> BoundaryLoadTrigger {
        frameWindowStore.checkAndScheduleBoundaryLoads(
            currentIndex: currentIndex,
            frameCount: frames.count,
            loadThreshold: WindowConfig.loadThreshold,
            reason: reason,
            isActivelyScrolling: isActivelyScrolling,
            subFrameOffset: subFrameOffset,
            cmdFTraceID: cmdFTrace?.id,
            olderTask: Task { [weak self] in
                guard let self else { return }
                await self.loadOlderFrames(reason: reason, cmdFTrace: cmdFTrace)
            },
            newerTask: Task { [weak self] in
                guard let self else { return }
                await self.loadNewerFrames(reason: reason, cmdFTrace: cmdFTrace)
            }
        )
    }

    func loadOlderFrames(
        reason: String = "unspecified",
        cmdFTrace: CmdFQuickFilterLatencyTrace? = nil
    ) async {
        beginCriticalTimelineFetch()
        defer { endCriticalTimelineFetch() }

        guard let appliedLoad = await frameWindowStore.loadOlderBoundary(
            reason: reason,
            filters: filterCriteria,
            frames: frames,
            currentIndex: currentIndex,
            maxFrames: WindowConfig.maxFrames,
            loadWindowSpanSeconds: WindowConfig.loadWindowSpanSeconds,
            loadBatchSize: WindowConfig.loadBatchSize,
            olderSparseRetryThreshold: WindowConfig.olderSparseRetryThreshold,
            nearestFallbackBatchSize: WindowConfig.nearestFallbackBatchSize,
            summarizeFilters: summarizeFiltersForLog,
            currentFilters: { self.filterCriteria },
            currentFrames: { self.frames },
            fetchFramesBefore: fetchFramesWithVideoInfoBeforeLogged,
            frameBufferCount: diskFrameBufferIndex.count,
            cmdFTraceID: cmdFTrace?.id,
            cmdFTraceStartedAt: cmdFTrace?.startedAt,
            memoryLogger: { context, frameCount, frameBufferCount, oldestTimestamp, newestTimestamp in
                MemoryTracker.logMemoryState(
                    context: context,
                    frameCount: frameCount,
                    frameBufferCount: frameBufferCount,
                    oldestTimestamp: oldestTimestamp,
                    newestTimestamp: newestTimestamp
                )
            }
        ) else { return }

        appliedLoad.apply(to: &frames, subFrameOffset: &subFrameOffset)
        logCmdFPlayheadState(
            appliedLoad.cmdFPlayheadEvent,
            trace: cmdFTrace,
            extra: appliedLoad.cmdFPlayheadExtra
        )
    }

    func loadNewerFrames(
        reason: String = "unspecified",
        cmdFTrace: CmdFQuickFilterLatencyTrace? = nil
    ) async {
        beginCriticalTimelineFetch()
        defer { endCriticalTimelineFetch() }

        guard let appliedLoad = await frameWindowStore.loadNewerBoundary(
            reason: reason,
            filters: filterCriteria,
            frames: frames,
            currentIndex: currentIndex,
            shouldTrackNewestWhenAtEdge: shouldPinToNewestAfterBoundaryAppend(reason: reason),
            isActivelyScrolling: isActivelyScrolling,
            currentSubFrameOffset: subFrameOffset,
            maxFrames: WindowConfig.maxFrames,
            currentFrame: currentTimelineFrame,
            loadWindowSpanSeconds: WindowConfig.loadWindowSpanSeconds,
            loadBatchSize: WindowConfig.loadBatchSize,
            newerSparseRetryThreshold: WindowConfig.newerSparseRetryThreshold,
            nearestFallbackBatchSize: WindowConfig.nearestFallbackBatchSize,
            summarizeFilters: summarizeFiltersForLog,
            currentFilters: { self.filterCriteria },
            currentFrames: { self.frames },
            fetchFramesInRange: fetchFramesWithVideoInfoLogged,
            fetchFramesAfter: fetchFramesWithVideoInfoAfterLogged,
            frameBufferCount: diskFrameBufferIndex.count,
            cmdFTraceID: cmdFTrace?.id,
            cmdFTraceStartedAt: cmdFTrace?.startedAt,
            memoryLogger: { context, frameCount, frameBufferCount, oldestTimestamp, newestTimestamp in
                MemoryTracker.logMemoryState(
                    context: context,
                    frameCount: frameCount,
                    frameBufferCount: frameBufferCount,
                    oldestTimestamp: oldestTimestamp,
                    newestTimestamp: newestTimestamp
                )
            }
        ) else { return }

        appliedLoad.apply(to: &frames, subFrameOffset: &subFrameOffset)
        logCmdFPlayheadState(
            appliedLoad.cmdFPlayheadEvent,
            trace: cmdFTrace,
            extra: appliedLoad.cmdFPlayheadExtra
        )
    }

    private func shouldPinToNewestAfterBoundaryAppend(reason _: String) -> Bool {
        if isInLiveMode {
            return true
        }

        return false
    }

    public func setPresentationWorkEnabled(_ enabled: Bool, reason: String) {
        let didChange = presentationWorkEnabled != enabled
        presentationWorkEnabled = enabled
        if didChange {
            presentationWorkGeneration &+= 1
        }
        if !enabled {
            cancelPresentationOverlayTasks()
        }
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug(
                "[TIMELINE-PRESENTATION] enabled=\(enabled) generation=\(presentationWorkGeneration) reason=\(reason)",
                category: .ui
            )
        }
    }

    func currentPresentationWorkGeneration() -> UInt64 {
        presentationWorkGeneration
    }

    func canPublishPresentationResult(
        frameID: FrameID? = nil,
        expectedGeneration: UInt64
    ) -> Bool {
        guard presentationWorkEnabled, expectedGeneration == presentationWorkGeneration else {
            return false
        }
        guard let frameID else { return true }
        return currentTimelineFrame?.frame.id == frameID
    }

    func setLoadingState(_ loading: Bool, reason: String) {
        if loading {
            if isLoading {
                let activeElapsedMs = loadingStateStartedAt.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0
                Log.warning(
                    "[TIMELINE-LOADING] START ignored reason='\(reason)' because already loading reason='\(activeLoadingReason)' elapsed=\(String(format: "%.1f", activeElapsedMs))ms",
                    category: .ui
                )
                return
            }

            loadingTransitionID &+= 1
            activeLoadingReason = reason
            loadingStateStartedAt = CFAbsoluteTimeGetCurrent()
            setMediaLoadingVisible(true)
            beginCriticalTimelineFetch()
            Log.info(
                "[TIMELINE-LOADING][\(loadingTransitionID)] START reason='\(reason)' frames=\(frames.count) index=\(currentIndex) filters={\(summarizeFiltersForLog(filterCriteria))}",
                category: .ui
            )
            return
        }

        guard isLoading else {
            Log.debug("[TIMELINE-LOADING] END ignored reason='\(reason)' (already idle)", category: .ui)
            return
        }

        let traceID = loadingTransitionID
        let startedReason = activeLoadingReason
        let elapsedMs = loadingStateStartedAt.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0

        setMediaLoadingVisible(false)
        loadingStateStartedAt = nil
        activeLoadingReason = "idle"
        endCriticalTimelineFetch()

        Log.recordLatency(
            "timeline.loading.overlay_visible_ms",
            valueMs: elapsedMs,
            category: .ui,
            summaryEvery: 10,
            warningThresholdMs: 500,
            criticalThresholdMs: 2000
        )

        let message = "[TIMELINE-LOADING][\(traceID)] END reason='\(reason)' startedBy='\(startedReason)' elapsed=\(String(format: "%.1f", elapsedMs))ms frames=\(frames.count) index=\(currentIndex)"
        if elapsedMs >= 1500 {
            Log.warning(message, category: .ui)
        } else {
            Log.info(message, category: .ui)
        }
    }

    var isCriticalTimelineFetchActive: Bool {
        criticalTimelineFetchDepth > 0
    }

    func beginCriticalTimelineFetch() {
        criticalTimelineFetchDepth += 1
        overlayRefreshWorkState.deferredRefreshNeeded = true
        cancelPresentationOverlayTasks()
    }

    func endCriticalTimelineFetch() {
        guard criticalTimelineFetchDepth > 0 else { return }

        criticalTimelineFetchDepth -= 1
        guard criticalTimelineFetchDepth == 0 else { return }

        let waiters = criticalTimelineFetchWaiters
        criticalTimelineFetchWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        if overlayRefreshWorkState.deferredRefreshNeeded {
            overlayRefreshWorkState.deferredRefreshNeeded = false
            scheduleDeferredPresentationOverlayRefresh()
        }
    }

    private func scheduleDeferredPresentationOverlayRefresh() {
        guard presentationWorkEnabled, !isActivelyScrolling else { return }
        let generation = currentPresentationWorkGeneration()
        guard canPublishPresentationResult(expectedGeneration: generation) else { return }
        refreshStaticPresentationIfNeeded()
    }

    @discardableResult
    private func prioritizeBoundaryLoadOverPresentationOverlays() -> Bool {
        guard presentationWorkEnabled, !isActivelyScrolling else { return false }
        let boundaryLoad = checkAndLoadMoreFrames(reason: "presentationOverlay")
        guard boundaryLoad.any else { return false }

        overlayRefreshWorkState.deferredRefreshNeeded = true
        cancelPresentationOverlayTasks()
        return true
    }

    func schedulePresentationOverlayRefresh(expectedGeneration: UInt64 = 0) {
        guard presentationWorkEnabled, !isInLiveMode else { return }
        guard let frame = currentTimelineFrame?.frame else {
            overlayRefreshWorkState.idleTask?.cancel()
            overlayRefreshWorkState.idleTask = nil
            return
        }

        let generation = expectedGeneration == 0
            ? currentPresentationWorkGeneration()
            : expectedGeneration
        guard canPublishPresentationResult(frameID: frame.id, expectedGeneration: generation) else { return }

        if isCriticalTimelineFetchActive {
            overlayRefreshWorkState.deferredRefreshNeeded = true
            return
        }

        if prioritizeBoundaryLoadOverPresentationOverlays() {
            return
        }

        overlayRefreshWorkState.idleTask?.cancel()
        overlayRefreshWorkState.idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .nanoseconds(WindowConfig.presentationOverlayIdleDelayNanoseconds),
                clock: .continuous
            )
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard self.presentationWorkEnabled, !self.isInLiveMode, !self.isActivelyScrolling else {
                self.overlayRefreshWorkState.deferredRefreshNeeded = true
                return
            }
            guard self.canPublishPresentationResult(frameID: frame.id, expectedGeneration: generation) else { return }
            guard !self.isCriticalTimelineFetchActive else {
                self.overlayRefreshWorkState.deferredRefreshNeeded = true
                return
            }
            if self.prioritizeBoundaryLoadOverPresentationOverlays() {
                return
            }

            self.startPresentationOverlayRefresh(
                expectedGeneration: generation,
                resetSelection: true,
                deferIfCriticalFetchActive: true
            )
        }
    }

    func startPresentationOverlayRefresh(
        expectedGeneration: UInt64 = 0,
        resetSelection: Bool,
        deferIfCriticalFetchActive: Bool
    ) {
        overlayRefreshWorkState.refreshTask?.cancel()
        overlayRefreshWorkState.refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.refreshPresentationOverlayNow(
                expectedGeneration: expectedGeneration,
                resetSelection: resetSelection,
                deferIfCriticalFetchActive: deferIfCriticalFetchActive
            )
        }
    }

    func refreshPresentationOverlayNow(
        expectedGeneration: UInt64 = 0,
        resetSelection: Bool,
        deferIfCriticalFetchActive: Bool
    ) async {
        guard !isInLiveMode else { return }
        let generation = expectedGeneration == 0
            ? currentPresentationWorkGeneration()
            : expectedGeneration
        guard canPublishPresentationResult(expectedGeneration: generation) else { return }

        guard let timelineFrame = currentTimelineFrame else {
            clearOverlayPresentationForMissingFrame()
            return
        }

        let frame = timelineFrame.frame
        guard canPublishPresentationResult(frameID: frame.id, expectedGeneration: generation) else { return }

        if revealedRedactedFrameID != frame.id {
            clearTemporaryRedactionReveals()
            revealedRedactedFrameID = frame.id
        }

        if resetSelection {
            clearTextSelection()
        }

        isHoveringURL = false

        if isCriticalTimelineFetchActive {
            if deferIfCriticalFetchActive {
                overlayRefreshWorkState.deferredRefreshNeeded = true
            }
            setURLBoundingBox(nil)
            setOCRNodes([])
            setOCRStatus(.unknown)
            clearHyperlinkMatches()
            return
        }

        guard await waitForCriticalTimelineFetchToFinishIfNeeded(
            frameID: frame.id,
            expectedGeneration: generation
        ) else { return }

        await executePresentationOverlayRefresh(
            OverlayPresentationRequest(frame: frame, generation: generation)
        )
    }

    func cancelPresentationOverlayTasks() {
        overlayRefreshWorkState.idleTask?.cancel()
        overlayRefreshWorkState.idleTask = nil
        overlayRefreshWorkState.refreshTask?.cancel()
        overlayRefreshWorkState.refreshTask = nil
        overlayRefreshWorkState.ocrStatusPollingTask?.cancel()
        overlayRefreshWorkState.ocrStatusPollingTask = nil
    }

    private func waitForCriticalTimelineFetchToFinishIfNeeded(
        frameID: FrameID,
        expectedGeneration: UInt64
    ) async -> Bool {
        guard isCriticalTimelineFetchActive else {
            return canPublishPresentationResult(frameID: frameID, expectedGeneration: expectedGeneration)
        }

        overlayRefreshWorkState.deferredRefreshNeeded = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            criticalTimelineFetchWaiters.append(continuation)
        }

        guard !Task.isCancelled else { return false }
        return canPublishPresentationResult(frameID: frameID, expectedGeneration: expectedGeneration)
    }
}
