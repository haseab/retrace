import Foundation
import Shared

typealias TimelineLinkedSegmentComment = (
    comment: SegmentComment,
    preferredSegmentID: SegmentID
)

struct TimelineCommentThreadSessionState {
    var draftText: String = ""
    var draftAttachments: [CommentAttachmentDraft] = []
    var selectedBlockComments: [SegmentComment] = []
    var isLoadingBlockComments = false
    var blockCommentsLoadError: String? = nil
    var isAddingComment = false
}

enum TimelineCommentThreadLoadAction {
    case awaitExisting(Task<Void, Never>)
    case start(version: UInt64)
}

final class TimelineCommentThreadSessionController {
    private(set) var state = TimelineCommentThreadSessionState()

    private var preferredSegmentByCommentID: [Int64: SegmentID] = [:]
    private var activeLoadSegmentIDValues: [Int64]?
    private var loadTask: Task<Void, Never>?
    private var loadVersion: UInt64 = 0

    func setDraftText(_ text: String) {
        state.draftText = text
    }

    func setDraftAttachments(_ attachments: [CommentAttachmentDraft]) {
        state.draftAttachments = attachments
    }

    func setSelectedBlockComments(_ comments: [SegmentComment]) {
        state.selectedBlockComments = comments
        let validCommentIDs = Set(comments.map(\.id.value))
        preferredSegmentByCommentID = preferredSegmentByCommentID.filter { validCommentIDs.contains($0.key) }
    }

    func setIsLoadingBlockComments(_ isLoading: Bool) {
        state.isLoadingBlockComments = isLoading
    }

    func setBlockCommentsLoadError(_ error: String?) {
        state.blockCommentsLoadError = error
    }

    func setIsAddingComment(_ isAdding: Bool) {
        state.isAddingComment = isAdding
    }

    func appendDraftSnippet(_ snippet: String) {
        let trimmedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSnippet.isEmpty else { return }

        let current = state.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            state.draftText = trimmedSnippet
            return
        }

        if state.draftText.hasSuffix("\n\n") || state.draftText.hasSuffix(" ") {
            state.draftText += trimmedSnippet
        } else if state.draftText.hasSuffix("\n") {
            state.draftText += trimmedSnippet
        } else {
            state.draftText += "\n\(trimmedSnippet)"
        }
    }

    func removeDraftAttachment(_ draft: CommentAttachmentDraft) {
        state.draftAttachments.removeAll { $0.id == draft.id }
    }

    func preferredSegmentID(for commentID: SegmentCommentID) -> SegmentID? {
        preferredSegmentByCommentID[commentID.value]
    }

    @discardableResult
    func removeSelectedBlockComment(_ commentID: SegmentCommentID) -> Bool {
        let previousCount = state.selectedBlockComments.count
        state.selectedBlockComments.removeAll { $0.id == commentID }
        preferredSegmentByCommentID.removeValue(forKey: commentID.value)
        return state.selectedBlockComments.count != previousCount
    }

    func beginCommentsLoad(
        requestSegmentIDValues: [Int64],
        forceRefresh: Bool
    ) -> TimelineCommentThreadLoadAction {
        if !forceRefresh,
           activeLoadSegmentIDValues == requestSegmentIDValues,
           let loadTask {
            return .awaitExisting(loadTask)
        }

        loadTask?.cancel()
        activeLoadSegmentIDValues = requestSegmentIDValues
        loadVersion &+= 1
        state.isLoadingBlockComments = true
        state.blockCommentsLoadError = nil
        return .start(version: loadVersion)
    }

    func setLoadTask(_ task: Task<Void, Never>?) {
        loadTask = task
    }

    @discardableResult
    func applyLoadedComments(
        _ linkedComments: [TimelineLinkedSegmentComment],
        version: UInt64
    ) -> Bool {
        guard loadVersion == version else { return false }

        state.selectedBlockComments = linkedComments.map(\.comment)
        preferredSegmentByCommentID = Dictionary(
            uniqueKeysWithValues: linkedComments.map { ($0.comment.id.value, $0.preferredSegmentID) }
        )
        state.blockCommentsLoadError = nil
        return true
    }

    @discardableResult
    func applyLoadFailure(
        version: UInt64,
        message: String
    ) -> Bool {
        guard loadVersion == version else { return false }

        state.selectedBlockComments = []
        preferredSegmentByCommentID = [:]
        state.blockCommentsLoadError = message
        return true
    }

    @discardableResult
    func finishCommentsLoad(version: UInt64) -> Bool {
        guard loadVersion == version else { return false }

        loadTask = nil
        activeLoadSegmentIDValues = nil
        state.isLoadingBlockComments = false
        return true
    }

    func cancelCommentsLoad() {
        loadTask?.cancel()
        loadTask = nil
        activeLoadSegmentIDValues = nil
        loadVersion &+= 1
        state.isLoadingBlockComments = false
    }

    func clearThreadComments() {
        state.selectedBlockComments = []
        preferredSegmentByCommentID = [:]
        state.blockCommentsLoadError = nil
        state.isLoadingBlockComments = false
    }

    func resetDraft() {
        state.draftText = ""
        state.draftAttachments = []
    }

    func resetSession() {
        cancelCommentsLoad()
        clearThreadComments()
        resetDraft()
        state.isAddingComment = false
    }
}

struct TimelineCommentOverlaySessionState {
    var showTagSubmenu = false
    var showCommentSubmenu = false
    var isCommentLinkPopoverPresented = false
    var closeCommentLinkPopoverSignal = 0
    var showNewTagInput = false
    var newTagName = ""
    var isAllCommentsBrowserActive = false
    var returnToThreadCommentsSignal = 0
    var isHoveringAddTagButton = false
    var isHoveringAddCommentButton = false
}

final class TimelineCommentOverlaySessionController {
    private(set) var state = TimelineCommentOverlaySessionState()

    func setShowTagSubmenu(_ isVisible: Bool) {
        state.showTagSubmenu = isVisible
    }

    func setShowCommentSubmenu(_ isVisible: Bool) {
        state.showCommentSubmenu = isVisible
    }

    func setCommentLinkPopoverPresented(_ isPresented: Bool) {
        state.isCommentLinkPopoverPresented = isPresented
    }

    func setShowNewTagInput(_ isVisible: Bool) {
        state.showNewTagInput = isVisible
    }

    func setNewTagName(_ name: String) {
        state.newTagName = name
    }

    func setAllCommentsBrowserActive(_ isActive: Bool) {
        state.isAllCommentsBrowserActive = isActive
    }

    func setHoveringAddTagButton(_ isHovering: Bool) {
        state.isHoveringAddTagButton = isHovering
    }

    func setHoveringAddCommentButton(_ isHovering: Bool) {
        state.isHoveringAddCommentButton = isHovering
    }

    func requestCloseCommentLinkPopover() {
        state.closeCommentLinkPopoverSignal &+= 1
    }

    func requestReturnToThreadComments() {
        state.returnToThreadCommentsSignal &+= 1
    }

    func resetAll() {
        state = TimelineCommentOverlaySessionState()
    }

    func dismissCommentSubmenuForFadeOut() {
        state.showCommentSubmenu = false
        state.isCommentLinkPopoverPresented = false
        state.showTagSubmenu = false
    }

    func closeTagSubmenuPreservingDraft() {
        state.showTagSubmenu = false
    }

    func dismissContextMenuSubmenus() {
        state.showTagSubmenu = false
        state.showCommentSubmenu = false
        state.showNewTagInput = false
        state.newTagName = ""
    }

    func prepareForTimelineContextMenuPresentation() {
        resetAll()
    }

    func prepareForCommentSubmenuPresentation() {
        state.showTagSubmenu = false
        state.showCommentSubmenu = true
        state.isHoveringAddTagButton = false
        state.isHoveringAddCommentButton = false
    }

    func prepareForTagSubmenuPresentation() {
        state.showNewTagInput = false
        state.newTagName = ""
        state.showTagSubmenu = true
        state.showCommentSubmenu = false
        state.isHoveringAddTagButton = true
        state.isHoveringAddCommentButton = false
    }

    func presentTagSubmenuInsideComment() {
        state.showCommentSubmenu = true
        state.showTagSubmenu = true
    }

    func showTagSubmenuFromContextMenu() {
        state.showCommentSubmenu = false
        state.showTagSubmenu = true
    }

    func toggleTagSubmenuFromContextMenu() {
        state.showCommentSubmenu = false
        state.showTagSubmenu.toggle()
    }

    func presentCommentSubmenuFromContextMenu() {
        state.showTagSubmenu = false
        state.showCommentSubmenu = true
    }

    func dismissTagEditing() {
        state.showTagSubmenu = false
        state.showNewTagInput = false
        state.newTagName = ""
        state.isHoveringAddTagButton = false
    }
}

struct TimelineTagIndicatorState {
    var availableTags: [Tag] = []
    var selectedSegmentTags: Set<TagID> = []
    var segmentTagsMap: [Int64: Set<Int64>] = [:]
    var segmentCommentCountsMap: [Int64: Int] = [:]
    var hasLoadedAvailableTags = false
    var hasLoadedSegmentTagsMap = false
    var hasLoadedSegmentCommentCountsMap = false
}

final class TimelineTagIndicatorStateController {
    private(set) var state = TimelineTagIndicatorState()

    func setAvailableTags(_ tags: [Tag]) {
        state.availableTags = tags
        state.hasLoadedAvailableTags = true
    }

    func setSelectedSegmentTags(_ tagIDs: Set<TagID>) {
        state.selectedSegmentTags = tagIDs
    }

    func clearSelectedSegmentTags() {
        state.selectedSegmentTags = []
    }

    func setSegmentTagsMap(_ map: [Int64: Set<Int64>]) {
        state.segmentTagsMap = map
        state.hasLoadedSegmentTagsMap = true
    }

    func setSegmentCommentCountsMap(_ map: [Int64: Int]) {
        state.segmentCommentCountsMap = map
        state.hasLoadedSegmentCommentCountsMap = true
    }

    func resetLoadedState() {
        state.hasLoadedAvailableTags = false
        state.hasLoadedSegmentTagsMap = false
        state.hasLoadedSegmentCommentCountsMap = false
    }

    func selectTag(_ tagID: TagID) {
        state.selectedSegmentTags.insert(tagID)
    }

    func deselectTag(_ tagID: TagID) {
        state.selectedSegmentTags.remove(tagID)
    }

    func appendAvailableTagIfNeeded(_ tag: Tag) {
        guard !state.availableTags.contains(where: { $0.id == tag.id }) else { return }
        state.availableTags.append(tag)
        state.availableTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func addTagToSegments(tagID: TagID, segmentIDs: Set<SegmentID>) {
        guard !segmentIDs.isEmpty else { return }

        var updatedMap = state.segmentTagsMap
        for segmentID in segmentIDs {
            var tags = updatedMap[segmentID.value] ?? Set<Int64>()
            tags.insert(tagID.value)
            updatedMap[segmentID.value] = tags
        }
        state.segmentTagsMap = updatedMap
    }

    func removeTagFromSegments(tagID: TagID, segmentIDs: Set<SegmentID>) {
        guard !segmentIDs.isEmpty else { return }

        var updatedMap = state.segmentTagsMap
        for segmentID in segmentIDs {
            guard var tags = updatedMap[segmentID.value] else { continue }
            tags.remove(tagID.value)
            if tags.isEmpty {
                updatedMap.removeValue(forKey: segmentID.value)
            } else {
                updatedMap[segmentID.value] = tags
            }
        }
        state.segmentTagsMap = updatedMap
    }

    func incrementCommentCounts(for segmentIDs: Set<SegmentID>) {
        guard !segmentIDs.isEmpty else { return }

        var updatedMap = state.segmentCommentCountsMap
        for segmentID in segmentIDs {
            updatedMap[segmentID.value, default: 0] += 1
        }
        state.segmentCommentCountsMap = updatedMap
    }

    func decrementCommentCounts(for segmentIDs: Set<SegmentID>) {
        guard !segmentIDs.isEmpty else { return }

        var updatedMap = state.segmentCommentCountsMap
        for segmentID in segmentIDs {
            let current = updatedMap[segmentID.value] ?? 0
            if current <= 1 {
                updatedMap.removeValue(forKey: segmentID.value)
            } else {
                updatedMap[segmentID.value] = current - 1
            }
        }
        state.segmentCommentCountsMap = updatedMap
    }
}
