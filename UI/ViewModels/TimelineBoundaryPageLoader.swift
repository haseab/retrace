import Foundation
import Shared

enum TimelineBoundaryPageLoader {
    static func loadOlderPage(
        oldestTimestamp: Date,
        requestFilters: FilterCriteria,
        reason: String,
        loadWindowSpanSeconds: TimeInterval,
        loadBatchSize: Int,
        olderSparseRetryThreshold: Int,
        nearestFallbackBatchSize: Int,
        fetchFramesBefore: (Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo]
    ) async throws -> TimelineOlderBoundaryPageQueryOutcome {
        let rangeEnd = oneMillisecondBefore(oldestTimestamp)
        let hasMetadataFilter = hasSparseMetadataFilter(requestFilters)

        let queryFilters: FilterCriteria
        if hasMetadataFilter {
            var metadataFilters = requestFilters
            if let explicitEnd = metadataFilters.endDate {
                metadataFilters.endDate = min(explicitEnd, rangeEnd)
            } else {
                metadataFilters.endDate = rangeEnd
            }
            queryFilters = metadataFilters
            let effectiveStart = queryFilters.startDate.map { Log.timestamp(from: $0) } ?? "unbounded"
            let effectiveEnd = queryFilters.endDate.map { Log.timestamp(from: $0) } ?? Log.timestamp(from: rangeEnd)
            Log.info(
                "[BoundaryOlder] START reason=\(reason) strategy=metadata-unbounded effectiveWindow=\(effectiveStart)->\(effectiveEnd) currentOldest=\(Log.timestamp(from: oldestTimestamp))",
                category: .ui
            )
        } else {
            let rangeStart = rangeEnd.addingTimeInterval(-loadWindowSpanSeconds)
            guard let boundedFilters = TimelineFrameWindowSupport.makeBoundedBoundaryFilters(
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                criteria: requestFilters
            ) else {
                Log.info(
                    "[BoundaryOlder] SKIP reason=\(reason) window=\(Log.timestamp(from: rangeStart))->\(Log.timestamp(from: rangeEnd)) no-overlap-with-filters",
                    category: .ui
                )
                return .skippedNoOverlap(rangeStart: rangeStart, rangeEnd: rangeEnd)
            }
            queryFilters = boundedFilters
            Log.info(
                "[BoundaryOlder] START reason=\(reason) strategy=windowed window=\(Log.timestamp(from: rangeStart))->\(Log.timestamp(from: rangeEnd)) effectiveWindow=\(Log.timestamp(from: boundedFilters.startDate ?? rangeStart))->\(Log.timestamp(from: boundedFilters.endDate ?? rangeEnd)) currentOldest=\(Log.timestamp(from: oldestTimestamp))",
                category: .ui
            )
        }

        let queryStart = CFAbsoluteTimeGetCurrent()
        var framesDescending = try await fetchFramesBefore(
            oldestTimestamp,
            loadBatchSize,
            queryFilters,
            "loadOlderFrames.reason=\(reason)"
        )
        let queryElapsedMs = (CFAbsoluteTimeGetCurrent() - queryStart) * 1000

        if let nearest = framesDescending.first, let farthest = framesDescending.last {
            Log.info(
                "[BoundaryOlder] RESULT reason=\(reason) count=\(framesDescending.count) nearest=\(Log.timestamp(from: nearest.frame.timestamp)) farthest=\(Log.timestamp(from: farthest.frame.timestamp)) query=\(String(format: "%.1f", queryElapsedMs))ms",
                category: .ui
            )
        } else {
            Log.info(
                "[BoundaryOlder] RESULT reason=\(reason) count=0 query=\(String(format: "%.1f", queryElapsedMs))ms",
                category: .ui
            )
        }

        guard !Task.isCancelled else {
            return .loaded(
                TimelineOlderBoundaryPageQueryResult(
                    framesDescending: framesDescending,
                    queryElapsedMs: queryElapsedMs
                )
            )
        }

        let shouldRetryNearestFallback = !hasMetadataFilter
            && framesDescending.count < olderSparseRetryThreshold

        if shouldRetryNearestFallback {
            let boundedCount = framesDescending.count
            let fallbackTrigger = boundedCount == 0 ? "empty" : "sparse"
            Log.info(
                "[BoundaryOlder] FALLBACK_START reason=\(reason) strategy=nearest trigger=\(fallbackTrigger) boundedCount=\(boundedCount) threshold=\(olderSparseRetryThreshold) before=\(Log.timestamp(from: oldestTimestamp)) limit=\(nearestFallbackBatchSize)",
                category: .ui
            )
            let fallbackStart = CFAbsoluteTimeGetCurrent()
            let fallbackFramesDescending = try await fetchFramesBefore(
                oldestTimestamp,
                nearestFallbackBatchSize,
                requestFilters,
                "loadOlderFrames.reason=\(reason).nearestFallback"
            )
            let fallbackElapsedMs = (CFAbsoluteTimeGetCurrent() - fallbackStart) * 1000

            if let nearest = fallbackFramesDescending.first, let farthest = fallbackFramesDescending.last {
                Log.info(
                    "[BoundaryOlder] FALLBACK_RESULT reason=\(reason) count=\(fallbackFramesDescending.count) nearest=\(Log.timestamp(from: nearest.frame.timestamp)) farthest=\(Log.timestamp(from: farthest.frame.timestamp)) query=\(String(format: "%.1f", fallbackElapsedMs))ms",
                    category: .ui
                )
            } else {
                Log.info(
                    "[BoundaryOlder] FALLBACK_RESULT reason=\(reason) count=0 query=\(String(format: "%.1f", fallbackElapsedMs))ms",
                    category: .ui
                )
            }

            if fallbackFramesDescending.count > boundedCount {
                Log.info(
                    "[BoundaryOlder] FALLBACK_APPLY reason=\(reason) boundedCount=\(boundedCount) replacementCount=\(fallbackFramesDescending.count)",
                    category: .ui
                )
                framesDescending = fallbackFramesDescending
            } else if boundedCount > 0 {
                Log.info(
                    "[BoundaryOlder] FALLBACK_KEEP reason=\(reason) boundedCount=\(boundedCount) fallbackCount=\(fallbackFramesDescending.count)",
                    category: .ui
                )
            } else {
                framesDescending = fallbackFramesDescending
            }
        }

        return .loaded(
            TimelineOlderBoundaryPageQueryResult(
                framesDescending: framesDescending,
                queryElapsedMs: queryElapsedMs
            )
        )
    }

    static func loadNewerPage(
        newestTimestamp: Date,
        requestFilters: FilterCriteria,
        reason: String,
        loadWindowSpanSeconds: TimeInterval,
        loadBatchSize: Int,
        newerSparseRetryThreshold: Int,
        nearestFallbackBatchSize: Int,
        fetchFramesInRange: (Date, Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo],
        fetchFramesAfter: (Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo]
    ) async throws -> TimelineNewerBoundaryPageQueryResult {
        let rangeStart = oneMillisecondAfter(newestTimestamp)
        let rangeEnd = rangeStart.addingTimeInterval(loadWindowSpanSeconds)
        Log.info(
            "[BoundaryNewer] START reason=\(reason) window=\(Log.timestamp(from: rangeStart))->\(Log.timestamp(from: rangeEnd)) currentNewest=\(Log.timestamp(from: newestTimestamp))",
            category: .ui
        )

        let queryStart = CFAbsoluteTimeGetCurrent()
        var frames = try await fetchFramesInRange(
            rangeStart,
            rangeEnd,
            loadBatchSize,
            requestFilters,
            "loadNewerFrames.reason=\(reason)"
        )
        let queryElapsedMs = (CFAbsoluteTimeGetCurrent() - queryStart) * 1000

        if let first = frames.first, let last = frames.last {
            Log.info(
                "[BoundaryNewer] RESULT reason=\(reason) count=\(frames.count) first=\(Log.timestamp(from: first.frame.timestamp)) last=\(Log.timestamp(from: last.frame.timestamp)) query=\(String(format: "%.1f", queryElapsedMs))ms",
                category: .ui
            )
        } else {
            Log.info(
                "[BoundaryNewer] RESULT reason=\(reason) count=0 query=\(String(format: "%.1f", queryElapsedMs))ms",
                category: .ui
            )
        }

        guard !Task.isCancelled else {
            return TimelineNewerBoundaryPageQueryResult(
                frames: frames,
                queryElapsedMs: queryElapsedMs
            )
        }

        let shouldRetryNearestFallback = frames.count < newerSparseRetryThreshold
        if shouldRetryNearestFallback {
            let boundedCount = frames.count
            let fallbackTrigger = boundedCount == 0 ? "empty" : "sparse"
            Log.info(
                "[BoundaryNewer] FALLBACK_START reason=\(reason) strategy=nearest trigger=\(fallbackTrigger) boundedCount=\(boundedCount) threshold=\(newerSparseRetryThreshold) after=\(Log.timestamp(from: newestTimestamp)) limit=\(nearestFallbackBatchSize)",
                category: .ui
            )
            let fallbackStart = CFAbsoluteTimeGetCurrent()
            let fallbackFrames = try await fetchFramesAfter(
                newestTimestamp,
                nearestFallbackBatchSize,
                requestFilters,
                "loadNewerFrames.reason=\(reason).nearestFallback"
            )
            let fallbackElapsedMs = (CFAbsoluteTimeGetCurrent() - fallbackStart) * 1000

            if let first = fallbackFrames.first, let last = fallbackFrames.last {
                Log.info(
                    "[BoundaryNewer] FALLBACK_RESULT reason=\(reason) count=\(fallbackFrames.count) first=\(Log.timestamp(from: first.frame.timestamp)) last=\(Log.timestamp(from: last.frame.timestamp)) query=\(String(format: "%.1f", fallbackElapsedMs))ms",
                    category: .ui
                )
            } else {
                Log.info(
                    "[BoundaryNewer] FALLBACK_RESULT reason=\(reason) count=0 query=\(String(format: "%.1f", fallbackElapsedMs))ms",
                    category: .ui
                )
            }

            if fallbackFrames.count > boundedCount {
                Log.info(
                    "[BoundaryNewer] FALLBACK_APPLY reason=\(reason) boundedCount=\(boundedCount) replacementCount=\(fallbackFrames.count)",
                    category: .ui
                )
                frames = fallbackFrames
            } else if boundedCount > 0 {
                Log.info(
                    "[BoundaryNewer] FALLBACK_KEEP reason=\(reason) boundedCount=\(boundedCount) fallbackCount=\(fallbackFrames.count)",
                    category: .ui
                )
            } else {
                frames = fallbackFrames
            }
        }

        return TimelineNewerBoundaryPageQueryResult(
            frames: frames,
            queryElapsedMs: queryElapsedMs
        )
    }

    private static func hasSparseMetadataFilter(_ criteria: FilterCriteria) -> Bool {
        criteria.windowNameFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || criteria.browserUrlFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func oneMillisecondAfter(_ date: Date) -> Date {
        date.addingTimeInterval(0.001)
    }

    private static func oneMillisecondBefore(_ date: Date) -> Date {
        date.addingTimeInterval(-0.001)
    }
}
