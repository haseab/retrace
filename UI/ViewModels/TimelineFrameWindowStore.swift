import Foundation
import Shared

final class TimelineFrameWindowStore {
    let state = TimelineFrameWindowStateController()

    var oldestLoadedTimestamp: Date? { state.oldestLoadedTimestamp }
    var newestLoadedTimestamp: Date? { state.newestLoadedTimestamp }
    var hasMoreOlder: Bool { state.hasMoreOlder }
    var hasMoreNewer: Bool { state.hasMoreNewer }
    var hasReachedAbsoluteStart: Bool { state.hasReachedAbsoluteStart }
    var hasReachedAbsoluteEnd: Bool { state.hasReachedAbsoluteEnd }
    var isLoadingOlder: Bool { state.isLoadingOlder }
    var isLoadingNewer: Bool { state.isLoadingNewer }

    func consumePendingCurrentIndexAfterFrameReplacement() -> Int? {
        state.consumePendingCurrentIndexAfterFrameReplacement()
    }

    @MainActor
    func applyFilteredEmptyState(context: String) {
        state.cancelBoundaryLoadTasks(reason: "filteredEmpty.\(context)")
        state.setPendingCurrentIndexAfterFrameReplacement(nil)
        state.setTerminalBoundaryState()
    }

    @MainActor
    func restoreSnapshotState(
        frames: [TimelineFrame],
        currentIndex: Int,
        hasMoreOlder: Bool,
        hasMoreNewer: Bool
    ) {
        state.cancelBoundaryLoadTasks(reason: "restoreTimelineState")
        state.prepareFrameReplacement(
            currentIndex: currentIndex,
            oldest: frames.first?.frame.timestamp,
            newest: frames.last?.frame.timestamp
        )
        state.hasMoreOlder = hasMoreOlder
        state.hasMoreNewer = hasMoreNewer
        state.hasReachedAbsoluteStart = !hasMoreOlder
        state.hasReachedAbsoluteEnd = !hasMoreNewer
    }

    @MainActor
    func prepareNavigationWindowReplacement(
        reason: String,
        frames: [TimelineFrame],
        currentIndex: Int
    ) -> TimelinePreparedFrameWindowReplacement {
        state.cancelBoundaryLoadTasks(reason: reason)
        return state.prepareWindowReplacement(
            frames: frames,
            currentIndex: currentIndex
        )
    }

    @MainActor
    func prepareMostRecentWindowReplacement(
        reason: String,
        from framesWithVideoInfo: [FrameWithVideoInfo]
    ) -> TimelinePreparedFrameWindowReplacement {
        state.cancelBoundaryLoadTasks(reason: reason)
        return state.prepareMostRecentWindow(from: framesWithVideoInfo)
    }

    func setBoundaryPaginationState(hasMoreOlder: Bool, hasMoreNewer: Bool) {
        state.hasMoreOlder = hasMoreOlder
        state.hasMoreNewer = hasMoreNewer
    }

    func boundaryPaginationState() -> (
        hasMoreOlder: Bool,
        hasMoreNewer: Bool,
        hasReachedAbsoluteStart: Bool,
        hasReachedAbsoluteEnd: Bool
    ) {
        (
            state.hasMoreOlder,
            state.hasMoreNewer,
            state.hasReachedAbsoluteStart,
            state.hasReachedAbsoluteEnd
        )
    }

    func updateWindowBoundaries(frames: [TimelineFrame]) {
        state.updateWindowBoundaries(frames: frames)
    }

    func cancelBoundaryLoadTasks(reason: String) {
        state.cancelBoundaryLoadTasks(reason: reason)
    }

    func updateDeferredTrimAnchorIfNeeded(
        isActivelyScrolling: Bool,
        currentFrame: TimelineFrame?
    ) {
        state.updateDeferredTrimAnchorIfNeeded(
            isActivelyScrolling: isActivelyScrolling,
            currentFrame: currentFrame
        )
    }

    func handleDeferredTrimIfNeeded(
        trigger: String,
        frames: [TimelineFrame],
        currentIndex: Int,
        maxFrames: Int,
        currentFrame: TimelineFrame?
    ) -> TimelineFrameWindowHandledTrimOutcome? {
        state.handleDeferredTrimIfNeeded(
            trigger: trigger,
            frames: frames,
            currentIndex: currentIndex,
            maxFrames: maxFrames,
            currentFrame: currentFrame
        )
    }

    func removeFrame(
        at index: Int,
        from existingFrames: [TimelineFrame],
        currentIndex: Int
    ) -> TimelineOptimisticFrameWindowMutationResult {
        state.removeFrame(
            at: index,
            from: existingFrames,
            currentIndex: currentIndex
        )
    }

    func removeFrames(
        matching segmentIDs: Set<SegmentID>,
        from existingFrames: [TimelineFrame],
        currentIndex: Int,
        preserveCurrentFrameID: FrameID?
    ) -> TimelineOptimisticFrameWindowMutationResult {
        state.removeFrames(
            matching: segmentIDs,
            from: existingFrames,
            currentIndex: currentIndex,
            preserveCurrentFrameID: preserveCurrentFrameID
        )
    }

    func restoreFrames(
        _ restoredFrames: [TimelineFrame],
        at insertIndex: Int,
        into existingFrames: [TimelineFrame],
        previousCurrentIndex: Int,
        previousSelectedFrameIndex: Int?
    ) -> TimelineOptimisticFrameWindowMutationResult {
        state.restoreFrames(
            restoredFrames,
            at: insertIndex,
            into: existingFrames,
            previousCurrentIndex: previousCurrentIndex,
            previousSelectedFrameIndex: previousSelectedFrameIndex
        )
    }

    func applyRefreshAppendMutation(
        _ result: TimelineRefreshAppendMutationResult,
        maxFrames: Int,
        isActivelyScrolling: Bool,
        frameBufferCount: Int,
        memoryLogger: (String, Int, Int, Date?, Date?) -> Void
    ) -> TimelinePreparedFrameWindowReplacement {
        state.applyRefreshAppendMutation(
            result,
            maxFrames: maxFrames,
            isActivelyScrolling: isActivelyScrolling,
            frameBufferCount: frameBufferCount,
            memoryLogger: memoryLogger
        )
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
        state.checkAndScheduleBoundaryLoads(
            currentIndex: currentIndex,
            frameCount: frameCount,
            loadThreshold: loadThreshold,
            reason: reason,
            isActivelyScrolling: isActivelyScrolling,
            subFrameOffset: subFrameOffset,
            cmdFTraceID: cmdFTraceID,
            olderTask: olderTask(),
            newerTask: newerTask()
        )
    }

    @MainActor
    func loadOlderBoundary(
        reason: String,
        filters: FilterCriteria,
        frames: [TimelineFrame],
        currentIndex: Int,
        maxFrames: Int,
        loadWindowSpanSeconds: TimeInterval,
        loadBatchSize: Int,
        olderSparseRetryThreshold: Int,
        nearestFallbackBatchSize: Int,
        summarizeFilters: @MainActor (FilterCriteria) -> String,
        currentFilters: @MainActor () -> FilterCriteria,
        currentFrames: @MainActor () -> [TimelineFrame],
        fetchFramesBefore: (Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo],
        frameBufferCount: Int,
        cmdFTraceID: String?,
        cmdFTraceStartedAt: CFAbsoluteTime?,
        memoryLogger: (String, Int, Int, Date?, Date?) -> Void
    ) async -> TimelineBoundaryAppliedLoad? {
        await state.loadOlderBoundary(
            reason: reason,
            filters: filters,
            frames: frames,
            currentIndex: currentIndex,
            maxFrames: maxFrames,
            loadWindowSpanSeconds: loadWindowSpanSeconds,
            loadBatchSize: loadBatchSize,
            olderSparseRetryThreshold: olderSparseRetryThreshold,
            nearestFallbackBatchSize: nearestFallbackBatchSize,
            summarizeFilters: summarizeFilters,
            currentFilters: currentFilters,
            currentFrames: currentFrames,
            fetchFramesBefore: fetchFramesBefore,
            frameBufferCount: frameBufferCount,
            cmdFTraceID: cmdFTraceID,
            cmdFTraceStartedAt: cmdFTraceStartedAt,
            memoryLogger: memoryLogger
        )
    }

    @MainActor
    func loadNewerBoundary(
        reason: String,
        filters: FilterCriteria,
        frames: [TimelineFrame],
        currentIndex: Int,
        shouldTrackNewestWhenAtEdge: Bool,
        isActivelyScrolling: Bool,
        currentSubFrameOffset: Double,
        maxFrames: Int,
        currentFrame: TimelineFrame?,
        loadWindowSpanSeconds: TimeInterval,
        loadBatchSize: Int,
        newerSparseRetryThreshold: Int,
        nearestFallbackBatchSize: Int,
        summarizeFilters: @MainActor (FilterCriteria) -> String,
        currentFilters: @MainActor () -> FilterCriteria,
        currentFrames: @MainActor () -> [TimelineFrame],
        fetchFramesInRange: (Date, Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo],
        fetchFramesAfter: (Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo],
        frameBufferCount: Int,
        cmdFTraceID: String?,
        cmdFTraceStartedAt: CFAbsoluteTime?,
        memoryLogger: (String, Int, Int, Date?, Date?) -> Void
    ) async -> TimelineBoundaryAppliedLoad? {
        await state.loadNewerBoundary(
            reason: reason,
            filters: filters,
            frames: frames,
            currentIndex: currentIndex,
            shouldTrackNewestWhenAtEdge: shouldTrackNewestWhenAtEdge,
            isActivelyScrolling: isActivelyScrolling,
            currentSubFrameOffset: currentSubFrameOffset,
            maxFrames: maxFrames,
            currentFrame: currentFrame,
            loadWindowSpanSeconds: loadWindowSpanSeconds,
            loadBatchSize: loadBatchSize,
            newerSparseRetryThreshold: newerSparseRetryThreshold,
            nearestFallbackBatchSize: nearestFallbackBatchSize,
            summarizeFilters: summarizeFilters,
            currentFilters: currentFilters,
            currentFrames: currentFrames,
            fetchFramesInRange: fetchFramesInRange,
            fetchFramesAfter: fetchFramesAfter,
            frameBufferCount: frameBufferCount,
            cmdFTraceID: cmdFTraceID,
            cmdFTraceStartedAt: cmdFTraceStartedAt,
            memoryLogger: memoryLogger
        )
    }
}
