import Foundation
import Shared

extension TimelineCommentsStore {
    @MainActor
    func updateCommentSearchQuery(
        _ rawQuery: String,
        debounceNanoseconds: UInt64,
        pageSize: Int,
        searchEntries: @escaping (String, Int, Int) async throws -> [TimelineCommentTimelineEntry],
        mapEntryToRow: @escaping (TimelineCommentTimelineEntry) -> CommentTimelineRow,
        invalidate: @escaping () -> Void
    ) {
        cancelCommentSearch()

        let request = updateSearchState(invalidate: invalidate) {
            $0.updateQuery(rawQuery)
        }

        guard let request else { return }
        runCommentSearchPage(
            request,
            immediate: false,
            debounceNanoseconds: debounceNanoseconds,
            pageSize: pageSize,
            searchEntries: searchEntries,
            mapEntryToRow: mapEntryToRow,
            invalidate: invalidate
        )
    }

    @MainActor
    func retryCommentSearch(
        pageSize: Int,
        searchEntries: @escaping (String, Int, Int) async throws -> [TimelineCommentTimelineEntry],
        mapEntryToRow: @escaping (TimelineCommentTimelineEntry) -> CommentTimelineRow,
        invalidate: @escaping () -> Void
    ) {
        cancelCommentSearch()

        let request = updateSearchState(invalidate: invalidate) {
            $0.retrySearch()
        }

        guard let request else { return }
        runCommentSearchPage(
            request,
            immediate: true,
            debounceNanoseconds: 0,
            pageSize: pageSize,
            searchEntries: searchEntries,
            mapEntryToRow: mapEntryToRow,
            invalidate: invalidate
        )
    }

    @MainActor
    func loadMoreCommentSearchResultsIfNeeded(
        currentCommentID: SegmentCommentID?,
        pageSize: Int,
        searchEntries: @escaping (String, Int, Int) async throws -> [TimelineCommentTimelineEntry],
        mapEntryToRow: @escaping (TimelineCommentTimelineEntry) -> CommentTimelineRow,
        invalidate: @escaping () -> Void
    ) {
        guard let request = updateSearchState(invalidate: invalidate, mutation: {
            $0.loadMoreResultsIfNeeded(currentCommentID: currentCommentID)
        }) else {
            return
        }

        runCommentSearchPage(
            request,
            immediate: true,
            debounceNanoseconds: 0,
            pageSize: pageSize,
            searchEntries: searchEntries,
            mapEntryToRow: mapEntryToRow,
            invalidate: invalidate
        )
    }

    @MainActor
    func resetCommentSearchState(invalidate: () -> Void) {
        cancelCommentSearch()
        updateSearchState(invalidate: invalidate) { $0.reset() }
    }

    @MainActor
    func resetCommentTimelineBrowsing(invalidate: () -> Void) {
        cancelCommentSearch()
        updateTimelineState(invalidate: invalidate) { $0.reset() }
        updateSearchState(invalidate: invalidate) { $0.reset() }
    }

    @MainActor
    func ensureCommentTimelineMetadataLoaded(
        fetchAllTags: @escaping () async throws -> [Tag],
        fetchSegmentTagsMap: @escaping () async throws -> [Int64: Set<Int64>],
        callbacks: TagIndicatorUpdateCallbacks
    ) async {
        if tagIndicatorState.availableTags.isEmpty {
            do {
                setAvailableTags(try await fetchAllTags(), invalidate: callbacks.invalidate)
                callbacks.didUpdateAvailableTags()
            } catch {
                Log.error("[Comments] Failed to load tags for all-comments timeline: \(error)", category: .ui)
            }
        }

        if tagIndicatorState.segmentTagsMap.isEmpty {
            do {
                setSegmentTagsMap(try await fetchSegmentTagsMap(), invalidate: callbacks.invalidate)
                callbacks.didUpdateSegmentTagsMap()
            } catch {
                Log.error("[Comments] Failed to load segment-tag map for all-comments timeline: \(error)", category: .ui)
            }
        }
    }

    @MainActor
    func loadCommentTimeline(
        anchorComment: SegmentComment?,
        fetchAllTags: @escaping () async throws -> [Tag],
        fetchSegmentTagsMap: @escaping () async throws -> [Int64: Set<Int64>],
        fetchEntries: @escaping () async throws -> [TimelineCommentTimelineEntry],
        metadataNormalizer: @escaping (String?) -> String?,
        rowBuilder: @escaping (SegmentComment, CommentTimelineSegmentContext?) -> CommentTimelineRow,
        callbacks: TagIndicatorUpdateCallbacks
    ) async {
        guard updateTimelineState(invalidate: callbacks.invalidate, mutation: {
            $0.beginInitialLoad(anchorComment: anchorComment)
        }) else { return }

        do {
            async let metadataLoad: Void = ensureCommentTimelineMetadataLoaded(
                fetchAllTags: fetchAllTags,
                fetchSegmentTagsMap: fetchSegmentTagsMap,
                callbacks: callbacks
            )
            async let entriesTask = fetchEntries()

            let entries = try await entriesTask
            await metadataLoad

            updateTimelineState(invalidate: callbacks.invalidate) {
                $0.applyInitialEntries(
                    entries,
                    anchorComment: anchorComment,
                    metadataNormalizer: metadataNormalizer,
                    rowBuilder: rowBuilder
                )
                $0.finishInitialLoad()
            }
        } catch {
            updateTimelineState(invalidate: callbacks.invalidate) {
                $0.finishInitialLoad(errorMessage: "Could not load all comments.")
            }
            Log.error("[Comments] Failed to load all-comments timeline: \(error)", category: .ui)
        }
    }

    @MainActor
    func ingestCommentTimelinePage(
        direction: TimelineCommentTimelineDirection,
        maxBatches: Int,
        fetchFrameBatch: @escaping (TimelineCommentTimelineDirection, Date) async throws -> [FrameReference],
        metadataNormalizer: @escaping (String?) -> String?,
        loadCommentsForSegment: @escaping (SegmentID) async throws -> [SegmentComment],
        rowBuilder: @escaping (SegmentComment, CommentTimelineSegmentContext?) -> CommentTimelineRow,
        invalidate: @escaping () -> Void
    ) async throws -> Int {
        var totalAdded = 0
        var completedBatches = 0

        while completedBatches < maxBatches {
            completedBatches += 1

            guard let boundaryTimestamp = commentTimelineBoundaryTimestamp(for: direction) else {
                updateTimelineState(invalidate: invalidate) {
                    $0.setHasMorePages(false, direction: direction)
                }
                return totalAdded
            }

            let batch = try await fetchFrameBatch(direction, boundaryTimestamp)
            if batch.isEmpty {
                updateTimelineState(invalidate: invalidate) {
                    $0.setHasMorePages(false, direction: direction)
                }
                return totalAdded
            }

            let addedInBatch = try await updateTimelineState(invalidate: invalidate) {
                try await $0.ingestFrameBatch(
                    batch,
                    metadataNormalizer: metadataNormalizer,
                    loadCommentsForSegment: loadCommentsForSegment,
                    rowBuilder: rowBuilder
                )
            }
            totalAdded += addedInBatch

            if addedInBatch > 0 {
                return totalAdded
            }
        }

        return totalAdded
    }

    @MainActor
    func loadCommentTimelinePage(
        direction: TimelineCommentTimelineDirection,
        baseFilters: FilterCriteria,
        maxBatches: Int,
        fetchFramesBefore: @escaping (Date, Int, FilterCriteria) async throws -> [FrameReference],
        fetchFramesAfter: @escaping (Date, Int, FilterCriteria) async throws -> [FrameReference],
        metadataNormalizer: @escaping (String?) -> String?,
        loadCommentsForSegment: @escaping (SegmentID) async throws -> [SegmentComment],
        rowBuilder: @escaping (SegmentComment, CommentTimelineSegmentContext?) -> CommentTimelineRow,
        invalidate: @escaping () -> Void
    ) async {
        guard updateTimelineState(invalidate: invalidate, mutation: {
            $0.beginPageLoad(direction: direction)
        }) else { return }

        do {
            var filters = baseFilters
            filters.commentFilter = .commentsOnly

            _ = try await ingestCommentTimelinePage(
                direction: direction,
                maxBatches: maxBatches,
                fetchFrameBatch: { direction, boundaryTimestamp in
                    switch direction {
                    case .older:
                        return try await fetchFramesBefore(boundaryTimestamp, 240, filters)
                    case .newer:
                        return try await fetchFramesAfter(boundaryTimestamp.addingTimeInterval(0.001), 240, filters)
                    }
                },
                metadataNormalizer: metadataNormalizer,
                loadCommentsForSegment: loadCommentsForSegment,
                rowBuilder: rowBuilder,
                invalidate: invalidate
            )
            updateTimelineState(invalidate: invalidate) {
                $0.finishPageLoad(direction: direction)
            }
        } catch {
            let message = direction == .older
                ? "Could not load older comments."
                : "Could not load newer comments."
            updateTimelineState(invalidate: invalidate) {
                $0.finishPageLoad(direction: direction, errorMessage: message)
            }
            let label = direction == .older ? "older" : "newer"
            Log.error("[Comments] Failed loading \(label) all-comments page: \(error)", category: .ui)
        }
    }

    func cancelCommentSearch() {
        commentSearchTask?.cancel()
        commentSearchTask = nil
    }

    @MainActor
    func runCommentSearchPage(
        _ request: TimelineCommentSearchRequest,
        immediate: Bool,
        debounceNanoseconds: UInt64,
        pageSize: Int,
        searchEntries: @escaping (String, Int, Int) async throws -> [TimelineCommentTimelineEntry],
        mapEntryToRow: @escaping (TimelineCommentTimelineEntry) -> CommentTimelineRow,
        invalidate: @escaping () -> Void
    ) {
        cancelCommentSearch()

        commentSearchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if !immediate {
                try? await Task.sleep(for: .nanoseconds(Int64(debounceNanoseconds)), clock: .continuous)
            }

            guard !Task.isCancelled else { return }

            do {
                let entries = try await searchEntries(request.query, request.offset, pageSize)
                let results = entries.map(mapEntryToRow)

                guard !Task.isCancelled else { return }
                guard self.updateSearchState(invalidate: invalidate, mutation: {
                    $0.applyResults(
                        query: request.query,
                        offset: request.offset,
                        append: request.append,
                        results: results,
                        pageSize: pageSize
                    )
                }) else {
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard self.updateSearchState(invalidate: invalidate, mutation: {
                    $0.applyFailure(
                        query: request.query,
                        append: request.append,
                        message: request.append ? "Could not load more comments." : "Could not search comments."
                    )
                }) else {
                    return
                }
                Log.error("[Comments] Failed to search comments: \(error)", category: .ui)
            }
        }
    }
}
