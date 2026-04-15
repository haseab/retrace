import Foundation
import Shared

extension SimpleTimelineViewModel {
    private func nextFetchTraceID(prefix: String) -> String {
        fetchTraceID &+= 1
        return "\(prefix)-\(fetchTraceID)"
    }

    private func compensatedFetchLimitForPendingDeletes(_ requestedLimit: Int) -> Int {
        let normalizedLimit = max(1, requestedLimit)
        let pendingCount = deletedFrameIDs.count
        guard pendingCount > 0 else { return normalizedLimit }

        let compensatedLimit = max(normalizedLimit * 2, normalizedLimit + pendingCount)
        return min(compensatedLimit, Self.pendingDeleteCompensatedFetchLimitCap)
    }

    private func filterPendingDeletedFrames(
        _ framesWithVideoInfo: [FrameWithVideoInfo],
        requestedLimit: Int,
        traceID: String,
        reason: String
    ) -> [FrameWithVideoInfo] {
        let normalizedLimit = max(0, requestedLimit)
        guard normalizedLimit > 0 else { return [] }
        guard !framesWithVideoInfo.isEmpty else { return [] }

        let pendingDeleteIDs = deletedFrameIDs
        guard !pendingDeleteIDs.isEmpty else {
            return framesWithVideoInfo.count > normalizedLimit
                ? Array(framesWithVideoInfo.prefix(normalizedLimit))
                : framesWithVideoInfo
        }

        let filteredFrames = framesWithVideoInfo.filter { !pendingDeleteIDs.contains($0.frame.id) }
        let droppedCount = framesWithVideoInfo.count - filteredFrames.count
        if droppedCount > 0 {
            Log.info(
                "[TIMELINE-FETCH][\(traceID)] Filtered pending-deleted frames reason='\(reason)' dropped=\(droppedCount) pendingDeleteIDs=\(pendingDeleteIDs.count)",
                category: .ui
            )
        }

        return filteredFrames.count > normalizedLimit
            ? Array(filteredFrames.prefix(normalizedLimit))
            : filteredFrames
    }

    func fetchFramesWithVideoInfoLogged(
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        filters: FilterCriteria,
        reason: String
    ) async throws -> [FrameWithVideoInfo] {
        let requestedLimit = max(1, limit)
        let queryLimit = compensatedFetchLimitForPendingDeletes(requestedLimit)
        let traceID = nextFetchTraceID(prefix: "window")
        let fetchStart = CFAbsoluteTimeGetCurrent()
        Log.info(
            "[TIMELINE-FETCH][\(traceID)] START reason='\(reason)' range=[\(Log.timestamp(from: startDate)) → \(Log.timestamp(from: endDate))] limit=\(requestedLimit) queryLimit=\(queryLimit) filters={\(summarizeFiltersForLog(filters))}",
            category: .ui
        )

        do {
            let rawFramesWithVideoInfo: [FrameWithVideoInfo]
#if DEBUG
            if let override = test_windowFetchHooks.getFramesWithVideoInfo {
                rawFramesWithVideoInfo = try await override(startDate, endDate, queryLimit, filters, reason)
            } else {
                rawFramesWithVideoInfo = try await coordinator.getFramesWithVideoInfo(
                    from: startDate,
                    to: endDate,
                    limit: queryLimit,
                    filters: filters
                )
            }
#else
            rawFramesWithVideoInfo = try await coordinator.getFramesWithVideoInfo(
                from: startDate,
                to: endDate,
                limit: queryLimit,
                filters: filters
            )
#endif
            let framesWithVideoInfo = filterPendingDeletedFrames(
                rawFramesWithVideoInfo,
                requestedLimit: requestedLimit,
                traceID: traceID,
                reason: reason
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.recordLatency(
                "timeline.fetch.window_frames_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 250,
                criticalThresholdMs: 750
            )
            let message = "[TIMELINE-FETCH][\(traceID)] END reason='\(reason)' count=\(framesWithVideoInfo.count) rawCount=\(rawFramesWithVideoInfo.count) elapsed=\(String(format: "%.1f", elapsedMs))ms"
            if elapsedMs >= 750 {
                Log.warning(message, category: .ui)
            } else {
                Log.info(message, category: .ui)
            }
            return framesWithVideoInfo
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.error(
                "[TIMELINE-FETCH][\(traceID)] FAIL reason='\(reason)' after \(String(format: "%.1f", elapsedMs))ms: \(error)",
                category: .ui
            )
            throw error
        }
    }

    func fetchFramesWithVideoInfoBeforeLogged(
        timestamp: Date,
        limit: Int,
        filters: FilterCriteria,
        reason: String
    ) async throws -> [FrameWithVideoInfo] {
        let requestedLimit = max(1, limit)
        let queryLimit = compensatedFetchLimitForPendingDeletes(requestedLimit)
        let traceID = nextFetchTraceID(prefix: "before")
        let fetchStart = CFAbsoluteTimeGetCurrent()
        let effectiveDateRanges = filters.effectiveDateRanges
        let boundedStart = effectiveDateRanges.first?.start.map { Log.timestamp(from: $0) } ?? "nil"
        let boundedEnd = effectiveDateRanges.first?.end.map { Log.timestamp(from: $0) } ?? "nil"
        Log.info(
            "[TIMELINE-FETCH][\(traceID)] START reason='\(reason)' before=\(Log.timestamp(from: timestamp)) limit=\(requestedLimit) queryLimit=\(queryLimit) boundedRange=[\(boundedStart) → \(boundedEnd)] filters={\(summarizeFiltersForLog(filters))}",
            category: .ui
        )

        do {
            let rawFramesWithVideoInfo: [FrameWithVideoInfo]
#if DEBUG
            if let override = test_windowFetchHooks.getFramesWithVideoInfoBefore {
                rawFramesWithVideoInfo = try await override(timestamp, queryLimit, filters, reason)
            } else {
                rawFramesWithVideoInfo = try await coordinator.getFramesWithVideoInfoBefore(
                    timestamp: timestamp,
                    limit: queryLimit,
                    filters: filters
                )
            }
#else
            rawFramesWithVideoInfo = try await coordinator.getFramesWithVideoInfoBefore(
                timestamp: timestamp,
                limit: queryLimit,
                filters: filters
            )
#endif
            let framesWithVideoInfo = filterPendingDeletedFrames(
                rawFramesWithVideoInfo,
                requestedLimit: requestedLimit,
                traceID: traceID,
                reason: reason
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.recordLatency(
                "timeline.fetch.before_frames_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 250,
                criticalThresholdMs: 750
            )
            let message = "[TIMELINE-FETCH][\(traceID)] END reason='\(reason)' count=\(framesWithVideoInfo.count) rawCount=\(rawFramesWithVideoInfo.count) elapsed=\(String(format: "%.1f", elapsedMs))ms"
            if elapsedMs >= 750 {
                Log.warning(message, category: .ui)
            } else {
                Log.info(message, category: .ui)
            }
            return framesWithVideoInfo
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.error(
                "[TIMELINE-FETCH][\(traceID)] FAIL reason='\(reason)' after \(String(format: "%.1f", elapsedMs))ms: \(error)",
                category: .ui
            )
            throw error
        }
    }

    func fetchFramesWithVideoInfoAfterLogged(
        timestamp: Date,
        limit: Int,
        filters: FilterCriteria,
        reason: String
    ) async throws -> [FrameWithVideoInfo] {
        let requestedLimit = max(1, limit)
        let queryLimit = compensatedFetchLimitForPendingDeletes(requestedLimit)
        let traceID = nextFetchTraceID(prefix: "after")
        let fetchStart = CFAbsoluteTimeGetCurrent()
        let effectiveDateRanges = filters.effectiveDateRanges
        let boundedStart = effectiveDateRanges.first?.start.map { Log.timestamp(from: $0) } ?? "nil"
        let boundedEnd = effectiveDateRanges.first?.end.map { Log.timestamp(from: $0) } ?? "nil"
        Log.info(
            "[TIMELINE-FETCH][\(traceID)] START reason='\(reason)' after=\(Log.timestamp(from: timestamp)) limit=\(requestedLimit) queryLimit=\(queryLimit) boundedRange=[\(boundedStart) → \(boundedEnd)] filters={\(summarizeFiltersForLog(filters))}",
            category: .ui
        )

        do {
            let rawFramesWithVideoInfo: [FrameWithVideoInfo]
#if DEBUG
            if let override = test_windowFetchHooks.getFramesWithVideoInfoAfter {
                rawFramesWithVideoInfo = try await override(timestamp, queryLimit, filters, reason)
            } else {
                rawFramesWithVideoInfo = try await coordinator.getFramesWithVideoInfoAfter(
                    timestamp: timestamp,
                    limit: queryLimit,
                    filters: filters
                )
            }
#else
            rawFramesWithVideoInfo = try await coordinator.getFramesWithVideoInfoAfter(
                timestamp: timestamp,
                limit: queryLimit,
                filters: filters
            )
#endif
            let framesWithVideoInfo = filterPendingDeletedFrames(
                rawFramesWithVideoInfo,
                requestedLimit: requestedLimit,
                traceID: traceID,
                reason: reason
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.recordLatency(
                "timeline.fetch.after_frames_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 250,
                criticalThresholdMs: 750
            )
            let message = "[TIMELINE-FETCH][\(traceID)] END reason='\(reason)' count=\(framesWithVideoInfo.count) rawCount=\(rawFramesWithVideoInfo.count) elapsed=\(String(format: "%.1f", elapsedMs))ms"
            if elapsedMs >= 750 {
                Log.warning(message, category: .ui)
            } else {
                Log.info(message, category: .ui)
            }
            return framesWithVideoInfo
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.error(
                "[TIMELINE-FETCH][\(traceID)] FAIL reason='\(reason)' after \(String(format: "%.1f", elapsedMs))ms: \(error)",
                category: .ui
            )
            throw error
        }
    }

    func fetchMostRecentFramesWithVideoInfoLogged(
        limit: Int,
        filters: FilterCriteria,
        reason: String
    ) async throws -> [FrameWithVideoInfo] {
        let requestedLimit = max(1, limit)
        let queryLimit = compensatedFetchLimitForPendingDeletes(requestedLimit)
        let traceID = nextFetchTraceID(prefix: "most-recent")
        let fetchStart = CFAbsoluteTimeGetCurrent()
        Log.info(
            "[TIMELINE-FETCH][\(traceID)] START reason='\(reason)' mostRecent limit=\(requestedLimit) queryLimit=\(queryLimit) filters={\(summarizeFiltersForLog(filters))}",
            category: .ui
        )

        do {
            let rawFramesWithVideoInfo: [FrameWithVideoInfo]
#if DEBUG
            if let override = test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo {
                rawFramesWithVideoInfo = try await override(queryLimit, filters)
            } else {
                rawFramesWithVideoInfo = try await coordinator.getMostRecentFramesWithVideoInfo(limit: queryLimit, filters: filters)
            }
#else
            rawFramesWithVideoInfo = try await coordinator.getMostRecentFramesWithVideoInfo(limit: queryLimit, filters: filters)
#endif
            let framesWithVideoInfo = filterPendingDeletedFrames(
                rawFramesWithVideoInfo,
                requestedLimit: requestedLimit,
                traceID: traceID,
                reason: reason
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.recordLatency(
                "timeline.fetch.most_recent_frames_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 220,
                criticalThresholdMs: 600
            )
            let message = "[TIMELINE-FETCH][\(traceID)] END reason='\(reason)' count=\(framesWithVideoInfo.count) rawCount=\(rawFramesWithVideoInfo.count) elapsed=\(String(format: "%.1f", elapsedMs))ms"
            if elapsedMs >= 600 {
                Log.warning(message, category: .ui)
            } else {
                Log.info(message, category: .ui)
            }
            return framesWithVideoInfo
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.error(
                "[TIMELINE-FETCH][\(traceID)] FAIL reason='\(reason)' after \(String(format: "%.1f", elapsedMs))ms: \(error)",
                category: .ui
            )
            throw error
        }
    }

    func refreshFrameDataCurrentDate() -> Date {
#if DEBUG
        if let override = test_refreshFrameDataHooks.now {
            return override()
        }
#endif
        return Date()
    }
}
