import Foundation
import Shared

enum TimelineFrameWindowSupport {
    static func makeBoundedBoundaryFilters(
        rangeStart: Date,
        rangeEnd: Date,
        criteria: FilterCriteria
    ) -> FilterCriteria? {
        var boundedFilters = criteria
        let effectiveStart = max(rangeStart, boundedFilters.startDate ?? rangeStart)
        let effectiveEnd = min(rangeEnd, boundedFilters.endDate ?? rangeEnd)

        guard effectiveStart <= effectiveEnd else {
            return nil
        }

        boundedFilters.startDate = effectiveStart
        boundedFilters.endDate = effectiveEnd
        return boundedFilters
    }

    static func boundaryLoadTrigger(
        currentIndex: Int,
        frameCount: Int,
        loadThreshold: Int,
        hasMoreOlder: Bool,
        hasMoreNewer: Bool,
        isLoadingOlder: Bool,
        isLoadingNewer: Bool
    ) -> TimelineBoundaryLoadTrigger {
        TimelineBoundaryLoadTrigger(
            older: currentIndex < loadThreshold && hasMoreOlder && !isLoadingOlder,
            newer: currentIndex > frameCount - loadThreshold && hasMoreNewer && !isLoadingNewer
        )
    }

    static func trim(
        frames: [TimelineFrame],
        preserveDirection: TimelineTrimDirection,
        currentIndex: Int,
        maxFrames: Int,
        anchorFrameID: FrameID?,
        anchorTimestamp: Date?
    ) -> TimelineFrameWindowTrimResult? {
        guard frames.count > maxFrames else { return nil }

        let excessCount = frames.count - maxFrames

        switch preserveDirection {
        case .older:
            return TimelineFrameWindowTrimResult(
                frames: Array(frames.dropLast(excessCount)),
                targetIndexAfterTrim: nil,
                excessCount: excessCount
            )

        case .newer:
            let trimmedFrames = Array(frames.dropFirst(excessCount))
            let targetIndexAfterTrim: Int

            if let anchorFrameID,
               let anchoredIndex = trimmedFrames.firstIndex(where: { $0.frame.id == anchorFrameID }) {
                targetIndexAfterTrim = anchoredIndex
            } else if let anchorTimestamp {
                targetIndexAfterTrim = trimmedFrames.enumerated().min {
                    abs($0.element.frame.timestamp.timeIntervalSince(anchorTimestamp))
                        < abs($1.element.frame.timestamp.timeIntervalSince(anchorTimestamp))
                }?.offset ?? max(0, currentIndex - excessCount)
            } else {
                targetIndexAfterTrim = max(0, currentIndex - excessCount)
            }

            return TimelineFrameWindowTrimResult(
                frames: trimmedFrames,
                targetIndexAfterTrim: targetIndexAfterTrim,
                excessCount: excessCount
            )
        }
    }
}

enum TimelineFrameWindowBlockSupport {
    static func newestEdgeBlockSummary(in frameList: [TimelineFrame]) -> TimelineEdgeBlockSummary? {
        guard !frameList.isEmpty else { return nil }

        let endIndex = frameList.count - 1
        let bundleID = frameList[endIndex].frame.metadata.appBundleID
        var startIndex = endIndex

        while startIndex > 0 {
            let current = frameList[startIndex]
            let previous = frameList[startIndex - 1]
            let appChanged = previous.frame.metadata.appBundleID != bundleID
            let hasSignificantGap = current.frame.timestamp.timeIntervalSince(previous.frame.timestamp) >= TimelineAppBlockBuilder.minimumGapThreshold
            if appChanged || hasSignificantGap {
                break
            }
            startIndex -= 1
        }

        return TimelineEdgeBlockSummary(
            bundleID: bundleID,
            startIndex: startIndex,
            endIndex: endIndex,
            frameCount: endIndex - startIndex + 1,
            startTimestamp: frameList[startIndex].frame.timestamp,
            endTimestamp: frameList[endIndex].frame.timestamp
        )
    }

    static func logNewestEdgeBlockTransition(
        context: String,
        reason: String,
        before: TimelineEdgeBlockSummary?,
        after: TimelineEdgeBlockSummary?,
        appendedCount: Int
    ) {
        guard let after else { return }

        if let before,
           before.bundleID == after.bundleID,
           after.frameCount > before.frameCount {
            let growth = after.frameCount - before.frameCount
            Log.info(
                "[TIMELINE-BLOCK] \(context) reason=\(reason) newestBlockGrewBy=\(growth) appended=\(appendedCount) before={\(summarizeEdgeBlock(before))} after={\(summarizeEdgeBlock(after))}",
                category: .ui
            )
            return
        }

        Log.info(
            "[TIMELINE-BLOCK] \(context) reason=\(reason) newestBlockChanged appended=\(appendedCount) before={\(summarizeEdgeBlock(before))} after={\(summarizeEdgeBlock(after))}",
            category: .ui
        )
    }

    static func describeEdgeBlock(_ block: TimelineEdgeBlockSummary?) -> String {
        summarizeEdgeBlock(block)
    }

    private static func summarizeEdgeBlock(_ block: TimelineEdgeBlockSummary?) -> String {
        guard let block else { return "none" }
        let bundle = block.bundleID ?? "nil"
        let start = Log.timestamp(from: block.startTimestamp)
        let end = Log.timestamp(from: block.endTimestamp)
        return "bundle=\(bundle) range=\(block.startIndex)-\(block.endIndex) frames=\(block.frameCount) ts=\(start)->\(end)"
    }
}

enum TimelineFrameWindowMutationSupport {
    static func applyOlder(
        existingFrames: [TimelineFrame],
        applyPlan: TimelineOlderBoundaryApplyPlan
    ) -> TimelineFrameWindowMutationResult {
        let frames = applyPlan.addedFrames + existingFrames
        return TimelineFrameWindowMutationResult(
            frames: frames,
            currentIndex: applyPlan.resultingCurrentIndex,
            oldestTimestamp: frames.first?.frame.timestamp,
            newestTimestamp: frames.last?.frame.timestamp,
            shouldResetSubFrameOffset: false
        )
    }

    static func applyNewer(
        existingFrames: [TimelineFrame],
        applyPlan: TimelineNewerBoundaryApplyPlan
    ) -> TimelineFrameWindowMutationResult {
        let frames = existingFrames + applyPlan.addedFrames
        return TimelineFrameWindowMutationResult(
            frames: frames,
            currentIndex: applyPlan.resultingCurrentIndex,
            oldestTimestamp: frames.first?.frame.timestamp,
            newestTimestamp: frames.last?.frame.timestamp,
            shouldResetSubFrameOffset: applyPlan.didPinToNewest
        )
    }
}

enum TimelineFrameWindowTrimSupport {
    static func directionLabel(_ direction: TimelineTrimDirection) -> String {
        switch direction {
        case .older:
            return "older"
        case .newer:
            return "newer"
        }
    }

    static func makeDeferredTrimDecision(
        frames: [TimelineFrame],
        preserveDirection: TimelineTrimDirection,
        maxFrames: Int,
        allowDeferral: Bool,
        isActivelyScrolling: Bool,
        currentFrame: TimelineFrame?,
        anchorFrameID: FrameID?,
        anchorTimestamp: Date?
    ) -> TimelineFrameWindowDeferredTrimDecision? {
        guard frames.count > maxFrames else { return nil }
        guard allowDeferral, preserveDirection == .newer, isActivelyScrolling else { return nil }

        return TimelineFrameWindowDeferredTrimDecision(
            anchorFrameID: anchorFrameID ?? currentFrame?.frame.id,
            anchorTimestamp: anchorTimestamp ?? currentFrame?.frame.timestamp
        )
    }

    static func prepareTrimOutcome(
        frames: [TimelineFrame],
        preserveDirection: TimelineTrimDirection,
        currentIndex: Int,
        maxFrames: Int,
        allowDeferral: Bool,
        isActivelyScrolling: Bool,
        currentFrame: TimelineFrame?,
        anchorFrameID: FrameID?,
        anchorTimestamp: Date?,
        reason: String
    ) -> TimelineFrameWindowTrimOutcome? {
        guard frames.count > maxFrames else { return nil }

        if let deferredDecision = makeDeferredTrimDecision(
            frames: frames,
            preserveDirection: preserveDirection,
            maxFrames: maxFrames,
            allowDeferral: allowDeferral,
            isActivelyScrolling: isActivelyScrolling,
            currentFrame: currentFrame,
            anchorFrameID: anchorFrameID,
            anchorTimestamp: anchorTimestamp
        ) {
            let anchorIDValue = deferredDecision.anchorFrameID?.value ?? -1
            let anchorTS = deferredDecision.anchorTimestamp.map { Log.timestamp(from: $0) } ?? "nil"
            return .deferred(
                TimelineFrameWindowDeferredTrimOutcome(
                    direction: preserveDirection,
                    anchorFrameID: deferredDecision.anchorFrameID,
                    anchorTimestamp: deferredDecision.anchorTimestamp,
                    logMessage: "[Memory] DEFERRING trim direction=\(directionLabel(preserveDirection)) reason=\(reason) frames=\(frames.count) anchorFrameID=\(anchorIDValue) anchorTs=\(anchorTS)"
                )
            )
        }

        guard let trimMutation = applyTrim(
            frames: frames,
            preserveDirection: preserveDirection,
            currentIndex: currentIndex,
            maxFrames: maxFrames,
            currentFrame: currentFrame,
            anchorFrameID: anchorFrameID,
            anchorTimestamp: anchorTimestamp
        ) else {
            return nil
        }

        let trimLogMessage: String
        let anchorLogMessage: String?
        switch preserveDirection {
        case .older:
            trimLogMessage = "[Memory] TRIMMING \(trimMutation.excessCount) newer frames from END (preserving older) reason=\(reason)"
            anchorLogMessage = nil

        case .newer:
            let oldIndex = currentIndex
            let targetIndexAfterTrim = trimMutation.pendingCurrentIndexAfterFrameReplacement ?? max(0, oldIndex)
            let anchorIDValue = trimMutation.resolvedAnchorFrameID?.value ?? -1
            let anchorTS = trimMutation.resolvedAnchorTimestamp.map { Log.timestamp(from: $0) } ?? "nil"
            trimLogMessage = "[Memory] TRIMMING \(trimMutation.excessCount) older frames from START (preserving newer) reason=\(reason)"
            anchorLogMessage = "[Memory] TRIM anchor result reason=\(reason) oldIndex=\(oldIndex) newIndex=\(targetIndexAfterTrim) anchorFrameID=\(anchorIDValue) anchorTs=\(anchorTS)"
        }

        return .apply(
            TimelineFrameWindowAppliedTrimOutcome(
                mutation: trimMutation,
                trimLogMessage: trimLogMessage,
                anchorLogMessage: anchorLogMessage
            )
        )
    }

    static func applyTrim(
        frames: [TimelineFrame],
        preserveDirection: TimelineTrimDirection,
        currentIndex: Int,
        maxFrames: Int,
        currentFrame: TimelineFrame?,
        anchorFrameID: FrameID?,
        anchorTimestamp: Date?
    ) -> TimelineFrameWindowTrimMutationResult? {
        let resolvedAnchorFrameID = anchorFrameID ?? currentFrame?.frame.id
        let resolvedAnchorTimestamp = anchorTimestamp ?? currentFrame?.frame.timestamp

        guard let trimResult = TimelineFrameWindowSupport.trim(
            frames: frames,
            preserveDirection: preserveDirection,
            currentIndex: currentIndex,
            maxFrames: maxFrames,
            anchorFrameID: resolvedAnchorFrameID,
            anchorTimestamp: resolvedAnchorTimestamp
        ) else {
            return nil
        }

        switch preserveDirection {
        case .older:
            return TimelineFrameWindowTrimMutationResult(
                frames: trimResult.frames,
                pendingCurrentIndexAfterFrameReplacement: nil,
                excessCount: trimResult.excessCount,
                oldestTimestamp: trimResult.frames.first?.frame.timestamp,
                newestTimestamp: trimResult.frames.last?.frame.timestamp,
                boundaryToRestoreAfterTrim: .newer,
                resolvedAnchorFrameID: resolvedAnchorFrameID,
                resolvedAnchorTimestamp: resolvedAnchorTimestamp
            )

        case .newer:
            return TimelineFrameWindowTrimMutationResult(
                frames: trimResult.frames,
                pendingCurrentIndexAfterFrameReplacement: trimResult.targetIndexAfterTrim ?? max(0, currentIndex),
                excessCount: trimResult.excessCount,
                oldestTimestamp: trimResult.frames.first?.frame.timestamp,
                newestTimestamp: trimResult.frames.last?.frame.timestamp,
                boundaryToRestoreAfterTrim: .older,
                resolvedAnchorFrameID: resolvedAnchorFrameID,
                resolvedAnchorTimestamp: resolvedAnchorTimestamp
            )
        }
    }
}

enum TimelineBoundaryPageApplySupport {
    static func prepareOlderLoadOutcome(
        pageOutcome: TimelineOlderBoundaryPageQueryOutcome,
        existingFrames: [TimelineFrame],
        currentIndex: Int
    ) -> TimelineOlderBoundaryPreparedOutcome {
        switch pageOutcome {
        case .skippedNoOverlap:
            return .reachedStart(skippedDueToNoOverlap: true, queryElapsedMs: nil)

        case let .loaded(result):
            guard !result.framesDescending.isEmpty else {
                return .reachedStart(
                    skippedDueToNoOverlap: false,
                    queryElapsedMs: result.queryElapsedMs
                )
            }

            return .apply(
                TimelineOlderBoundaryPreparedLoad(
                    queryElapsedMs: result.queryElapsedMs,
                    applyPlan: makeOlderApplyPlan(
                        existingFrames: existingFrames,
                        currentIndex: currentIndex,
                        loadedFramesDescending: result.framesDescending
                    )
                )
            )
        }
    }

    static func makeOlderApplyPlan(
        existingFrames: [TimelineFrame],
        currentIndex: Int,
        loadedFramesDescending: [FrameWithVideoInfo]
    ) -> TimelineOlderBoundaryApplyPlan {
        let addedFrames = loadedFramesDescending.reversed().map(TimelineFrame.init(frameWithVideoInfo:))
        let clampedPreviousIndex = min(max(currentIndex, 0), max(0, existingFrames.count - 1))
        let previousFrameTimestamp = existingFrames.isEmpty ? nil : existingFrames[clampedPreviousIndex].frame.timestamp
        let resultingCurrentIndex = existingFrames.isEmpty ? 0 : clampedPreviousIndex + addedFrames.count

        return TimelineOlderBoundaryApplyPlan(
            addedFrames: addedFrames,
            clampedPreviousIndex: clampedPreviousIndex,
            resultingCurrentIndex: resultingCurrentIndex,
            previousFrameTimestamp: previousFrameTimestamp
        )
    }

    static func prepareNewerLoadOutcome(
        pageResult: TimelineNewerBoundaryPageQueryResult,
        existingFrames: [TimelineFrame],
        currentIndex: Int,
        shouldTrackNewestWhenAtEdge: Bool
    ) -> TimelineNewerBoundaryPreparedOutcome {
        guard !pageResult.frames.isEmpty else {
            return .reachedEndEmpty(queryElapsedMs: pageResult.queryElapsedMs)
        }

        let appendOutcome = makeNewerApplyPlan(
            existingFrames: existingFrames,
            currentIndex: currentIndex,
            loadedFrames: pageResult.frames,
            shouldTrackNewestWhenAtEdge: shouldTrackNewestWhenAtEdge
        )

        switch appendOutcome {
        case let .duplicateOnly(duplicateOnlyResult):
            return .reachedEndDuplicateOnly(duplicateOnlyResult, queryElapsedMs: pageResult.queryElapsedMs)

        case let .append(plan):
            return .apply(
                TimelineNewerBoundaryPreparedLoad(
                    queryElapsedMs: pageResult.queryElapsedMs,
                    requestedFrameCount: pageResult.frames.count,
                    applyPlan: plan
                )
            )
        }
    }

    static func makeNewerApplyPlan(
        existingFrames: [TimelineFrame],
        currentIndex: Int,
        loadedFrames: [FrameWithVideoInfo],
        shouldTrackNewestWhenAtEdge: Bool
    ) -> TimelineNewerBoundaryApplyPlanOutcome {
        let candidateFrames = loadedFrames.map(TimelineFrame.init(frameWithVideoInfo:))
        let existingFrameIDs = Set(existingFrames.map(\.frame.id))
        let addedFrames = candidateFrames.filter { !existingFrameIDs.contains($0.frame.id) }
        let duplicateCount = candidateFrames.count - addedFrames.count

        guard !addedFrames.isEmpty else {
            return .duplicateOnly(
                TimelineNewerBoundaryDuplicateOnlyResult(
                    attemptedFrameCount: candidateFrames.count,
                    newestFrameID: existingFrames.last?.frame.id.value ?? -1,
                    duplicateFrameID: candidateFrames.first?.frame.id.value ?? -1
                )
            )
        }

        let wasAtNewestBeforeAppend = currentIndex >= existingFrames.count - 1
        let didPinToNewest = wasAtNewestBeforeAppend && shouldTrackNewestWhenAtEdge
        let resultingCurrentIndex = didPinToNewest
            ? existingFrames.count + addedFrames.count - 1
            : currentIndex

        return .append(
            TimelineNewerBoundaryApplyPlan(
                addedFrames: addedFrames,
                duplicateCount: duplicateCount,
                wasAtNewestBeforeAppend: wasAtNewestBeforeAppend,
                didPinToNewest: didPinToNewest,
                resultingCurrentIndex: resultingCurrentIndex
            )
        )
    }
}

enum TimelineBoundaryLoadCompletionSupport {
    static func logOlderBoundaryLoadStarted(
        reason: String,
        oldestTimestamp: Date,
        cmdFTraceID: String?
    ) {
        let traceLabel = cmdFTraceID.map { "[\($0)] " } ?? ""
        Log.info(
            "[BoundaryOlder] \(traceLabel)start reason=\(reason) oldest=\(Log.timestamp(from: oldestTimestamp))",
            category: .ui
        )
    }

    static func logNewerBoundaryLoadStarted(
        reason: String,
        newestTimestamp: Date?,
        currentIndex: Int,
        frameCount: Int,
        hasMoreNewer: Bool,
        isActivelyScrolling: Bool,
        subFrameOffset: Double,
        cmdFTraceID: String?
    ) {
        let traceLabel = cmdFTraceID.map { "[\($0)] " } ?? ""
        let newestLabel = newestTimestamp.map { Log.timestamp(from: $0) } ?? "nil"
        let offsetLabel = String(format: "%.1f", subFrameOffset)
        Log.info(
            "[BoundaryNewer] \(traceLabel)start reason=\(reason) newest=\(newestLabel) index=\(currentIndex)/\(max(0, frameCount - 1)) hasMoreNewer=\(hasMoreNewer) scrolling=\(isActivelyScrolling) subFrameOffset=\(offsetLabel)",
            category: .ui
        )
    }

    static func logBoundaryLoadFailure(
        direction: TimelineBoundaryLoadDirection,
        reason: String,
        error: Error,
        loadStartedAt: CFAbsoluteTime,
        cmdFTraceID: String?
    ) {
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000
        let traceLabel = cmdFTraceID.map { "[\($0)] " } ?? ""
        let elapsedLabel = String(format: "%.1f", elapsedMs)
        Log.error(
            "[\(direction.label)] \(traceLabel)FAILED reason=\(reason) elapsed=\(elapsedLabel)ms error=\(error)",
            category: .ui
        )
    }

    static func prepareOlderApplyResult(
        existingFrames: [TimelineFrame],
        currentIndex: Int,
        oldFirstTimestamp: Date,
        preparedLoad: TimelineOlderBoundaryPreparedLoad
    ) -> TimelineOlderBoundaryApplyResult {
        let applyPlan = preparedLoad.applyPlan
        return TimelineOlderBoundaryApplyResult(
            mutationResult: TimelineFrameWindowMutationSupport.applyOlder(
                existingFrames: existingFrames,
                applyPlan: applyPlan
            ),
            completionSummary: makeOlderApplySummary(
                beforeCount: existingFrames.count,
                oldFirstTimestamp: oldFirstTimestamp,
                applyPlan: applyPlan
            )
        )
    }

    static func prepareNewerApplyResult(
        existingFrames: [TimelineFrame],
        currentIndex: Int,
        oldLastTimestamp: Date?,
        preparedLoad: TimelineNewerBoundaryPreparedLoad
    ) -> TimelineNewerBoundaryApplyResult {
        let applyPlan = preparedLoad.applyPlan
        return TimelineNewerBoundaryApplyResult(
            mutationResult: TimelineFrameWindowMutationSupport.applyNewer(
                existingFrames: existingFrames,
                applyPlan: applyPlan
            ),
            completionSummary: makeNewerApplySummary(
                beforeCount: existingFrames.count,
                previousIndex: currentIndex,
                oldLastTimestamp: oldLastTimestamp,
                applyPlan: applyPlan
            )
        )
    }

    static func makeOlderApplySummary(
        beforeCount: Int,
        oldFirstTimestamp: Date,
        applyPlan: TimelineOlderBoundaryApplyPlan
    ) -> TimelineOlderBoundaryLoadCompletionSummary {
        let bridgeTimestamp = applyPlan.addedFrames.last?.frame.timestamp
        let bridgeGapSeconds = bridgeTimestamp.map { max(0, oldFirstTimestamp.timeIntervalSince($0)) }

        return TimelineOlderBoundaryLoadCompletionSummary(
            beforeCount: beforeCount,
            afterCount: beforeCount + applyPlan.addedFrames.count,
            addedCount: applyPlan.addedFrames.count,
            previousIndex: applyPlan.clampedPreviousIndex,
            currentIndex: applyPlan.resultingCurrentIndex,
            oldFirstTimestamp: oldFirstTimestamp,
            previousFrameTimestamp: applyPlan.previousFrameTimestamp,
            bridgeTimestamp: bridgeTimestamp,
            bridgeGapSeconds: bridgeGapSeconds
        )
    }

    static func makeNewerApplySummary(
        beforeCount: Int,
        previousIndex: Int,
        oldLastTimestamp: Date?,
        applyPlan: TimelineNewerBoundaryApplyPlan
    ) -> TimelineNewerBoundaryLoadCompletionSummary {
        let bridgeTimestamp = applyPlan.addedFrames.first?.frame.timestamp
        let bridgeGapSeconds = oldLastTimestamp.flatMap { oldLast in
            bridgeTimestamp.map { max(0, $0.timeIntervalSince(oldLast)) }
        }

        return TimelineNewerBoundaryLoadCompletionSummary(
            beforeCount: beforeCount,
            afterCount: beforeCount + applyPlan.addedFrames.count,
            addedCount: applyPlan.addedFrames.count,
            previousIndex: previousIndex,
            currentIndex: applyPlan.resultingCurrentIndex,
            oldLastTimestamp: oldLastTimestamp,
            wasAtNewestBeforeAppend: applyPlan.wasAtNewestBeforeAppend,
            didPinToNewest: applyPlan.didPinToNewest,
            bridgeTimestamp: bridgeTimestamp,
            bridgeGapSeconds: bridgeGapSeconds
        )
    }

    static func logOlderApplied(
        reason: String,
        completionSummary: TimelineOlderBoundaryLoadCompletionSummary,
        mutationResult: TimelineFrameWindowMutationResult,
        frameBufferCount: Int,
        memoryLogger: (String, Int, Int, Date?, Date?) -> Void
    ) {
        Log.info(
            "[Memory] LOADED OLDER: +\(completionSummary.addedCount) frames (\(completionSummary.beforeCount)→\(completionSummary.afterCount)), index adjusted from \(completionSummary.previousIndex) to \(completionSummary.currentIndex), maintaining timestamp=\(completionSummary.previousFrameTimestamp?.description ?? "nil")",
            category: .ui
        )
        Log.info(
            "[INFINITE-SCROLL] After load older: new first frame=\(mutationResult.frames.first?.frame.timestamp.description ?? "nil"), new last frame=\(mutationResult.frames.last?.frame.timestamp.description ?? "nil")",
            category: .ui
        )
        if let bridge = completionSummary.bridgeTimestamp,
           let bridgeGap = completionSummary.bridgeGapSeconds
        {
            Log.info(
                "[BoundaryOlder] MERGE reason=\(reason) bridgeGap=\(String(format: "%.1fs", bridgeGap)) oldFirst=\(Log.timestamp(from: completionSummary.oldFirstTimestamp)) insertedLast=\(Log.timestamp(from: bridge))",
                category: .ui
            )
        }
        memoryLogger(
            "AFTER LOAD OLDER",
            mutationResult.frames.count,
            frameBufferCount,
            mutationResult.oldestTimestamp,
            mutationResult.newestTimestamp
        )
    }

    static func logNewerApplied(
        reason: String,
        completionSummary: TimelineNewerBoundaryLoadCompletionSummary,
        mutationResult: TimelineFrameWindowMutationResult,
        frameBufferCount: Int,
        memoryLogger: (String, Int, Int, Date?, Date?) -> Void,
        hasMoreNewer: Bool,
        isActivelyScrolling: Bool,
        previousSubFrameOffset: Double,
        currentSubFrameOffset: Double,
        previousNewestBlock: TimelineEdgeBlockSummary?,
        currentNewestBlock: TimelineEdgeBlockSummary?
    ) {
        Log.info(
            "[BOUNDARY-NEWER-PLAYHEAD] PRE_APPEND reason=\(reason) currentIndex=\(completionSummary.previousIndex) beforeCount=\(completionSummary.beforeCount) added=\(completionSummary.addedCount) wasAtNewestLoaded=\(completionSummary.wasAtNewestBeforeAppend) shouldPinToNewest=\(completionSummary.didPinToNewest) hasMoreNewer=\(hasMoreNewer) isActivelyScrolling=\(isActivelyScrolling) subFrameOffset=\(String(format: "%.1f", previousSubFrameOffset))",
            category: .ui
        )
        Log.info(
            "[BOUNDARY-NEWER-PLAYHEAD] POST_APPEND reason=\(reason) index=\(completionSummary.previousIndex)->\(completionSummary.currentIndex) beforeCount=\(completionSummary.beforeCount) afterCount=\(completionSummary.afterCount) pinnedToNewest=\(completionSummary.didPinToNewest) hasMoreNewer=\(hasMoreNewer) isActivelyScrolling=\(isActivelyScrolling) subFrameOffset=\(String(format: "%.1f", currentSubFrameOffset))",
            category: .ui
        )
        TimelineFrameWindowBlockSupport.logNewestEdgeBlockTransition(
            context: "boundary-newer",
            reason: reason,
            before: previousNewestBlock,
            after: currentNewestBlock,
            appendedCount: completionSummary.addedCount
        )
        Log.info(
            "[Memory] LOADED NEWER: +\(completionSummary.addedCount) frames (\(completionSummary.beforeCount)→\(completionSummary.afterCount))",
            category: .ui
        )
        if let bridge = completionSummary.bridgeTimestamp,
           let bridgeGap = completionSummary.bridgeGapSeconds,
           let oldLastTimestamp = completionSummary.oldLastTimestamp
        {
            Log.info(
                "[BoundaryNewer] MERGE reason=\(reason) bridgeGap=\(String(format: "%.1fs", bridgeGap)) oldLast=\(Log.timestamp(from: oldLastTimestamp)) insertedFirst=\(Log.timestamp(from: bridge))",
                category: .ui
            )
        }
        memoryLogger(
            "AFTER LOAD NEWER",
            mutationResult.frames.count,
            frameBufferCount,
            mutationResult.oldestTimestamp,
            mutationResult.newestTimestamp
        )
    }

    static func logOlderCmdFCompletion(
        traceID: String,
        reason: String,
        queryElapsedMs: Double,
        loadStartedAt: CFAbsoluteTime,
        traceStartedAt: CFAbsoluteTime,
        addedCount: Int
    ) {
        let timing = makeTiming(
            now: CFAbsoluteTimeGetCurrent(),
            loadStartedAt: loadStartedAt,
            traceStartedAt: traceStartedAt
        )
        Log.recordLatency(
            "timeline.cmdf.quick_filter.boundary.older_ms",
            valueMs: timing.loadElapsedMs,
            category: .ui,
            summaryEvery: 5,
            warningThresholdMs: 220,
            criticalThresholdMs: 500
        )
        Log.info(
            "[CmdFPerf][\(traceID)] Boundary older load complete reason=\(reason) query=\(String(format: "%.1f", queryElapsedMs))ms load=\(String(format: "%.1f", timing.loadElapsedMs))ms added=\(addedCount) total=\(String(format: "%.1f", timing.totalFromTraceMs ?? timing.loadElapsedMs))ms",
            category: .ui
        )
    }

    static func logNewerCmdFCompletion(
        traceID: String,
        reason: String,
        queryElapsedMs: Double,
        loadStartedAt: CFAbsoluteTime,
        traceStartedAt: CFAbsoluteTime,
        addedCount: Int
    ) {
        let timing = makeTiming(
            now: CFAbsoluteTimeGetCurrent(),
            loadStartedAt: loadStartedAt,
            traceStartedAt: traceStartedAt
        )
        Log.recordLatency(
            "timeline.cmdf.quick_filter.boundary.newer_ms",
            valueMs: timing.loadElapsedMs,
            category: .ui,
            summaryEvery: 5,
            warningThresholdMs: 220,
            criticalThresholdMs: 500
        )
        Log.info(
            "[CmdFPerf][\(traceID)] Boundary newer load complete reason=\(reason) query=\(String(format: "%.1f", queryElapsedMs))ms load=\(String(format: "%.1f", timing.loadElapsedMs))ms added=\(addedCount) total=\(String(format: "%.1f", timing.totalFromTraceMs ?? timing.loadElapsedMs))ms",
            category: .ui
        )
    }

    static func makeTiming(
        now: CFAbsoluteTime,
        loadStartedAt: CFAbsoluteTime,
        traceStartedAt: CFAbsoluteTime
    ) -> TimelineBoundaryLoadTiming {
        let loadElapsedMs = (now - loadStartedAt) * 1000
        let totalFromTraceMs: Double?
        if traceStartedAt > 0 {
            totalFromTraceMs = (now - traceStartedAt) * 1000
        } else {
            totalFromTraceMs = nil
        }
        return TimelineBoundaryLoadTiming(loadElapsedMs: loadElapsedMs, totalFromTraceMs: totalFromTraceMs)
    }
}

enum TimelineRefreshWindowSupport {
    static func makeExistingWindowAction(
        navigateToNewest: Bool,
        allowNearLiveAutoAdvance: Bool,
        currentIndex: Int,
        frameCount: Int,
        hasActiveFilters: Bool,
        newestLoadedFrameIsRecent: Bool,
        nearLiveEdgeFrameThreshold: Int
    ) -> TimelineRefreshExistingWindowAction {
        if !navigateToNewest, currentIndex < frameCount, !hasActiveFilters {
            let framesFromNewest = frameCount - 1 - currentIndex
            let isNearLive = newestLoadedFrameIsRecent &&
                framesFromNewest < nearLiveEdgeFrameThreshold
            if !isNearLive || !allowNearLiveAutoAdvance {
                return .skipRefresh
            }

            return .refresh(shouldNavigateToNewest: true)
        }

        return .refresh(shouldNavigateToNewest: navigateToNewest)
    }

    static func makeFetchAction(
        existingFrames: [TimelineFrame],
        currentIndex: Int,
        fetchedFrames: [FrameWithVideoInfo],
        newestCachedTimestamp: Date,
        refreshLimit: Int,
        shouldNavigateToNewest: Bool,
        hasStartedScrubbingThisVisibleSession: Bool
    ) -> TimelineRefreshFetchAction {
        let shouldAutoAdvanceAfterFetch =
            shouldNavigateToNewest && !hasStartedScrubbingThisVisibleSession
        let newFrames = fetchedFrames.filter { $0.frame.timestamp > newestCachedTimestamp }

        if !newFrames.isEmpty {
            if newFrames.count >= refreshLimit {
                return shouldAutoAdvanceAfterFetch ? .requireFullReloadToNewest : .noChange
            }

            let appendedFrames = newFrames.reversed().map { TimelineFrame(frameWithVideoInfo: $0) }
            let frames = existingFrames + appendedFrames
            let resultingCurrentIndex = shouldAutoAdvanceAfterFetch ? max(0, frames.count - 1) : currentIndex

            return .append(
                TimelineRefreshAppendMutationResult(
                    frames: frames,
                    resultingCurrentIndex: resultingCurrentIndex,
                    appendedFrameCount: appendedFrames.count,
                    oldestTimestamp: frames.first?.frame.timestamp,
                    newestTimestamp: frames.last?.frame.timestamp
                )
            )
        }

        if shouldAutoAdvanceAfterFetch {
            return .pinToNewestExisting(resultingCurrentIndex: max(0, existingFrames.count - 1))
        }

        return .noChange
    }
}
