import AppKit
import Foundation
import Shared

extension SimpleTimelineViewModel {
    @MainActor
    public func invalidateCachesAndReload() {
        Log.info("[DataSourceChange] invalidateCachesAndReload() called", category: .ui)

        let oldImageCount = diskFrameBufferIndex.count
        Log.debug("[DataSourceChange] Clearing disk frame buffer with \(oldImageCount) entries", category: .ui)
        clearDiskFrameBuffer(reason: "data source reload")
        Log.debug("[DataSourceChange] Disk frame buffer cleared, new count: \(diskFrameBufferIndex.count)", category: .ui)

        let hadAppBlocks = blockSnapshotController.hasCachedSnapshot
        commentsStore.resetLoadedTagIndicatorState(invalidate: notifyCommentStateWillChange)
        applyAppBlockSnapshotUpdate(.invalidate, reason: .invalidateCachesAndReload)
        Log.debug("[DataSourceChange] Cleared app blocks cache (had cached: \(hadAppBlocks))", category: .ui)

        Log.debug("[DataSourceChange] Clearing search results", category: .ui)
        searchViewModel.clearSearchResults()

        filterStore.clearCriteria(invalidate: notifyFilterStateWillChange)
        clearCachedFilterCriteria()
        Log.debug("[DataSourceChange] Cleared filter state and cache", category: .ui)

        Log.info("[DataSourceChange] Cleared \(oldImageCount) buffered frames, search results, and filters, reloading from current position", category: .ui)
        Log.debug("[DataSourceChange] Current frames count: \(frames.count), currentIndex: \(currentIndex)", category: .ui)

        if currentIndex >= 0 && currentIndex < frames.count {
            let currentTimestamp = frames[currentIndex].frame.timestamp
            Log.debug("[DataSourceChange] Will reload frames around timestamp: \(currentTimestamp)", category: .ui)
            Task {
                await reloadFramesAroundTimestamp(currentTimestamp)
            }
        } else {
            Log.debug("[DataSourceChange] No valid current position, will load most recent frame", category: .ui)
            Task {
                await loadMostRecentFrame()
            }
        }
        Log.debug("[DataSourceChange] invalidateCachesAndReload() completed", category: .ui)
    }

    func reloadFramesAroundTimestamp(
        _ timestamp: Date,
        cmdFTrace: CmdFQuickFilterLatencyTrace? = nil,
        refreshPresentation: Bool = true
    ) async {
        let reloadStart = CFAbsoluteTimeGetCurrent()
        Log.debug("[DataSourceChange] reloadFramesAroundTimestamp() starting for timestamp: \(timestamp)", category: .ui)
        if let cmdFTrace {
            Log.debug(
                "[CmdFPerf][\(cmdFTrace.id)] Reload around timestamp started action=\(cmdFTrace.action) app=\(cmdFTrace.bundleID) source=\(cmdFTrace.source.rawValue)",
                category: .ui
            )
        }
        logCmdFPlayheadState("reload.start", trace: cmdFTrace, targetTimestamp: timestamp)
        setLoadingState(true, reason: "reloadFramesAroundTimestamp")
        clearError()

        do {
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: timestamp) ?? timestamp
            let endDate = calendar.date(byAdding: .minute, value: 10, to: timestamp) ?? timestamp

            Log.debug("[DataSourceChange] Fetching frames from \(startDate) to \(endDate)", category: .ui)
            let queryStart = CFAbsoluteTimeGetCurrent()
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "reloadFramesAroundTimestamp"
            )
            let queryElapsedMs = (CFAbsoluteTimeGetCurrent() - queryStart) * 1000
            Log.debug("[DataSourceChange] Fetched \(framesWithVideoInfo.count) frames from data adapter", category: .ui)

            if !framesWithVideoInfo.isEmpty {
                let timelineFrames = framesWithVideoInfo.map { TimelineFrame(frameWithVideoInfo: $0) }
                let closestIndex = Self.findClosestFrameIndex(in: timelineFrames, to: timestamp)
                let preparedWindow = frameWindowStore.prepareNavigationWindowReplacement(
                    reason: "reloadFramesAroundTimestamp",
                    frames: timelineFrames,
                    currentIndex: closestIndex
                )
                frames = preparedWindow.frames
                logCmdFPlayheadState("reload.framesReplaced", trace: cmdFTrace, targetTimestamp: timestamp)
                logCmdFPlayheadState(
                    "reload.closestIndexSelected",
                    trace: cmdFTrace,
                    targetTimestamp: timestamp,
                    extra: "closestIndex=\(preparedWindow.resultingCurrentIndex)"
                )

                ensureTapeTagIndicatorDataLoadedIfNeeded()

                if refreshPresentation {
                    refreshCurrentFramePresentation()
                }

                let boundaryLoad = checkAndLoadMoreFrames(reason: "reloadFramesAroundTimestamp", cmdFTrace: cmdFTrace)
                logCmdFPlayheadState(
                    "reload.boundaryCheck",
                    trace: cmdFTrace,
                    targetTimestamp: timestamp,
                    extra: "boundaryOlder=\(boundaryLoad.older) boundaryNewer=\(boundaryLoad.newer)"
                )

                Log.info("[DataSourceChange] Reloaded \(frames.count) frames around \(timestamp)", category: .ui)
                if let cmdFTrace {
                    let reloadElapsedMs = (CFAbsoluteTimeGetCurrent() - reloadStart) * 1000
                    let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.recordLatency(
                        "timeline.cmdf.quick_filter.reload_window_ms",
                        valueMs: totalElapsedMs,
                        category: .ui,
                        summaryEvery: 5,
                        warningThresholdMs: 220,
                        criticalThresholdMs: 500
                    )
                    Log.info(
                        "[CmdFPerf][\(cmdFTrace.id)] Reload complete trigger=\(cmdFTrace.trigger) action=\(cmdFTrace.action) query=\(String(format: "%.1f", queryElapsedMs))ms reload=\(String(format: "%.1f", reloadElapsedMs))ms total=\(String(format: "%.1f", totalElapsedMs))ms frames=\(frames.count) index=\(currentIndex) boundaryOlder=\(boundaryLoad.older) boundaryNewer=\(boundaryLoad.newer)",
                        category: .ui
                    )
                }
            } else {
                Log.info("[DataSourceChange] No frames found around timestamp, loading most recent", category: .ui)
                if let cmdFTrace {
                    let elapsedBeforeFallbackMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.warning(
                        "[CmdFPerf][\(cmdFTrace.id)] Empty reload window after \(String(format: "%.1f", elapsedBeforeFallbackMs))ms (query \(String(format: "%.1f", queryElapsedMs))ms), falling back to loadMostRecentFrame()",
                        category: .ui
                    )
                }
                logCmdFPlayheadState("reload.emptyWindow", trace: cmdFTrace, targetTimestamp: timestamp)
                let fallbackStart = CFAbsoluteTimeGetCurrent()
                setLoadingState(false, reason: "reloadFramesAroundTimestamp.fallbackHandoff")
                await loadMostRecentFrame(refreshPresentation: refreshPresentation)
                logCmdFPlayheadState("reload.fallbackComplete", trace: cmdFTrace, targetTimestamp: timestamp)
                if let cmdFTrace {
                    let fallbackElapsedMs = (CFAbsoluteTimeGetCurrent() - fallbackStart) * 1000
                    let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.recordLatency(
                        "timeline.cmdf.quick_filter.fallback_total_ms",
                        valueMs: totalElapsedMs,
                        category: .ui,
                        summaryEvery: 5,
                        warningThresholdMs: 320,
                        criticalThresholdMs: 750
                    )
                    Log.info(
                        "[CmdFPerf][\(cmdFTrace.id)] Fallback loadMostRecentFrame() complete fallback=\(String(format: "%.1f", fallbackElapsedMs))ms total=\(String(format: "%.1f", totalElapsedMs))ms",
                        category: .ui
                    )
                }
                return
            }
        } catch {
            Log.error("[DataSourceChange] Failed to reload frames: \(error)", category: .ui)
            if let cmdFTrace {
                let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                Log.error(
                    "[CmdFPerf][\(cmdFTrace.id)] Reload failed after \(String(format: "%.1f", totalElapsedMs))ms action=\(cmdFTrace.action) app=\(cmdFTrace.bundleID): \(error)",
                    category: .ui
                )
            }
            setPresentationError(error.localizedDescription)
        }

        setLoadingState(false, reason: "reloadFramesAroundTimestamp.complete")
    }

    private func waitForInFlightMostRecentLoad() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            initialMostRecentLoadWaiters.append(continuation)
        }
    }

    private func completeMostRecentLoadWaiters() {
        guard !initialMostRecentLoadWaiters.isEmpty else { return }
        let waiters = initialMostRecentLoadWaiters
        initialMostRecentLoadWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    public func loadMostRecentFrame(
        clickStartTime _: CFAbsoluteTime? = nil,
        refreshPresentation: Bool = true
    ) async {
        if isInitialLoadInProgress {
            Log.debug("[SimpleTimelineViewModel] loadMostRecentFrame joining in-flight initial load", category: .ui)
            await waitForInFlightMostRecentLoad()
            return
        }

        guard !isLoading else {
            let activeElapsedMs = loadingStateStartedAt.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0
            Log.warning(
                "[SimpleTimelineViewModel] loadMostRecentFrame skipped - already loading reason='\(activeLoadingReason)' elapsed=\(String(format: "%.1f", activeElapsedMs))ms",
                category: .ui
            )
            return
        }

        isInitialLoadInProgress = true
        defer {
            isInitialLoadInProgress = false
            completeMostRecentLoadWaiters()
        }

        setLoadingState(true, reason: "loadMostRecentFrame")
        clearError()

        do {
            Log.debug("[SimpleTimelineViewModel] Loading frames with filters - hasActiveFilters: \(filterCriteria.hasActiveFilters), apps: \(String(describing: filterCriteria.selectedApps)), mode: \(filterCriteria.appFilterMode.rawValue)", category: .ui)
            let framesWithVideoInfo = try await fetchMostRecentFramesWithVideoInfoLogged(
                limit: WindowConfig.maxFrames,
                filters: filterCriteria,
                reason: "loadMostRecentFrame"
            )

            guard !framesWithVideoInfo.isEmpty else {
                if filterCriteria.hasActiveFilters {
                    applyFilteredEmptyTimelineState(context: "loadMostRecentFrame.noFrames")
                    showNoResultsMessage()
                } else {
                    showErrorWithAutoDismiss("No frames found in any database")
                }
                setLoadingState(false, reason: "loadMostRecentFrame.noFrames")
                return
            }

            let preparedWindow = frameWindowStore.prepareMostRecentWindowReplacement(
                reason: "loadMostRecentFrame",
                from: framesWithVideoInfo
            )
            frames = preparedWindow.frames

            Log.debug("[SimpleTimelineViewModel] Loaded \(frames.count) frames", category: .ui)

            MemoryTracker.logMemoryState(
                context: "INITIAL LOAD",
                frameCount: frames.count,
                frameBufferCount: diskFrameBufferIndex.count,
                oldestTimestamp: frameWindowStore.oldestLoadedTimestamp,
                newestTimestamp: frameWindowStore.newestLoadedTimestamp
            )
            if frames.count > 0 {
                Log.debug("[SimpleTimelineViewModel] First 3 frames (should be oldest):", category: .ui)
                for i in 0..<min(3, frames.count) {
                    let f = frames[i].frame
                    Log.debug("  [\(i)] \(f.timestamp) - \(f.metadata.appBundleID ?? "nil")", category: .ui)
                }
                Log.debug("[SimpleTimelineViewModel] Last 3 frames (should be newest):", category: .ui)
                for i in max(0, frames.count - 3)..<frames.count {
                    let f = frames[i].frame
                    Log.debug("  [\(i)] \(f.timestamp) - \(f.metadata.appBundleID ?? "nil")", category: .ui)
                }
            }

            Log.info(
                "[TIMELINE-BLOCK] initial-load reason=loadMostRecentFrame newest={\(TimelineFrameWindowBlockSupport.describeEdgeBlock(TimelineFrameWindowBlockSupport.newestEdgeBlockSummary(in: frames)))}",
                category: .ui
            )

            scheduleStoppedPositionRecording()
            checkAndLoadMoreFrames()
            _ = await searchViewModel.restoreCachedSearchResults()
            ensureTapeTagIndicatorDataLoadedIfNeeded()

            if refreshPresentation {
                refreshCurrentFramePresentation()
            }

            setLoadingState(false, reason: "loadMostRecentFrame.success")
        } catch {
            setPresentationError("Failed to load frames: \(error.localizedDescription)")
            setLoadingState(false, reason: "loadMostRecentFrame.error")
        }
    }

    public func loadFramesDirectly(_ framesWithVideoInfo: [FrameWithVideoInfo], clickStartTime _: CFAbsoluteTime? = nil) async {
        guard !isInitialLoadInProgress && !isLoading else {
            Log.debug("[SimpleTimelineViewModel] loadFramesDirectly skipped - already loading", category: .ui)
            return
        }
        isInitialLoadInProgress = true
        defer { isInitialLoadInProgress = false }

        setLoadingState(true, reason: "loadFramesDirectly")
        clearError()

        guard !framesWithVideoInfo.isEmpty else {
            if filterCriteria.hasActiveFilters {
                applyFilteredEmptyTimelineState(context: "loadFramesDirectly.noFrames")
                showNoResultsMessage()
            } else {
                showErrorWithAutoDismiss("No frames found in any database")
            }
            setLoadingState(false, reason: "loadFramesDirectly.noFrames")
            return
        }

        let preparedWindow = frameWindowStore.prepareMostRecentWindowReplacement(
            reason: "loadFramesDirectly",
            from: framesWithVideoInfo
        )
        frames = preparedWindow.frames

        Log.debug("[SimpleTimelineViewModel] Loaded \(frames.count) frames directly", category: .ui)
        scheduleStoppedPositionRecording()
        checkAndLoadMoreFrames()
        _ = await searchViewModel.restoreCachedSearchResults()
        ensureTapeTagIndicatorDataLoadedIfNeeded()
        refreshCurrentFramePresentation()
        setLoadingState(false, reason: "loadFramesDirectly.success")
    }

    public func refreshFrameData(
        navigateToNewest: Bool = true,
        allowNearLiveAutoAdvance: Bool = true,
        refreshPresentation: Bool = true
    ) async {
        beginCriticalTimelineFetch()
        defer { endCriticalTimelineFetch() }

        if !frames.isEmpty {
            let hasActiveFilters = filterCriteria.hasActiveFilters
            let newestLoadedFrameIsRecent = isNewestLoadedFrameRecent(now: refreshFrameDataCurrentDate())
            let existingWindowAction = TimelineRefreshWindowSupport.makeExistingWindowAction(
                navigateToNewest: navigateToNewest,
                allowNearLiveAutoAdvance: allowNearLiveAutoAdvance,
                currentIndex: currentIndex,
                frameCount: frames.count,
                hasActiveFilters: hasActiveFilters,
                newestLoadedFrameIsRecent: newestLoadedFrameIsRecent,
                nearLiveEdgeFrameThreshold: Self.nearLiveEdgeFrameThreshold
            )

            let shouldNavigateToNewest: Bool
            switch existingWindowAction {
            case .skipRefresh:
                if refreshPresentation {
                    refreshCurrentFramePresentation()
                }
                return
            case let .refresh(shouldNavigate):
                shouldNavigateToNewest = shouldNavigate
            }

            if filterStore.consumeRequiresFullReloadOnNextRefresh(invalidate: notifyFilterStateWillChange) {
                if shouldNavigateToNewest {
                    await loadMostRecentFrame(refreshPresentation: refreshPresentation)
                } else if let timestamp = currentTimestamp {
                    await reloadFramesAroundTimestamp(timestamp, refreshPresentation: refreshPresentation)
                } else {
                    await loadMostRecentFrame(refreshPresentation: refreshPresentation)
                }
                return
            }

            if let newestCachedTimestamp = frames.last?.frame.timestamp {
                do {
                    let refreshLimit = 50
                    let newerFrames = try await fetchMostRecentFramesWithVideoInfoLogged(
                        limit: refreshLimit,
                        filters: filterCriteria,
                        reason: "refreshFrameData.navigateToNewest=\(shouldNavigateToNewest)"
                    )
                    switch TimelineRefreshWindowSupport.makeFetchAction(
                        existingFrames: frames,
                        currentIndex: currentIndex,
                        fetchedFrames: newerFrames,
                        newestCachedTimestamp: newestCachedTimestamp,
                        refreshLimit: refreshLimit,
                        shouldNavigateToNewest: shouldNavigateToNewest,
                        hasStartedScrubbingThisVisibleSession: hasStartedScrubbingThisVisibleSession
                    ) {
                    case .noChange:
                        break
                    case .requireFullReloadToNewest:
                        await loadMostRecentFrame(refreshPresentation: refreshPresentation)
                        return
                    case let .pinToNewestExisting(resultingCurrentIndex):
                        if currentIndex != resultingCurrentIndex {
                            currentIndex = resultingCurrentIndex
                        }
                    case let .append(result):
                        let preparedAppend = frameWindowStore.applyRefreshAppendMutation(
                            result,
                            maxFrames: WindowConfig.maxFrames,
                            isActivelyScrolling: isActivelyScrolling,
                            frameBufferCount: diskFrameBufferIndex.count,
                            memoryLogger: { context, frameCount, frameBufferCount, oldestTimestamp, newestTimestamp in
                                MemoryTracker.logMemoryState(
                                    context: context,
                                    frameCount: frameCount,
                                    frameBufferCount: frameBufferCount,
                                    oldestTimestamp: oldestTimestamp,
                                    newestTimestamp: newestTimestamp
                                )
                            }
                        )
                        frames = preparedAppend.frames
                    }
                } catch {
                    Log.error("[TIMELINE-REFRESH] Failed to check for new frames: \(error)", category: .ui)
                }
            }

            if refreshPresentation {
                refreshCurrentFramePresentation()
            }
            return
        }

        await loadMostRecentFrame(refreshPresentation: refreshPresentation)
    }
}
