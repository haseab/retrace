import Foundation
import Shared

final class TimelineCommentsStore {
    enum OptimisticSnapshotReason {
        case addTagToSegmentTagsMap
        case removeTagFromSegmentTagsMap
        case incrementCommentCountsForSegments
        case decrementCommentCountsForSegments

        var logLabel: String {
            switch self {
            case .addTagToSegmentTagsMap:
                return "addTagToSegmentTagsMap"
            case .removeTagFromSegmentTagsMap:
                return "removeTagFromSegmentTagsMap"
            case .incrementCommentCountsForSegments:
                return "incrementCommentCountsForSegments"
            case .decrementCommentCountsForSegments:
                return "decrementCommentCountsForSegments"
            }
        }
    }

    struct TagLoadContext {
        let timelineContextMenuSegmentIndex: Int?
        let selectedSegmentID: SegmentID?
    }

    struct TagIndicatorUpdateCallbacks {
        let invalidate: @MainActor () -> Void
        let didUpdateAvailableTags: @MainActor () -> Void
        let didUpdateSegmentTagsMap: @MainActor () -> Void
        let didUpdateSegmentCommentCountsMap: @MainActor () -> Void
    }

    struct OptimisticSnapshotCallbacks {
        let invalidate: @MainActor () -> Void
        let refreshSnapshotImmediately: @MainActor (_ reason: OptimisticSnapshotReason) -> Void
    }

    let timeline = TimelineCommentTimelineController()
    let search = TimelineCommentSearchController()
    let overlayController = TimelineCommentOverlaySessionController()
    let thread = TimelineCommentThreadSessionController()
    let tagIndicatorController = TimelineTagIndicatorStateController()

    var lazyTagIndicatorLoadTask: Task<Void, Never>?
    var tagIndicatorRefreshTask: Task<Void, Never>?
    var tagIndicatorRefreshVersion: UInt64 = 0
    var commentSearchTask: Task<Void, Never>?

    var timelineState: TimelineCommentTimelineState { timeline.state }
    var searchState: TimelineCommentSearchState { search.state }
    var overlayState: TimelineCommentOverlaySessionState { overlayController.state }
    var threadState: TimelineCommentThreadSessionState { thread.state }
    var tagIndicatorState: TimelineTagIndicatorState { tagIndicatorController.state }

    @MainActor
    func preferredSegmentID(for commentID: SegmentCommentID) -> SegmentID? {
        thread.preferredSegmentID(for: commentID)
    }

    @MainActor
    func commentTimelineBoundaryTimestamp(for direction: TimelineCommentTimelineDirection) -> Date? {
        timeline.boundaryTimestamp(for: direction)
    }

    @MainActor
    func resetThreadSession(invalidate: () -> Void) {
        updateThreadState(invalidate: invalidate) { $0.resetSession() }
    }

    @MainActor
    func resetTimelineContextSession(invalidate: () -> Void) {
        resetThreadSession(invalidate: invalidate)
        resetCommentTimelineBrowsing(invalidate: invalidate)
        clearSelectedSegmentTags(invalidate: invalidate)
        updateOverlayState(invalidate: invalidate) { $0.resetAll() }
    }

    @MainActor
    func beginCommentSubmenuDismissal(invalidate: () -> Void) {
        cancelThreadLoad(invalidate: invalidate)
        updateOverlayState(invalidate: invalidate) {
            $0.dismissCommentSubmenuForFadeOut()
        }
    }

    @MainActor
    func finalizeCommentSubmenuDismissal(invalidate: () -> Void) {
        resetThreadSession(invalidate: invalidate)
        resetCommentTimelineBrowsing(invalidate: invalidate)
        updateOverlayState(invalidate: invalidate) { $0.resetAll() }
    }

    @MainActor
    func cancelThreadLoad(invalidate: () -> Void) {
        updateThreadState(invalidate: invalidate) { $0.cancelCommentsLoad() }
    }

    @MainActor
    func setDraftText(_ text: String, invalidate: () -> Void) {
        updateThreadState(invalidate: invalidate) { $0.setDraftText(text) }
    }

    @MainActor
    func setDraftAttachments(_ attachments: [CommentAttachmentDraft], invalidate: () -> Void) {
        updateThreadState(invalidate: invalidate) { $0.setDraftAttachments(attachments) }
    }

    @MainActor
    func appendDraftSnippet(_ snippet: String, invalidate: () -> Void) {
        updateThreadState(invalidate: invalidate) { $0.appendDraftSnippet(snippet) }
    }

    @MainActor
    func removeDraftAttachment(_ draft: CommentAttachmentDraft, invalidate: () -> Void) {
        updateThreadState(invalidate: invalidate) { $0.removeDraftAttachment(draft) }
    }

    @discardableResult
    @MainActor
    func removeSelectedBlockComment(
        _ commentID: SegmentCommentID,
        invalidate: () -> Void
    ) -> Bool {
        updateThreadState(invalidate: invalidate) { $0.removeSelectedBlockComment(commentID) }
    }

    @MainActor
    func removeCommentFromSelectedBlock(
        comment: SegmentComment,
        segmentIDs: [SegmentID],
        fetchCommentsForSegment: @escaping (SegmentID) async throws -> [SegmentComment],
        removeCommentFromSegments: @escaping ([SegmentID], SegmentCommentID) async throws -> Void,
        rowBuilder: @escaping (SegmentComment, CommentTimelineSegmentContext?) -> CommentTimelineRow,
        optimisticCallbacks: OptimisticSnapshotCallbacks? = nil,
        invalidate: @escaping () -> Void
    ) async throws -> Set<SegmentID> {
        var linkedSegmentIDs: Set<SegmentID> = []
        for segmentID in segmentIDs {
            let comments = try await fetchCommentsForSegment(segmentID)
            if comments.contains(where: { $0.id == comment.id }) {
                linkedSegmentIDs.insert(segmentID)
            }
        }

        if !linkedSegmentIDs.isEmpty {
            try await removeCommentFromSegments(Array(linkedSegmentIDs), comment.id)
        }

        _ = removeSelectedBlockComment(comment.id, invalidate: invalidate)
        _ = updateTimelineState(invalidate: invalidate) {
            $0.removeComment(id: comment.id, rowBuilder: rowBuilder)
        }
        if let optimisticCallbacks, !linkedSegmentIDs.isEmpty {
            decrementCommentCounts(
                for: linkedSegmentIDs,
                callbacks: optimisticCallbacks
            )
        }
        return linkedSegmentIDs
    }

    @discardableResult
    @MainActor
    func updateTimelineState<T>(
        invalidate: () -> Void,
        mutation: (TimelineCommentTimelineController) -> T
    ) -> T {
        invalidate()
        return mutation(timeline)
    }

    @discardableResult
    @MainActor
    func updateTimelineState<T>(
        invalidate: () -> Void,
        mutation: (TimelineCommentTimelineController) async throws -> T
    ) async rethrows -> T {
        invalidate()
        return try await mutation(timeline)
    }

    @discardableResult
    @MainActor
    func updateSearchState<T>(
        invalidate: () -> Void,
        mutation: (TimelineCommentSearchController) -> T
    ) -> T {
        invalidate()
        return mutation(search)
    }

    @discardableResult
    @MainActor
    func updateOverlayState<T>(
        invalidate: () -> Void,
        mutation: (TimelineCommentOverlaySessionController) -> T
    ) -> T {
        invalidate()
        return mutation(overlayController)
    }

    @MainActor
    func updateThreadState<T>(
        invalidate: () -> Void,
        mutation: (TimelineCommentThreadSessionController) -> T
    ) -> T {
        invalidate()
        return mutation(thread)
    }

    @MainActor
    func updateTagIndicatorState<T>(
        invalidate: () -> Void,
        mutation: (TimelineTagIndicatorStateController) -> T
    ) -> T {
        invalidate()
        return mutation(tagIndicatorController)
    }
}
