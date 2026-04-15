import App
import AppKit
import Foundation
import Shared
import SwiftUI

extension SimpleTimelineViewModel {
    struct StoppedPosition {
        let frameID: FrameID
        let timestamp: Date
        let searchHighlightQuery: String?
    }

    static var maxStoppedPositionHistory: Int { 50 }
}

extension SimpleTimelineViewModel {
    // MARK: - Navigation + Commands

    public func recordKeyboardShortcut(_ shortcut: String) {
        DashboardViewModel.recordKeyboardShortcut(coordinator: coordinator, shortcut: shortcut)
    }

    /// Jump to the start of the previous consecutive app block.
    /// Returns true when navigation occurred, false when already at the oldest block.
    @discardableResult
    public func navigateToPreviousBlockStart() -> Bool {
        guard !frames.isEmpty else { return false }
        let snapshot = appBlockSnapshot
        let blocks = snapshot.blocks
        guard !blocks.isEmpty else { return false }
        guard let currentBlockIndex = blockIndexForFrame(currentIndex),
              currentBlockIndex > 0 else {
            return false
        }

        navigateToFrame(blocks[currentBlockIndex - 1].startIndex)
        return true
    }

    /// Jump to the start of the next consecutive app block.
    /// Returns true when navigation occurred, false when already at the newest block.
    @discardableResult
    public func navigateToNextBlockStart() -> Bool {
        guard !frames.isEmpty else { return false }
        let snapshot = appBlockSnapshot
        let blocks = snapshot.blocks
        guard !blocks.isEmpty else { return false }
        guard let currentBlockIndex = blockIndexForFrame(currentIndex),
              currentBlockIndex < blocks.count - 1 else {
            return false
        }

        navigateToFrame(blocks[currentBlockIndex + 1].startIndex)
        return true
    }

    /// Jump to the start of the next consecutive app block.
    /// If already in the newest block, jump to the newest frame.
    /// Returns true when navigation occurred, false when already at the newest frame.
    @discardableResult
    public func navigateToNextBlockStartOrNewestFrame() -> Bool {
        guard !frames.isEmpty else { return false }
        let snapshot = appBlockSnapshot
        let blocks = snapshot.blocks
        guard !blocks.isEmpty else { return false }
        guard let currentBlockIndex = blockIndexForFrame(currentIndex) else {
            return false
        }

        if currentBlockIndex < blocks.count - 1 {
            navigateToFrame(blocks[currentBlockIndex + 1].startIndex)
            return true
        }

        let newestFrameIndex = frames.count - 1
        guard currentIndex < newestFrameIndex else { return false }
        navigateToFrame(newestFrameIndex)
        return true
    }

    // MARK: - Frame Navigation

    private enum FrameNavigationContext: Equatable {
        case manual
        case searchResult
    }

    /// Navigate to a specific index in the frames array
    public func navigateToFrame(_ index: Int, fromScroll: Bool = false) {
        performFrameNavigation(index, fromScroll: fromScroll, context: .manual)
    }

    private func navigateToFrameForSearchResult(_ index: Int) {
        performFrameNavigation(index, fromScroll: false, context: .searchResult)
    }

    private func performFrameNavigation(
        _ index: Int,
        fromScroll: Bool,
        context: FrameNavigationContext
    ) {
        // Exit live mode on explicit navigation
        if isInLiveMode {
            exitLiveMode()
        }

        // Reset sub-frame offset for non-scroll navigation (click, keyboard, etc.)
        if !fromScroll {
            subFrameOffset = 0
        }

        // Clamp to valid range
        let clampedIndex = max(0, min(frames.count - 1, index))
        guard clampedIndex != currentIndex else { return }
        let previousIndex = currentIndex
        clearPositionRecoveryHintForSupersedingNavigation()

        if !undonePositionHistory.isEmpty {
            undonePositionHistory.removeAll()
        }

        // Clear transient search-result highlight when manually navigating.
        if context == .manual && !hasActiveInFrameSearchQuery {
            if isShowingSearchHighlight {
                clearSearchHighlight()
            } else if isSearchResultNavigationModeActive {
                clearSearchHighlightImmediately()
            }
        }
        // Only dismiss search overlay if there's no active search query
        if isSearchOverlayVisible && searchViewModel.searchQuery.isEmpty {
            isSearchOverlayVisible = false
        }

        // Track scrub distance for metrics
        let distance = abs(clampedIndex - currentIndex)
        TimelineWindowController.shared.accumulateScrubDistance(Double(distance))

        // Hard seek to a distant window: drop disk buffer so old-region cache doesn't pollute reads.
        if !fromScroll, distance >= Self.hardSeekResetThreshold {
            clearDiskFrameBuffer(reason: "hard seek to distant window")
        }

        currentIndex = clampedIndex
        if clampedIndex >= frames.count - 1 && frameWindowStore.hasMoreNewer {
            Log.info(
                "[PLAYHEAD-EDGE] navigateToFrame fromScroll=\(fromScroll) requested=\(index) index=\(previousIndex)->\(clampedIndex) frameCount=\(frames.count) hasMoreNewer=\(frameWindowStore.hasMoreNewer) isLoadingNewer=\(frameWindowStore.isLoadingNewer) isActivelyScrolling=\(isActivelyScrolling) subFrameOffset=\(String(format: "%.1f", subFrameOffset))",
                category: .ui
            )
        }

        if Self.isFilteredScrubDiagnosticsEnabled,
           filterCriteria.hasActiveFilters,
           let timelineFrame = currentTimelineFrame {
            let selectedApps = (filterCriteria.selectedApps ?? []).sorted().joined(separator: ",")
            let videoFrameIndex = timelineFrame.videoInfo?.frameIndex ?? -1
            let videoSuffix = timelineFrame.videoInfo.map { String($0.videoPath.suffix(32)) } ?? "nil"
            Log.debug(
                "[FILTER-SCRUB] fromScroll=\(fromScroll) index=\(previousIndex)->\(clampedIndex) frameID=\(timelineFrame.frame.id.value) ts=\(timelineFrame.frame.timestamp) bundle=\(timelineFrame.frame.metadata.appBundleID ?? "nil") selectedApps=[\(selectedApps)] videoFrameIndex=\(videoFrameIndex) videoPathSuffix=\(videoSuffix)",
                category: .ui
            )
        }

        // Clear selection when scrolling - highlight follows the playhead
        selectedFrameIndex = nil

        // Keep zoom level consistent across frames (don't reset on navigation)
        // User can reset with Cmd+0 if needed

        // Load image if this is an image-based frame
        refreshCurrentFramePresentation()

        // Check if we need to load more frames (infinite scroll)
        checkAndLoadMoreFrames()

        // Periodic memory state logging
        navigationCounter += 1
        if navigationCounter % Self.memoryLogInterval == 0 {
            MemoryTracker.logMemoryState(
                context: "PERIODIC (nav #\(navigationCounter))",
                frameCount: frames.count,
                frameBufferCount: diskFrameBufferFrameCount,
                oldestTimestamp: frameWindowStore.oldestLoadedTimestamp,
                newestTimestamp: frameWindowStore.newestLoadedTimestamp
            )
        }

        // Track stopped positions for Cmd+Z undo
        scheduleStoppedPositionRecording()
    }

    /// Schedule recording the current position as a "stopped" position after 350 ms of inactivity
    func scheduleStoppedPositionRecording() {
        // Cancel any previous work item
        cancelPendingStoppedPositionRecording()

        let indexToRecord = currentIndex

        // Create new work item (lighter weight than Task)
        let workItem = DispatchWorkItem { [weak self] in
            self?.recordStoppedPosition(indexToRecord)
        }
        playheadStoppedDetectionWorkItem = workItem

        // Schedule after the threshold duration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stoppedThresholdSeconds, execute: workItem)
    }

    func cancelPendingStoppedPositionRecording() {
        playheadStoppedDetectionWorkItem?.cancel()
        playheadStoppedDetectionWorkItem = nil
    }

    @discardableResult
    func recordCurrentPositionImmediatelyForUndo(
        reason: String,
        highlightQueryOverride: String? = nil
    ) -> Bool {
        let historyCountBefore = stoppedPositionHistory.count
        recordStoppedPosition(currentIndex, highlightQueryOverride: highlightQueryOverride)
        let didRecord = stoppedPositionHistory.count != historyCountBefore
        if didRecord {
            Log.debug(
                "[PlayheadUndo] Recorded immediate jump snapshot for \(reason) (history size=\(stoppedPositionHistory.count))",
                category: .ui
            )
        }
        return didRecord
    }

    /// Preserve the current playhead as an undo target, then snap to newest immediately.
    /// Used when hidden-state cache expiry advances reopen to "now".
    @discardableResult
    public func applyCacheBustReopenSnapToNewest(newestIndex: Int) -> Bool {
        guard !frames.isEmpty else { return false }

        let clampedNewestIndex = max(0, min(frames.count - 1, newestIndex))
        guard clampedNewestIndex != currentIndex else { return false }

        cancelPendingStoppedPositionRecording()
        _ = recordCurrentPositionImmediatelyForUndo(reason: "timelineReopen.cacheBust.source")
        currentIndex = clampedNewestIndex
        _ = recordCurrentPositionImmediatelyForUndo(reason: "timelineReopen.cacheBust.destination")
        return true
    }

    /// Record a position as a "stopped" position for undo history
    private func recordStoppedPosition(_ index: Int, highlightQueryOverride: String? = nil) {
        // Don't record invalid indices
        guard index >= 0 && index < frames.count else { return }

        let frame = frames[index].frame
        let frameID = frame.id
        let timestamp = frame.timestamp
        let preservedHighlightQuery = normalizedRestorableSearchHighlightQuery(
            highlightQueryOverride ?? currentRestorableSearchHighlightQuery()
        )

        // Don't record if it's the same as the last recorded frame
        guard frameID != lastRecordedStoppedFrameID else { return }

        // New user navigation invalidates redo history.
        if !undonePositionHistory.isEmpty {
            undonePositionHistory.removeAll()
        }

        // Add to history
        stoppedPositionHistory.append(
            StoppedPosition(
                frameID: frameID,
                timestamp: timestamp,
                searchHighlightQuery: preservedHighlightQuery
            )
        )
        lastRecordedStoppedFrameID = frameID

        // Trim history if it exceeds max size
        if stoppedPositionHistory.count > Self.maxStoppedPositionHistory {
            stoppedPositionHistory.removeFirst(stoppedPositionHistory.count - Self.maxStoppedPositionHistory)
        }

        Log.debug("[PlayheadUndo] Recorded stopped position: frameID=\(frameID.stringValue), timestamp=\(timestamp), history size=\(stoppedPositionHistory.count)", category: .ui)
    }

    func normalizedRestorableSearchHighlightQuery(_ query: String?) -> String? {
        guard let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedQuery.isEmpty else {
            return nil
        }
        return normalizedQuery
    }

    private func currentRestorableSearchHighlightQuery() -> String? {
        guard !hasActiveInFrameSearchQuery, isShowingSearchHighlight else {
            return nil
        }
        return normalizedRestorableSearchHighlightQuery(searchHighlightQuery)
    }

    private func restoreSearchHighlightIfNeeded(from position: StoppedPosition) {
        guard let query = position.searchHighlightQuery else { return }
        showSearchHighlight(query: query)
    }

    /// Undo to the last stopped playhead position (Cmd+Z)
    /// Returns true if there was a position to undo to, false otherwise
    @discardableResult
    public func undoToLastStoppedPosition() -> Bool {
        // Need at least 2 positions: current (most recent) and one to go back to
        guard stoppedPositionHistory.count >= 2 else {
            Log.debug("[PlayheadUndo] No position to undo to (history size: \(stoppedPositionHistory.count))", category: .ui)
            return false
        }

        // Remove the current position (most recent) and move it to redo history.
        let currentPosition = stoppedPositionHistory.removeLast()
        undonePositionHistory.append(currentPosition)
        if undonePositionHistory.count > Self.maxStoppedPositionHistory {
            undonePositionHistory.removeFirst(undonePositionHistory.count - Self.maxStoppedPositionHistory)
        }

        // Get the previous position
        guard let previousPosition = stoppedPositionHistory.last else {
            return false
        }

        // Update lastRecordedStoppedFrameID to prevent re-recording the same position
        lastRecordedStoppedFrameID = previousPosition.frameID

        // Cancel any pending stopped position recording
        cancelPendingStoppedPositionRecording()

        // Undo is an explicit timeline navigation action; clear transient search-result highlight.
        resetSearchHighlightState()
        clearPositionRecoveryHint()

        // History navigation targets historical frames, so it must leave live mode even
        // when the destination frame is already loaded in memory.
        if isInLiveMode {
            exitLiveMode()
        }

        // Fast path: check if frame exists in current frames array
        if let index = frames.firstIndex(where: { $0.frame.id == previousPosition.frameID }) {
            Log.debug("[PlayheadUndo] Fast path: found frame in current array at index \(index)", category: .ui)
            if index != currentIndex {
                currentIndex = index
                refreshCurrentFramePresentation()
                checkAndLoadMoreFrames()
            }
            restoreSearchHighlightIfNeeded(from: previousPosition)
            return true
        }

        // Slow path: frame not in current array, need to reload frames around the timestamp
        Log.debug("[PlayheadUndo] Slow path: frame not in current array, reloading around timestamp \(previousPosition.timestamp)", category: .ui)

        Task { @MainActor in
            await navigateToUndoPosition(previousPosition)
        }

        return true
    }

    /// Redo to the last undone playhead position (Cmd+Shift+Z).
    /// Returns true if there was a position to redo to, false otherwise.
    @discardableResult
    public func redoLastUndonePosition() -> Bool {
        guard let nextPosition = undonePositionHistory.popLast() else {
            return false
        }

        // Cancel pending stop-detection work to avoid stale position snapshots during redo.
        cancelPendingStoppedPositionRecording()

        // Redo is explicit timeline navigation; clear transient search-result highlight.
        resetSearchHighlightState()

        // Redoing to a previous playhead state should also leave live mode before the
        // fast in-memory path updates the frame index.
        if isInLiveMode {
            exitLiveMode()
        }

        // Keep undo history in sync with the redone position.
        if stoppedPositionHistory.last?.frameID != nextPosition.frameID {
            stoppedPositionHistory.append(nextPosition)
            if stoppedPositionHistory.count > Self.maxStoppedPositionHistory {
                stoppedPositionHistory.removeFirst(stoppedPositionHistory.count - Self.maxStoppedPositionHistory)
            }
        }
        lastRecordedStoppedFrameID = nextPosition.frameID

        // Fast path: frame already in loaded window.
        if let index = frames.firstIndex(where: { $0.frame.id == nextPosition.frameID }) {
            if index != currentIndex {
                currentIndex = index
                refreshCurrentFramePresentation()
                checkAndLoadMoreFrames()
            }
            restoreSearchHighlightIfNeeded(from: nextPosition)
            return true
        }

        // Slow path: frame outside current window.
        Task { @MainActor in
            await navigateToUndoPosition(nextPosition)
        }
        return true
    }

    /// Navigate to an undo position by reloading frames around the timestamp
    /// Similar to navigateToSearchResult but without search highlighting
    @MainActor
    private func navigateToUndoPosition(_ position: StoppedPosition) async {
        // Exit live mode - we're navigating to a historical frame
        if isInLiveMode {
            exitLiveMode()
        }

        // Reuse the shared reload path so boundary-state reset/load-more behavior stays consistent.
        clearDiskFrameBuffer(reason: "undo navigation")
        await reloadFramesAroundTimestamp(position.timestamp)

        guard !frames.isEmpty else {
            Log.warning("[PlayheadUndo] Reload window empty after undo navigation", category: .ui)
            return
        }

        // Ensure undo lands on the exact frame when available.
        if let index = frames.firstIndex(where: { $0.frame.id == position.frameID }) {
            if index != currentIndex {
                currentIndex = index
                refreshCurrentFramePresentation()
                _ = checkAndLoadMoreFrames(reason: "navigateToUndoPosition.postReloadFramePin")
            }
        } else {
            Log.warning("[PlayheadUndo] Frame ID not found after reload, keeping closest timestamp frame", category: .ui)
        }

        restoreSearchHighlightIfNeeded(from: position)

        Log.info("[PlayheadUndo] Navigation complete, now at index \(currentIndex)", category: .ui)
    }

    private func beginSearchResultNavigation() -> UInt64 {
        searchResultNavigationGeneration &+= 1
        return searchResultNavigationGeneration
    }

    private func isCurrentSearchResultNavigation(_ generation: UInt64) -> Bool {
        generation == searchResultNavigationGeneration
    }

    func invalidateSearchResultNavigation() {
        searchResultNavigationGeneration &+= 1
    }

    func cancelPendingSearchHighlightTasks() {
        pendingSearchHighlightRevealTask?.cancel()
        pendingSearchHighlightRevealTask = nil
        pendingSearchHighlightResetTask?.cancel()
        pendingSearchHighlightResetTask = nil
    }

    private var activeSearchResultHighlightQuery: String? {
        let candidates: [String?] = [
            searchViewModel.committedSearchQuery,
            searchViewModel.searchQuery,
            searchHighlightQuery
        ]

        return candidates
            .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            .first(where: { !$0.isEmpty })
    }

    enum SearchResultNavigationTrigger {
        case button
        case keyboard

        var metricTrigger: String {
            switch self {
            case .button:
                return "button"
            case .keyboard:
                return "keyboard"
            }
        }
    }

    var searchResultHighlightNavigationState: SearchViewModel.ResultNavigationState? {
        guard isSearchResultNavigationModeActive,
              !hasActiveInFrameSearchQuery else {
            return nil
        }
        return searchViewModel.selectedResultNavigationState
    }

    private func recordSearchResultNavigation(
        direction: String,
        trigger: SearchResultNavigationTrigger,
        state: SearchViewModel.ResultNavigationState,
        didMove: Bool,
        didRequestMore: Bool
    ) {
        TimelineMetrics.recordSearchResultNavigation(
            coordinator: coordinator,
            direction: direction,
            trigger: trigger.metricTrigger,
            position: state.currentPosition,
            loadedCount: state.loadedCount,
            didMove: didMove,
            didRequestMore: didRequestMore
        )
    }

    func navigateToAdjacentSearchResult(
        offset: Int,
        trigger: SearchResultNavigationTrigger
    ) async {
        guard offset != 0,
              let navigationState = searchResultHighlightNavigationState else {
            return
        }

        let direction = offset > 0 ? "next" : "previous"
        let didRequestMore = offset > 0 && navigationState.requestsMoreResultsOnNextAdvance

        guard let targetResult = searchViewModel.selectAdjacentResult(offset: offset) else {
            recordSearchResultNavigation(
                direction: direction,
                trigger: trigger,
                state: navigationState,
                didMove: false,
                didRequestMore: didRequestMore
            )
            return
        }

        recordSearchResultNavigation(
            direction: direction,
            trigger: trigger,
            state: navigationState,
            didMove: true,
            didRequestMore: didRequestMore
        )

        let highlightQuery = activeSearchResultHighlightQuery ?? targetResult.matchedText
        await navigateToSearchResult(
            frameID: targetResult.id,
            timestamp: targetResult.timestamp,
            highlightQuery: highlightQuery,
            highlightImmediately: true
        )
    }

    /// Navigate to a specific frame by ID and highlight the search query
    /// Used when selecting a search result
    public func navigateToSearchResult(
        frameID: FrameID,
        timestamp: Date,
        highlightQuery: String,
        highlightImmediately: Bool = false
    ) async {
        let navigationGeneration = beginSearchResultNavigation()
        cancelPendingStoppedPositionRecording()
        _ = recordCurrentPositionImmediatelyForUndo(reason: "navigateToSearchResult.source")

        // Exit live mode immediately - we're navigating to a specific historical frame
        if isInLiveMode {
            exitLiveMode()
        }

        // Clear any active filters so the target frame is guaranteed to be found
        if filterCriteria.hasActiveFilters {
            Log.info("[SearchNavigation] Clearing active filters before navigating to search result", category: .ui)
            clearFilterState()
            filterStore.dismissFilterUI(invalidate: notifyFilterStateWillChange)
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.timeZone = .current
        Log.info("[SearchNavigation] Navigating to search result: frameID=\(frameID.stringValue), timestamp=\(df.string(from: timestamp)) (epoch: \(timestamp.timeIntervalSince1970)), query='\(highlightQuery)'", category: .ui)

        // First, try to find a frame with this ID in our current data
        if let index = frames.firstIndex(where: { $0.frame.id == frameID }) {
            guard isCurrentSearchResultNavigation(navigationGeneration) else {
                setLoadingState(false, reason: "navigateToSearchResult.supersededBeforeFrameWindow")
                return
            }
            navigateToFrameForSearchResult(index)
            _ = recordCurrentPositionImmediatelyForUndo(
                reason: "navigateToSearchResult.destination",
                highlightQueryOverride: highlightQuery
            )
            if highlightImmediately {
                showSearchHighlight(
                    query: highlightQuery,
                    mode: .matchedNodes,
                    delay: 0,
                    preserveExistingPresentation: true
                )
                await refreshPresentationOverlayNow(
                    resetSelection: false,
                    deferIfCriticalFetchActive: true
                )
                guard isCurrentSearchResultNavigation(navigationGeneration) else { return }
            } else {
                showSearchHighlight(
                    query: highlightQuery,
                    mode: .matchedNodes,
                    delay: 0.5
                )
            }
            setLoadingState(false, reason: "navigateToSearchResult.localFrame")
            return
        }

        // If not found, load frames in a ±10 minute window around the target timestamp
        // This approach (same as Cmd+G date search) guarantees the target frame is included
        do {
            setLoadingState(true, reason: "navigateToSearchResult")

            // Calculate ±10 minute window around target timestamp
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: timestamp) ?? timestamp
            let endDate = calendar.date(byAdding: .minute, value: 10, to: timestamp) ?? timestamp

            // Fetch all frames in the 20-minute window with video info (single optimized query)
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "navigateToSearchResult"
            )

            guard isCurrentSearchResultNavigation(navigationGeneration) else {
                setLoadingState(false, reason: "navigateToSearchResult.supersededBeforeHighlight")
                return
            }

            guard !framesWithVideoInfo.isEmpty else {
                Log.warning("[SearchNavigation] No frames found in time range", category: .ui)
                setLoadingState(false, reason: "navigateToSearchResult.noFrames")
                return
            }

            applyNavigationFrameWindow(
                framesWithVideoInfo,
                clearDiskBufferReason: "search navigation"
            )
            clearPositionRecoveryHintForSupersedingNavigation()

            // Find and navigate to the target frame by ID
            if let index = frames.firstIndex(where: { $0.frame.id == frameID }) {
                currentIndex = index
            } else {
                // Fallback: find closest frame by timestamp if ID not found
                let closest = frames.enumerated().min(by: {
                    abs($0.element.frame.timestamp.timeIntervalSince(timestamp)) <
                    abs($1.element.frame.timestamp.timeIntervalSince(timestamp))
                })
                currentIndex = closest?.offset ?? 0
                if let closestFrame = closest {
                    let diff = abs(closestFrame.element.frame.timestamp.timeIntervalSince(timestamp))
                    Log.warning("[SearchNavigation] Frame ID not found in loaded frames, using closest by timestamp at index \(closestFrame.offset), \(diff)s from target", category: .ui)
                }
            }
            _ = recordCurrentPositionImmediatelyForUndo(
                reason: "navigateToSearchResult.destination",
                highlightQueryOverride: highlightQuery
            )

            refreshCurrentFramePresentation()

            // Check if we need to pre-load more frames (near edge of loaded window)
            checkAndLoadMoreFrames()

            if highlightImmediately {
                showSearchHighlight(
                    query: highlightQuery,
                    mode: .matchedNodes,
                    delay: 0,
                    preserveExistingPresentation: true
                )
            }

            // Wait for the overlay pipeline to publish OCR nodes before showing highlight.
            await refreshPresentationOverlayNow(
                resetSelection: false,
                deferIfCriticalFetchActive: true
            )
            guard isCurrentSearchResultNavigation(navigationGeneration) else {
                setLoadingState(false, reason: "navigateToSearchResult.supersededAfterOCRLoad")
                return
            }
            if !highlightImmediately {
                showSearchHighlight(
                    query: highlightQuery,
                    mode: .matchedNodes,
                    delay: 0.5
                )
            }
            setLoadingState(false, reason: "navigateToSearchResult.success")
            Log.info("[SearchNavigation] Navigation complete, now at index \(currentIndex)", category: .ui)

        } catch {
            Log.error("[SearchNavigation] Failed to navigate to search result: \(error)", category: .ui)
            setLoadingState(false, reason: "navigateToSearchResult.error")
        }
    }
}
