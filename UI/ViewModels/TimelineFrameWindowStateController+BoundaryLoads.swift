import Foundation
import Shared

extension TimelineFrameWindowStateController {
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
        guard let boundaryLoad = beginBoundaryLoad(
            direction: .older,
            filters: filters,
            frames: frames
        ) else { return nil }
        defer { finishBoundaryLoad(direction: .older) }
        guard !Task.isCancelled else { return nil }

        let oldestTimestamp = boundaryLoad.timestamp
        let requestContext = boundaryLoad.requestContext
        let requestFilters = requestContext.filters
        let loadStart = CFAbsoluteTimeGetCurrent()
        TimelineBoundaryLoadCompletionSupport.logOlderBoundaryLoadStarted(
            reason: reason,
            oldestTimestamp: oldestTimestamp,
            cmdFTraceID: cmdFTraceID
        )

        do {
            let pageOutcome = try await TimelineBoundaryPageLoader.loadOlderPage(
                oldestTimestamp: oldestTimestamp,
                requestFilters: requestFilters,
                reason: reason,
                loadWindowSpanSeconds: loadWindowSpanSeconds,
                loadBatchSize: loadBatchSize,
                olderSparseRetryThreshold: olderSparseRetryThreshold,
                nearestFallbackBatchSize: nearestFallbackBatchSize,
                fetchFramesBefore: fetchFramesBefore
            )

            if Task.isCancelled {
                return nil
            }

            let latestFilters = currentFilters()
            let latestFrames = currentFrames()
            guard isBoundaryLoadContextCurrent(
                direction: .older,
                requestContext: requestContext,
                reason: reason,
                filters: latestFilters,
                frames: latestFrames,
                summarizeFilters: summarizeFilters
            ) else {
                return nil
            }

            switch TimelineBoundaryPageApplySupport.prepareOlderLoadOutcome(
                pageOutcome: pageOutcome,
                existingFrames: frames,
                currentIndex: currentIndex
            ) {
            case let .reachedStart(skippedDueToNoOverlap, queryElapsedMs):
                completeOlderBoundaryReachedStart(
                    reason: reason,
                    skippedDueToNoOverlap: skippedDueToNoOverlap,
                    queryElapsedMs: queryElapsedMs,
                    loadStartedAt: loadStart,
                    cmdFTraceID: cmdFTraceID,
                    cmdFTraceStartedAt: cmdFTraceStartedAt
                )
                return nil

            case let .apply(load):
                return applyOlderBoundaryPreparedLoad(
                    reason: reason,
                    existingFrames: frames,
                    currentIndex: currentIndex,
                    oldFirstTimestamp: oldestTimestamp,
                    preparedLoad: load,
                    maxFrames: maxFrames,
                    frameBufferCount: frameBufferCount,
                    loadStartedAt: loadStart,
                    cmdFTraceID: cmdFTraceID,
                    cmdFTraceStartedAt: cmdFTraceStartedAt,
                    memoryLogger: memoryLogger
                )
            }
        } catch {
            TimelineBoundaryLoadCompletionSupport.logBoundaryLoadFailure(
                direction: .older,
                reason: reason,
                error: error,
                loadStartedAt: loadStart,
                cmdFTraceID: cmdFTraceID
            )
            return nil
        }
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
        guard let boundaryLoad = beginBoundaryLoad(
            direction: .newer,
            filters: filters,
            frames: frames
        ) else { return nil }
        defer { finishBoundaryLoad(direction: .newer) }
        guard !Task.isCancelled else { return nil }

        let newestTimestamp = boundaryLoad.timestamp
        let requestContext = boundaryLoad.requestContext
        let requestFilters = requestContext.filters
        let loadStart = CFAbsoluteTimeGetCurrent()
        TimelineBoundaryLoadCompletionSupport.logNewerBoundaryLoadStarted(
            reason: reason,
            newestTimestamp: newestTimestamp,
            currentIndex: currentIndex,
            frameCount: frames.count,
            hasMoreNewer: hasMoreNewer,
            isActivelyScrolling: isActivelyScrolling,
            subFrameOffset: currentSubFrameOffset,
            cmdFTraceID: cmdFTraceID
        )

        do {
            let pageResult = try await TimelineBoundaryPageLoader.loadNewerPage(
                newestTimestamp: newestTimestamp,
                requestFilters: requestFilters,
                reason: reason,
                loadWindowSpanSeconds: loadWindowSpanSeconds,
                loadBatchSize: loadBatchSize,
                newerSparseRetryThreshold: newerSparseRetryThreshold,
                nearestFallbackBatchSize: nearestFallbackBatchSize,
                fetchFramesInRange: fetchFramesInRange,
                fetchFramesAfter: fetchFramesAfter
            )

            if Task.isCancelled {
                return nil
            }

            let latestFilters = currentFilters()
            let latestFrames = currentFrames()
            guard isBoundaryLoadContextCurrent(
                direction: .newer,
                requestContext: requestContext,
                reason: reason,
                filters: latestFilters,
                frames: latestFrames,
                summarizeFilters: summarizeFilters
            ) else {
                return nil
            }

            switch TimelineBoundaryPageApplySupport.prepareNewerLoadOutcome(
                pageResult: pageResult,
                existingFrames: frames,
                currentIndex: currentIndex,
                shouldTrackNewestWhenAtEdge: shouldTrackNewestWhenAtEdge
            ) {
            case let .reachedEndEmpty(queryElapsedMs):
                completeNewerBoundaryReachedEndEmpty(
                    reason: reason,
                    queryElapsedMs: queryElapsedMs,
                    loadStartedAt: loadStart,
                    cmdFTraceID: cmdFTraceID,
                    cmdFTraceStartedAt: cmdFTraceStartedAt
                )
                return nil

            case let .reachedEndDuplicateOnly(duplicateOnlyResult, _):
                completeNewerBoundaryReachedEndDuplicateOnly(
                    reason: reason,
                    newestTimestamp: newestTimestamp,
                    duplicateOnlyResult: duplicateOnlyResult
                )
                return nil

            case let .apply(load):
                return applyNewerBoundaryPreparedLoad(
                    reason: reason,
                    existingFrames: frames,
                    currentIndex: currentIndex,
                    oldLastTimestamp: frames.last?.frame.timestamp,
                    preparedLoad: load,
                    maxFrames: maxFrames,
                    currentFrame: currentFrame,
                    frameBufferCount: frameBufferCount,
                    hasMoreNewer: hasMoreNewer,
                    isActivelyScrolling: isActivelyScrolling,
                    currentSubFrameOffset: currentSubFrameOffset,
                    loadStartedAt: loadStart,
                    cmdFTraceID: cmdFTraceID,
                    cmdFTraceStartedAt: cmdFTraceStartedAt,
                    memoryLogger: memoryLogger
                )
            }
        } catch {
            TimelineBoundaryLoadCompletionSupport.logBoundaryLoadFailure(
                direction: .newer,
                reason: reason,
                error: error,
                loadStartedAt: loadStart,
                cmdFTraceID: cmdFTraceID
            )
            return nil
        }
    }

    func applyOlderBoundaryPreparedLoad(
        reason: String,
        existingFrames: [TimelineFrame],
        currentIndex: Int,
        oldFirstTimestamp: Date,
        preparedLoad: TimelineOlderBoundaryPreparedLoad,
        maxFrames: Int,
        frameBufferCount: Int,
        loadStartedAt: CFAbsoluteTime,
        cmdFTraceID: String?,
        cmdFTraceStartedAt: CFAbsoluteTime?,
        memoryLogger: (String, Int, Int, Date?, Date?) -> Void
    ) -> TimelineBoundaryAppliedLoad {
        Log.debug("[InfiniteScroll] Got \(preparedLoad.applyPlan.addedFrames.count) older frames", category: .ui)

        let applyPlan = preparedLoad.applyPlan
        if applyPlan.clampedPreviousIndex != currentIndex {
            Log.warning(
                "[BoundaryOlder] Clamping invalid currentIndex reason=\(reason) oldIndex=\(currentIndex) frameCount=\(existingFrames.count) clamped=\(applyPlan.clampedPreviousIndex)",
                category: .ui
            )
        }

        let applyResult = TimelineBoundaryLoadCompletionSupport.prepareOlderApplyResult(
            existingFrames: existingFrames,
            currentIndex: currentIndex,
            oldFirstTimestamp: oldFirstTimestamp,
            preparedLoad: preparedLoad
        )
        let completionSummary = applyResult.completionSummary
        let mutationResult = applyResult.mutationResult

        prepareFrameReplacement(
            currentIndex: mutationResult.currentIndex,
            oldest: mutationResult.oldestTimestamp,
            newest: mutationResult.newestTimestamp
        )

        TimelineBoundaryLoadCompletionSupport.logOlderApplied(
            reason: reason,
            completionSummary: completionSummary,
            mutationResult: mutationResult,
            frameBufferCount: frameBufferCount,
            memoryLogger: memoryLogger
        )

        if let cmdFTraceID, let cmdFTraceStartedAt {
            TimelineBoundaryLoadCompletionSupport.logOlderCmdFCompletion(
                traceID: cmdFTraceID,
                reason: reason,
                queryElapsedMs: preparedLoad.queryElapsedMs,
                loadStartedAt: loadStartedAt,
                traceStartedAt: cmdFTraceStartedAt,
                addedCount: completionSummary.addedCount
            )
        }

        let finalFrames = finalizeBoundaryFramesAfterTrimIfNeeded(
            frames: mutationResult.frames,
            preserveDirection: .older,
            currentIndex: mutationResult.currentIndex,
            maxFrames: maxFrames,
            isActivelyScrolling: false,
            currentFrame: nil,
            reason: reason,
            frameBufferCount: frameBufferCount,
            memoryLogger: memoryLogger
        )

        return TimelineBoundaryAppliedLoad(
            frames: finalFrames,
            resultingSubFrameOffset: nil,
            cmdFPlayheadEvent: "boundary.older.indexAdjusted",
            cmdFPlayheadExtra: "reason=\(reason) oldIndex=\(completionSummary.previousIndex) added=\(completionSummary.addedCount)"
        )
    }

    func applyNewerBoundaryPreparedLoad(
        reason: String,
        existingFrames: [TimelineFrame],
        currentIndex: Int,
        oldLastTimestamp: Date?,
        preparedLoad: TimelineNewerBoundaryPreparedLoad,
        maxFrames: Int,
        currentFrame: TimelineFrame?,
        frameBufferCount: Int,
        hasMoreNewer: Bool,
        isActivelyScrolling: Bool,
        currentSubFrameOffset: Double,
        loadStartedAt: CFAbsoluteTime,
        cmdFTraceID: String?,
        cmdFTraceStartedAt: CFAbsoluteTime?,
        memoryLogger: (String, Int, Int, Date?, Date?) -> Void
    ) -> TimelineBoundaryAppliedLoad {
        Log.debug("[InfiniteScroll] Got \(preparedLoad.requestedFrameCount) newer frames", category: .ui)

        let appendPlan = preparedLoad.applyPlan
        if appendPlan.duplicateCount > 0 {
            Log.warning(
                "[BoundaryNewer] Dropping \(appendPlan.duplicateCount)/\(preparedLoad.requestedFrameCount) duplicate frame(s) reason=\(reason)",
                category: .ui
            )
        }

        let previousNewestBlock = TimelineFrameWindowBlockSupport.newestEdgeBlockSummary(in: existingFrames)
        let applyResult = TimelineBoundaryLoadCompletionSupport.prepareNewerApplyResult(
            existingFrames: existingFrames,
            currentIndex: currentIndex,
            oldLastTimestamp: oldLastTimestamp,
            preparedLoad: preparedLoad
        )
        let completionSummary = applyResult.completionSummary
        let mutationResult = applyResult.mutationResult

        prepareFrameReplacement(
            currentIndex: mutationResult.currentIndex,
            oldest: mutationResult.oldestTimestamp,
            newest: mutationResult.newestTimestamp
        )

        let resultingSubFrameOffset = mutationResult.shouldResetSubFrameOffset ? 0 : currentSubFrameOffset
        let currentNewestBlock = TimelineFrameWindowBlockSupport.newestEdgeBlockSummary(in: mutationResult.frames)
        TimelineBoundaryLoadCompletionSupport.logNewerApplied(
            reason: reason,
            completionSummary: completionSummary,
            mutationResult: mutationResult,
            frameBufferCount: frameBufferCount,
            memoryLogger: memoryLogger,
            hasMoreNewer: hasMoreNewer,
            isActivelyScrolling: isActivelyScrolling,
            previousSubFrameOffset: currentSubFrameOffset,
            currentSubFrameOffset: resultingSubFrameOffset,
            previousNewestBlock: previousNewestBlock,
            currentNewestBlock: currentNewestBlock
        )

        if let cmdFTraceID, let cmdFTraceStartedAt {
            TimelineBoundaryLoadCompletionSupport.logNewerCmdFCompletion(
                traceID: cmdFTraceID,
                reason: reason,
                queryElapsedMs: preparedLoad.queryElapsedMs,
                loadStartedAt: loadStartedAt,
                traceStartedAt: cmdFTraceStartedAt,
                addedCount: completionSummary.addedCount
            )
        }

        let finalFrames = finalizeBoundaryFramesAfterTrimIfNeeded(
            frames: mutationResult.frames,
            preserveDirection: .newer,
            currentIndex: mutationResult.currentIndex,
            maxFrames: maxFrames,
            isActivelyScrolling: isActivelyScrolling,
            currentFrame: currentFrame,
            reason: reason,
            frameBufferCount: frameBufferCount,
            memoryLogger: memoryLogger
        )

        return TimelineBoundaryAppliedLoad(
            frames: finalFrames,
            resultingSubFrameOffset: mutationResult.shouldResetSubFrameOffset ? 0 : nil,
            cmdFPlayheadEvent: "boundary.newer.appended",
            cmdFPlayheadExtra: "reason=\(reason) added=\(completionSummary.addedCount) pinnedToNewest=\(completionSummary.didPinToNewest)"
        )
    }
}
