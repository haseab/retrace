import Foundation
import Shared

typealias TimelineCommentTimelineEntry = (
    comment: SegmentComment,
    segmentID: SegmentID,
    appBundleID: String?,
    appName: String?,
    browserURL: String?,
    referenceTimestamp: Date
)

enum TimelineCommentTimelineDirection: Equatable {
    case older
    case newer
}

struct TimelineCommentTimelineState {
    var rows: [CommentTimelineRow] = []
    var anchorCommentID: SegmentCommentID?
    var isLoadingTimeline = false
    var isLoadingOlderPage = false
    var isLoadingNewerPage = false
    var loadError: String? = nil
    var hasOlderPages = false
    var hasNewerPages = false
}

final class TimelineCommentTimelineController {
    private(set) var state = TimelineCommentTimelineState()

    private var commentsByID: [Int64: SegmentComment] = [:]
    private var contextByCommentID: [Int64: CommentTimelineSegmentContext] = [:]
    private var loadedSegmentIDs: Set<Int64> = []
    private var oldestFrameTimestamp: Date?
    private var newestFrameTimestamp: Date?

    func beginInitialLoad(anchorComment: SegmentComment?) -> Bool {
        guard !state.isLoadingTimeline else { return false }

        reset()
        state.isLoadingTimeline = true
        state.anchorCommentID = anchorComment?.id
        return true
    }

    func applyInitialEntries(
        _ entries: [TimelineCommentTimelineEntry],
        anchorComment: SegmentComment?,
        metadataNormalizer: (String?) -> String?,
        rowBuilder: (SegmentComment, CommentTimelineSegmentContext?) -> CommentTimelineRow
    ) {
        for entry in entries {
            let commentIDValue = entry.comment.id.value
            commentsByID[commentIDValue] = entry.comment
            contextByCommentID[commentIDValue] = TimelineCommentTimelineSupport.makeContext(
                entry: entry,
                metadataNormalizer: metadataNormalizer
            )
        }

        if let anchorComment,
           commentsByID[anchorComment.id.value] == nil {
            commentsByID[anchorComment.id.value] = anchorComment
        }

        rebuildRows(rowBuilder: rowBuilder)
    }

    func finishInitialLoad(errorMessage: String? = nil) {
        state.isLoadingTimeline = false
        if let errorMessage {
            state.loadError = errorMessage
        }
    }

    @discardableResult
    func removeComment(
        id: SegmentCommentID,
        rowBuilder: (SegmentComment, CommentTimelineSegmentContext?) -> CommentTimelineRow
    ) -> Bool {
        guard commentsByID.removeValue(forKey: id.value) != nil else { return false }

        contextByCommentID.removeValue(forKey: id.value)
        rebuildRows(rowBuilder: rowBuilder)
        return true
    }

    func beginPageLoad(direction: TimelineCommentTimelineDirection) -> Bool {
        guard !state.isLoadingTimeline else { return false }

        switch direction {
        case .older:
            guard !state.isLoadingOlderPage, state.hasOlderPages else {
                return false
            }
            guard oldestFrameTimestamp != nil else {
                state.hasOlderPages = false
                return false
            }
            state.isLoadingOlderPage = true
        case .newer:
            guard !state.isLoadingNewerPage, state.hasNewerPages else {
                return false
            }
            guard newestFrameTimestamp != nil else {
                state.hasNewerPages = false
                return false
            }
            state.isLoadingNewerPage = true
        }

        return true
    }

    func finishPageLoad(
        direction: TimelineCommentTimelineDirection,
        errorMessage: String? = nil
    ) {
        switch direction {
        case .older:
            state.isLoadingOlderPage = false
        case .newer:
            state.isLoadingNewerPage = false
        }

        if let errorMessage {
            state.loadError = errorMessage
        }
    }

    func setHasMorePages(_ hasMore: Bool, direction: TimelineCommentTimelineDirection) {
        switch direction {
        case .older:
            state.hasOlderPages = hasMore
        case .newer:
            state.hasNewerPages = hasMore
        }
    }

    func boundaryTimestamp(for direction: TimelineCommentTimelineDirection) -> Date? {
        switch direction {
        case .older:
            return oldestFrameTimestamp
        case .newer:
            return newestFrameTimestamp
        }
    }

    @discardableResult
    func ingestFrameBatch(
        _ frameRefs: [FrameReference],
        metadataNormalizer: (String?) -> String?,
        loadCommentsForSegment: (SegmentID) async throws -> [SegmentComment],
        rowBuilder: (SegmentComment, CommentTimelineSegmentContext?) -> CommentTimelineRow
    ) async throws -> Int {
        guard !frameRefs.isEmpty else { return 0 }

        if let oldest = frameRefs.map(\.timestamp).min() {
            if let existing = oldestFrameTimestamp {
                oldestFrameTimestamp = min(existing, oldest)
            } else {
                oldestFrameTimestamp = oldest
            }
        }

        if let newest = frameRefs.map(\.timestamp).max() {
            if let existing = newestFrameTimestamp {
                newestFrameTimestamp = max(existing, newest)
            } else {
                newestFrameTimestamp = newest
            }
        }

        var contextBySegmentID: [Int64: CommentTimelineSegmentContext] = [:]
        for frame in frameRefs {
            let segmentIDValue = frame.segmentID.value
            let candidate = TimelineCommentTimelineSupport.makeContext(
                frame: frame,
                metadataNormalizer: metadataNormalizer
            )

            if let existing = contextBySegmentID[segmentIDValue] {
                contextBySegmentID[segmentIDValue] = TimelineCommentTimelineSupport.preferredSegmentContext(
                    existing,
                    candidate
                )
            } else {
                contextBySegmentID[segmentIDValue] = candidate
            }
        }

        var newlyAddedComments = 0

        for (segmentIDValue, context) in contextBySegmentID.sorted(by: { $0.key < $1.key }) {
            guard !loadedSegmentIDs.contains(segmentIDValue) else { continue }
            loadedSegmentIDs.insert(segmentIDValue)

            let segmentComments = try await loadCommentsForSegment(SegmentID(value: segmentIDValue))
            guard !segmentComments.isEmpty else { continue }

            for comment in segmentComments {
                if commentsByID[comment.id.value] == nil {
                    newlyAddedComments += 1
                }
                commentsByID[comment.id.value] = comment

                let existingContext = contextByCommentID[comment.id.value]
                if TimelineCommentTimelineSupport.shouldUseContext(
                    candidate: context,
                    existing: existingContext,
                    for: comment
                ) {
                    contextByCommentID[comment.id.value] = context
                }
            }
        }

        if newlyAddedComments > 0 {
            rebuildRows(rowBuilder: rowBuilder)
        }

        return newlyAddedComments
    }

    func reset() {
        state = TimelineCommentTimelineState()
        commentsByID.removeAll()
        contextByCommentID.removeAll()
        loadedSegmentIDs.removeAll()
        oldestFrameTimestamp = nil
        newestFrameTimestamp = nil
    }

    private func rebuildRows(
        rowBuilder: (SegmentComment, CommentTimelineSegmentContext?) -> CommentTimelineRow
    ) {
        state.rows = commentsByID.values
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.value < $1.id.value
                }
                return $0.createdAt < $1.createdAt
            }
            .map { comment in
                rowBuilder(comment, contextByCommentID[comment.id.value])
            }
    }
}

private enum TimelineCommentTimelineSupport {
    static func makeContext(
        entry: TimelineCommentTimelineEntry,
        metadataNormalizer: (String?) -> String?
    ) -> CommentTimelineSegmentContext {
        CommentTimelineSegmentContext(
            segmentID: entry.segmentID,
            appBundleID: metadataNormalizer(entry.appBundleID),
            appName: metadataNormalizer(entry.appName),
            browserURL: metadataNormalizer(entry.browserURL),
            referenceTimestamp: entry.referenceTimestamp
        )
    }

    static func makeContext(
        frame: FrameReference,
        metadataNormalizer: (String?) -> String?
    ) -> CommentTimelineSegmentContext {
        CommentTimelineSegmentContext(
            segmentID: SegmentID(value: frame.segmentID.value),
            appBundleID: metadataNormalizer(frame.metadata.appBundleID),
            appName: metadataNormalizer(frame.metadata.appName),
            browserURL: metadataNormalizer(frame.metadata.browserURL),
            referenceTimestamp: frame.timestamp
        )
    }

    static func preferredSegmentContext(
        _ lhs: CommentTimelineSegmentContext,
        _ rhs: CommentTimelineSegmentContext
    ) -> CommentTimelineSegmentContext {
        let lhsHasBrowserURL = lhs.browserURL?.isEmpty == false
        let rhsHasBrowserURL = rhs.browserURL?.isEmpty == false
        if lhsHasBrowserURL != rhsHasBrowserURL {
            return lhsHasBrowserURL ? lhs : rhs
        }

        return lhs.referenceTimestamp <= rhs.referenceTimestamp ? lhs : rhs
    }

    static func shouldUseContext(
        candidate: CommentTimelineSegmentContext,
        existing: CommentTimelineSegmentContext?,
        for comment: SegmentComment
    ) -> Bool {
        guard let existing else { return true }

        let candidateDistance = abs(candidate.referenceTimestamp.timeIntervalSince(comment.createdAt))
        let existingDistance = abs(existing.referenceTimestamp.timeIntervalSince(comment.createdAt))

        if candidateDistance == existingDistance {
            let candidateHasBundle = candidate.appBundleID?.isEmpty == false
            let existingHasBundle = existing.appBundleID?.isEmpty == false
            if candidateHasBundle != existingHasBundle {
                return candidateHasBundle
            }
            return candidate.segmentID.value < existing.segmentID.value
        }

        return candidateDistance < existingDistance
    }
}

struct TimelineCommentSearchState {
    var text: String = ""
    var results: [CommentTimelineRow] = []
    var hasMoreResults = false
    var isSearching = false
    var error: String? = nil
}

struct TimelineCommentSearchRequest: Equatable {
    let query: String
    let offset: Int
    let append: Bool
}

final class TimelineCommentSearchController {
    private(set) var state = TimelineCommentSearchState()

    private var activeQuery: String = ""
    private var nextOffset: Int = 0

    func updateQuery(_ rawQuery: String) -> TimelineCommentSearchRequest? {
        state.text = rawQuery

        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSearchResults()
            return nil
        }

        activeQuery = trimmed
        nextOffset = 0
        state.results = []
        state.hasMoreResults = false
        state.isSearching = true
        state.error = nil

        return TimelineCommentSearchRequest(query: trimmed, offset: 0, append: false)
    }

    func retrySearch() -> TimelineCommentSearchRequest? {
        guard !activeQuery.isEmpty else { return nil }

        nextOffset = 0
        state.results = []
        state.hasMoreResults = false
        state.isSearching = true
        state.error = nil

        return TimelineCommentSearchRequest(query: activeQuery, offset: 0, append: false)
    }

    func loadMoreResultsIfNeeded(currentCommentID: SegmentCommentID?) -> TimelineCommentSearchRequest? {
        guard let currentCommentID,
              currentCommentID == state.results.last?.id,
              !activeQuery.isEmpty,
              state.hasMoreResults,
              !state.isSearching else {
            return nil
        }

        state.isSearching = true
        state.error = nil

        return TimelineCommentSearchRequest(query: activeQuery, offset: nextOffset, append: true)
    }

    @discardableResult
    func applyResults(
        query: String,
        offset: Int,
        append: Bool,
        results: [CommentTimelineRow],
        pageSize: Int
    ) -> Bool {
        guard query == activeQuery else { return false }

        if append {
            state.results.append(contentsOf: results)
        } else {
            state.results = results
        }

        nextOffset = offset + results.count
        state.hasMoreResults = results.count == pageSize
        state.isSearching = false
        state.error = nil
        return true
    }

    @discardableResult
    func applyFailure(
        query: String,
        append: Bool,
        message: String
    ) -> Bool {
        guard query == activeQuery else { return false }

        if !append {
            state.results = []
            state.hasMoreResults = false
        }

        state.error = message
        state.isSearching = false
        return true
    }

    func reset() {
        activeQuery = ""
        nextOffset = 0
        state = TimelineCommentSearchState()
    }

    private func clearSearchResults() {
        activeQuery = ""
        nextOffset = 0
        state.results = []
        state.hasMoreResults = false
        state.isSearching = false
        state.error = nil
    }
}
