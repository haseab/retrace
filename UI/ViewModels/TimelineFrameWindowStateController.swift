import Foundation
import Shared

final class TimelineFrameWindowStateController {
    var pendingCurrentIndexAfterFrameReplacement: Int?
    var olderBoundaryLoadTask: Task<Void, Never>?
    var newerBoundaryLoadTask: Task<Void, Never>?

    var deferredTrimRequest: TimelineDeferredTrimRequest?

    private(set) var oldestLoadedTimestamp: Date?
    private(set) var newestLoadedTimestamp: Date?

    var isLoadingOlder = false
    var isLoadingNewer = false

    private var boundaryLoadContextGeneration: UInt64 = 0

    var hasMoreOlder = true
    var hasMoreNewer = true
    var hasReachedAbsoluteEnd = false
    var hasReachedAbsoluteStart = false

    var deferredTrimDirection: TimelineTrimDirection? {
        deferredTrimRequest?.direction
    }

    func consumePendingCurrentIndexAfterFrameReplacement() -> Int? {
        let pendingIndex = pendingCurrentIndexAfterFrameReplacement
        pendingCurrentIndexAfterFrameReplacement = nil
        return pendingIndex
    }

    func setPendingCurrentIndexAfterFrameReplacement(_ index: Int?) {
        pendingCurrentIndexAfterFrameReplacement = index
    }

    func updateWindowBoundaries(frames: [TimelineFrame]) {
        oldestLoadedTimestamp = frames.first?.frame.timestamp
        newestLoadedTimestamp = frames.last?.frame.timestamp
    }

    func setWindowBoundaries(oldest: Date?, newest: Date?) {
        oldestLoadedTimestamp = oldest
        newestLoadedTimestamp = newest
    }

    func invalidateBoundaryLoadContext() {
        boundaryLoadContextGeneration &+= 1
    }

    func resetBoundaryLoadState() {
        invalidateBoundaryLoadContext()
        isLoadingOlder = false
        isLoadingNewer = false
    }

    func replaceBoundaryLoadTask(
        direction: TimelineBoundaryLoadDirection,
        task: Task<Void, Never>
    ) {
        switch direction {
        case .older:
            olderBoundaryLoadTask?.cancel()
            olderBoundaryLoadTask = task
        case .newer:
            newerBoundaryLoadTask?.cancel()
            newerBoundaryLoadTask = task
        }
    }

    func clearBoundaryLoadTask(direction: TimelineBoundaryLoadDirection) {
        switch direction {
        case .older:
            olderBoundaryLoadTask = nil
        case .newer:
            newerBoundaryLoadTask = nil
        }
    }

    private func boundaryLoadTask(
        direction: TimelineBoundaryLoadDirection
    ) -> Task<Void, Never>? {
        switch direction {
        case .older:
            return olderBoundaryLoadTask
        case .newer:
            return newerBoundaryLoadTask
        }
    }

    private func boundaryTimestamp(
        direction: TimelineBoundaryLoadDirection
    ) -> Date? {
        switch direction {
        case .older:
            return oldestLoadedTimestamp
        case .newer:
            return newestLoadedTimestamp
        }
    }

    private func effectiveBoundaryLoadTrigger(
        from requestedTrigger: TimelineBoundaryLoadTrigger
    ) -> (
        trigger: TimelineBoundaryLoadTrigger,
        shouldScheduleOlder: Bool,
        shouldScheduleNewer: Bool,
        hasPendingOlderTask: Bool,
        hasPendingNewerTask: Bool
    ) {
        let hasPendingOlderTask = boundaryLoadTask(direction: .older) != nil
        let hasPendingNewerTask = boundaryLoadTask(direction: .newer) != nil
        let olderSchedulable = requestedTrigger.older &&
            !hasPendingOlderTask &&
            boundaryTimestamp(direction: .older) != nil
        let newerSchedulable = requestedTrigger.newer &&
            !hasPendingNewerTask &&
            boundaryTimestamp(direction: .newer) != nil

        return (
            trigger: TimelineBoundaryLoadTrigger(
                older: olderSchedulable || hasPendingOlderTask,
                newer: newerSchedulable || hasPendingNewerTask
            ),
            shouldScheduleOlder: olderSchedulable,
            shouldScheduleNewer: newerSchedulable,
            hasPendingOlderTask: hasPendingOlderTask,
            hasPendingNewerTask: hasPendingNewerTask
        )
    }

    func cancelBoundaryLoadTasks() -> (hadOlder: Bool, hadNewer: Bool) {
        let hadOlder = olderBoundaryLoadTask != nil
        let hadNewer = newerBoundaryLoadTask != nil

        olderBoundaryLoadTask?.cancel()
        newerBoundaryLoadTask?.cancel()
        olderBoundaryLoadTask = nil
        newerBoundaryLoadTask = nil
        resetBoundaryLoadState()

        return (hadOlder, hadNewer)
    }

    @discardableResult
    func cancelBoundaryLoadTasks(reason: String) -> (hadOlder: Bool, hadNewer: Bool) {
        let cancelled = cancelBoundaryLoadTasks()

        if cancelled.hadOlder || cancelled.hadNewer {
            Log.debug(
                "[InfiniteScroll] Cancelled boundary tasks (\(reason)) older=\(cancelled.hadOlder) newer=\(cancelled.hadNewer)",
                category: .ui
            )
        }

        return cancelled
    }

    func captureBoundaryLoadContext(
        direction: TimelineBoundaryLoadDirection,
        filters: FilterCriteria,
        frames: [TimelineFrame]
    ) -> TimelineBoundaryLoadContext? {
        let boundaryFrameID: FrameID?
        switch direction {
        case .older:
            boundaryFrameID = frames.first?.frame.id
        case .newer:
            boundaryFrameID = frames.last?.frame.id
        }

        guard let boundaryFrameID else { return nil }
        return TimelineBoundaryLoadContext(
            generation: boundaryLoadContextGeneration,
            filters: filters,
            boundaryFrameID: boundaryFrameID
        )
    }

    @MainActor
    private func summarizeBoundaryLoadContextForLog(
        _ context: TimelineBoundaryLoadContext,
        summarizeFilters: @MainActor (FilterCriteria) -> String
    ) -> String {
        "generation=\(context.generation) boundaryFrameID=\(context.boundaryFrameID.value) filters={\(summarizeFilters(context.filters))}"
    }

    @MainActor
    func isBoundaryLoadContextCurrent(
        direction: TimelineBoundaryLoadDirection,
        requestContext: TimelineBoundaryLoadContext,
        reason: String,
        filters: FilterCriteria,
        frames: [TimelineFrame],
        summarizeFilters: @MainActor (FilterCriteria) -> String
    ) -> Bool {
        let label = direction.label
        guard let currentContext = captureBoundaryLoadContext(
            direction: direction,
            filters: filters,
            frames: frames
        ) else {
            Log.info(
                "[\(label)] ABORT reason=\(reason) staleResult=frameBufferClearedWhileLoading",
                category: .ui
            )
            return false
        }

        if requestContext != currentContext {
            Log.info(
                "[\(label)] ABORT reason=\(reason) staleResult=contextChanged old={\(summarizeBoundaryLoadContextForLog(requestContext, summarizeFilters: summarizeFilters))} current={\(summarizeBoundaryLoadContextForLog(currentContext, summarizeFilters: summarizeFilters))}",
                category: .ui
            )
            return false
        }

        return true
    }

    func beginBoundaryLoad(
        direction: TimelineBoundaryLoadDirection,
        filters: FilterCriteria,
        frames: [TimelineFrame]
    ) -> (timestamp: Date, requestContext: TimelineBoundaryLoadContext)? {
        let boundaryTimestamp: Date?
        switch direction {
        case .older:
            guard !isLoadingOlder else { return nil }
            boundaryTimestamp = oldestLoadedTimestamp
        case .newer:
            guard !isLoadingNewer else { return nil }
            boundaryTimestamp = newestLoadedTimestamp
        }

        guard let boundaryTimestamp,
              let requestContext = captureBoundaryLoadContext(
                direction: direction,
                filters: filters,
                frames: frames
              ) else {
            return nil
        }

        switch direction {
        case .older:
            isLoadingOlder = true
        case .newer:
            isLoadingNewer = true
        }

        return (boundaryTimestamp, requestContext)
    }

    func finishBoundaryLoad(direction: TimelineBoundaryLoadDirection) {
        clearBoundaryLoadTask(direction: direction)
        switch direction {
        case .older:
            isLoadingOlder = false
        case .newer:
            isLoadingNewer = false
        }
    }

    @discardableResult
    func checkAndScheduleBoundaryLoads(
        currentIndex: Int,
        frameCount: Int,
        loadThreshold: Int,
        reason: String,
        isActivelyScrolling: Bool,
        subFrameOffset: Double,
        cmdFTraceID: String?,
        olderTask: @autoclosure () -> Task<Void, Never>,
        newerTask: @autoclosure () -> Task<Void, Never>
    ) -> TimelineBoundaryLoadTrigger {
        let loadTrigger = TimelineFrameWindowSupport.boundaryLoadTrigger(
            currentIndex: currentIndex,
            frameCount: frameCount,
            loadThreshold: loadThreshold,
            hasMoreOlder: hasMoreOlder,
            hasMoreNewer: hasMoreNewer,
            isLoadingOlder: isLoadingOlder,
            isLoadingNewer: isLoadingNewer
        )
        let effectiveTrigger = effectiveBoundaryLoadTrigger(from: loadTrigger)
        let maxIndex = max(frameCount - 1, 0)

        if let cmdFTraceID {
            Log.info(
                "[CmdFPerf][\(cmdFTraceID)] Boundary check reason=\(reason) index=\(currentIndex)/\(maxIndex) threshold=\(loadThreshold) loadOlder=\(effectiveTrigger.trigger.older) loadNewer=\(effectiveTrigger.trigger.newer)",
                category: .ui
            )
        }

        if effectiveTrigger.trigger.any {
            Log.info(
                "[BOUNDARY-CHECK] reason=\(reason) index=\(currentIndex)/\(maxIndex) loadOlder=\(effectiveTrigger.trigger.older) loadNewer=\(effectiveTrigger.trigger.newer) hasMoreOlder=\(hasMoreOlder) hasMoreNewer=\(hasMoreNewer) isLoadingOlder=\(isLoadingOlder) isLoadingNewer=\(isLoadingNewer) pendingOlderTask=\(effectiveTrigger.hasPendingOlderTask) pendingNewerTask=\(effectiveTrigger.hasPendingNewerTask) hasOlderTimestamp=\(oldestLoadedTimestamp != nil) hasNewerTimestamp=\(newestLoadedTimestamp != nil) isActivelyScrolling=\(isActivelyScrolling) subFrameOffset=\(String(format: "%.1f", subFrameOffset))",
                category: .ui
            )
        }

        if effectiveTrigger.shouldScheduleOlder {
            replaceBoundaryLoadTask(direction: .older, task: olderTask())
        }

        if effectiveTrigger.shouldScheduleNewer {
            replaceBoundaryLoadTask(direction: .newer, task: newerTask())
        }

        return effectiveTrigger.trigger
    }

    func resetBoundaryStateForReloadWindow() {
        hasMoreOlder = true
        hasMoreNewer = true
        hasReachedAbsoluteStart = false
        hasReachedAbsoluteEnd = false
    }

    func setTerminalBoundaryState() {
        hasMoreOlder = false
        hasMoreNewer = false
        hasReachedAbsoluteStart = true
        hasReachedAbsoluteEnd = true
    }

    func markReachedAbsoluteStart() {
        hasMoreOlder = false
        hasReachedAbsoluteStart = true
    }

    func markReachedAbsoluteEnd() {
        hasMoreNewer = false
        hasReachedAbsoluteEnd = true
    }

    func completeOlderBoundaryReachedStart(
        reason: String,
        skippedDueToNoOverlap: Bool,
        queryElapsedMs: Double?,
        loadStartedAt: CFAbsoluteTime,
        cmdFTraceID: String?,
        cmdFTraceStartedAt: CFAbsoluteTime?
    ) {
        markReachedAbsoluteStart()
        if !skippedDueToNoOverlap {
            Log.debug("[InfiniteScroll] No more older frames available - reached absolute start", category: .ui)
        }

        guard let queryElapsedMs, let cmdFTraceID else { return }
        let loadElapsedMs = (CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000
        let totalFromShortcutMs = cmdFTraceStartedAt.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? loadElapsedMs
        Log.recordLatency(
            "timeline.cmdf.quick_filter.boundary.older_ms",
            valueMs: loadElapsedMs,
            category: .ui,
            summaryEvery: 5,
            warningThresholdMs: 220,
            criticalThresholdMs: 500
        )
        Log.info(
            "[CmdFPerf][\(cmdFTraceID)] Boundary older load complete (empty) reason=\(reason) query=\(String(format: "%.1f", queryElapsedMs))ms load=\(String(format: "%.1f", loadElapsedMs))ms total=\(String(format: "%.1f", totalFromShortcutMs))ms",
            category: .ui
        )
    }

    func completeNewerBoundaryReachedEndEmpty(
        reason: String,
        queryElapsedMs: Double,
        loadStartedAt: CFAbsoluteTime,
        cmdFTraceID: String?,
        cmdFTraceStartedAt: CFAbsoluteTime?
    ) {
        Log.debug("[InfiniteScroll] No more newer frames available - reached absolute end", category: .ui)
        markReachedAbsoluteEnd()

        guard let cmdFTraceID else { return }
        let loadElapsedMs = (CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000
        let totalFromShortcutMs = cmdFTraceStartedAt.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? loadElapsedMs
        Log.recordLatency(
            "timeline.cmdf.quick_filter.boundary.newer_ms",
            valueMs: loadElapsedMs,
            category: .ui,
            summaryEvery: 5,
            warningThresholdMs: 220,
            criticalThresholdMs: 500
        )
        Log.info(
            "[CmdFPerf][\(cmdFTraceID)] Boundary newer load complete (empty) reason=\(reason) query=\(String(format: "%.1f", queryElapsedMs))ms load=\(String(format: "%.1f", loadElapsedMs))ms total=\(String(format: "%.1f", totalFromShortcutMs))ms",
            category: .ui
        )
    }

    func completeNewerBoundaryReachedEndDuplicateOnly(
        reason: String,
        newestTimestamp: Date,
        duplicateOnlyResult: TimelineNewerBoundaryDuplicateOnlyResult
    ) {
        Log.warning(
            "[BoundaryNewer] Duplicate-only result reason=\(reason) count=\(duplicateOnlyResult.attemptedFrameCount) newestFrameID=\(duplicateOnlyResult.newestFrameID) duplicateFrameID=\(duplicateOnlyResult.duplicateFrameID) newestTs=\(Log.timestamp(from: newestTimestamp)); marking end to stop retry loop",
            category: .ui
        )
        markReachedAbsoluteEnd()
    }

    func restoreMoreOlderAfterTrim() {
        hasMoreOlder = true
        hasReachedAbsoluteStart = false
    }

    func restoreMoreNewerAfterTrim() {
        hasMoreNewer = true
        hasReachedAbsoluteEnd = false
    }

    func applyTrimMutation(_ mutation: TimelineFrameWindowTrimMutationResult) {
        if let targetIndex = mutation.pendingCurrentIndexAfterFrameReplacement {
            setPendingCurrentIndexAfterFrameReplacement(targetIndex)
        }

        switch mutation.boundaryToRestoreAfterTrim {
        case .older:
            restoreMoreOlderAfterTrim()
        case .newer:
            restoreMoreNewerAfterTrim()
        }

        setWindowBoundaries(
            oldest: mutation.oldestTimestamp,
            newest: mutation.newestTimestamp
        )
    }

    func prepareFrameReplacement(currentIndex: Int, oldest: Date?, newest: Date?) {
        setPendingCurrentIndexAfterFrameReplacement(currentIndex)
        setWindowBoundaries(oldest: oldest, newest: newest)
    }

    func prepareWindowReplacement(
        frames: [TimelineFrame],
        currentIndex: Int,
        resetBoundaryState: Bool = true
    ) -> TimelinePreparedFrameWindowReplacement {
        prepareFrameReplacement(
            currentIndex: currentIndex,
            oldest: frames.first?.frame.timestamp,
            newest: frames.last?.frame.timestamp
        )
        if resetBoundaryState {
            resetBoundaryStateForReloadWindow()
        }
        return TimelinePreparedFrameWindowReplacement(
            frames: frames,
            resultingCurrentIndex: currentIndex
        )
    }

    func prepareMostRecentWindow(
        from framesWithVideoInfo: [FrameWithVideoInfo]
    ) -> TimelinePreparedFrameWindowReplacement {
        let frames = framesWithVideoInfo.reversed().map { TimelineFrame(frameWithVideoInfo: $0) }
        return prepareWindowReplacement(
            frames: frames,
            currentIndex: max(0, frames.count - 1)
        )
    }
}
