import App
import AppKit
import Foundation
import Shared
import SwiftUI

extension SimpleTimelineViewModel {
    // MARK: - Context Menu State

    /// Whether the right-click context menu is visible
    public private(set) var showContextMenu: Bool {
        get { shellUIState.showContextMenu }
        set { shellUIState.showContextMenu = newValue }
    }

    /// Location where the context menu should appear
    public private(set) var contextMenuLocation: CGPoint {
        get { shellUIState.contextMenuLocation }
        set { shellUIState.contextMenuLocation = newValue }
    }

    /// Dismiss the context menu if it's visible
    public func dismissContextMenu() {
        if showContextMenu {
            withAnimation(.easeOut(duration: 0.16)) {
                showContextMenu = false
            }
        }
    }

    public func setContextMenuVisible(_ isVisible: Bool) {
        showContextMenu = isVisible
    }

    public func presentContextMenu(at location: CGPoint) {
        contextMenuLocation = location
        showContextMenu = true
    }

    enum TimelineContextMenuPresentationSource {
        case secondaryClick
        case actionBubble
    }

    enum TimelineContextMenuDismissReason {
        case standard
        case scroll
    }

    // MARK: - Timeline Context Menu State (for right-click on timeline tape)

    /// Whether the timeline context menu is visible
    public private(set) var showTimelineContextMenu: Bool {
        get { shellUIState.showTimelineContextMenu }
        set { shellUIState.showTimelineContextMenu = newValue }
    }

    /// Location where the timeline context menu should appear
    public private(set) var timelineContextMenuLocation: CGPoint {
        get { shellUIState.timelineContextMenuLocation }
        set { shellUIState.timelineContextMenuLocation = newValue }
    }

    /// The segment index that was right-clicked on the timeline
    public internal(set) var timelineContextMenuSegmentIndex: Int? {
        get { shellUIState.timelineContextMenuSegmentIndex }
        set { shellUIState.timelineContextMenuSegmentIndex = newValue }
    }

    /// Whether to show the top hint teaching that the tape also supports right-click.
    public var showTimelineTapeRightClickHintBanner: Bool {
        get { shellUIState.showTimelineTapeRightClickHintBanner }
        set { shellUIState.showTimelineTapeRightClickHintBanner = newValue }
    }

    /// Whether the tag submenu is visible
    public var showTagSubmenu: Bool { commentsStore.overlayState.showTagSubmenu }

    /// Whether the comment submenu is visible
    public var showCommentSubmenu: Bool { commentsStore.overlayState.showCommentSubmenu }

    /// Whether the comment link insert popover is currently visible.
    /// Used so Escape can dismiss the popover before dismissing the full comment submenu.
    public var isCommentLinkPopoverPresented: Bool { commentsStore.overlayState.isCommentLinkPopoverPresented }

    /// Signal to request that the comment link popover close.
    public var closeCommentLinkPopoverSignal: Int { commentsStore.overlayState.closeCommentLinkPopoverSignal }

    /// Whether the "create new tag" input is visible
    public var showNewTagInput: Bool { commentsStore.overlayState.showNewTagInput }

    /// Text for the new tag name input
    public var newTagName: String { commentsStore.overlayState.newTagName }

    /// Text for the new comment body
    public var newCommentText: String { commentsStore.threadState.draftText }

    /// Draft file attachments for the pending comment
    public var newCommentAttachmentDrafts: [CommentAttachmentDraft] { commentsStore.threadState.draftAttachments }

    /// Existing comments linked to the currently selected timeline block thread.
    public var selectedBlockComments: [SegmentComment] { commentsStore.threadState.selectedBlockComments }

    /// Whether existing comments are loading for the currently selected segment thread.
    public var isLoadingBlockComments: Bool { commentsStore.threadState.isLoadingBlockComments }

    /// Optional error surfaced when loading selected segment comments fails
    public var blockCommentsLoadError: String? { commentsStore.threadState.blockCommentsLoadError }

    /// Flattened timeline rows for "All Comments" browsing.
    public var commentTimelineRows: [CommentTimelineRow] { commentsStore.timelineState.rows }

    /// Anchor comment for the all-comments timeline view.
    public var commentTimelineAnchorCommentID: SegmentCommentID? { commentsStore.timelineState.anchorCommentID }

    /// Whether the all-comments timeline is currently loading its initial data.
    public var isLoadingCommentTimeline: Bool { commentsStore.timelineState.isLoadingTimeline }

    /// Whether older all-comments pages are currently being fetched.
    public var isLoadingOlderCommentTimeline: Bool { commentsStore.timelineState.isLoadingOlderPage }

    /// Whether newer all-comments pages are currently being fetched.
    public var isLoadingNewerCommentTimeline: Bool { commentsStore.timelineState.isLoadingNewerPage }

    /// Optional error surfaced when loading all-comments timeline fails.
    public var commentTimelineLoadError: String? { commentsStore.timelineState.loadError }

    /// Whether older comment pages are still available.
    public var commentTimelineHasOlder: Bool { commentsStore.timelineState.hasOlderPages }

    /// Whether newer comment pages are still available.
    public var commentTimelineHasNewer: Bool { commentsStore.timelineState.hasNewerPages }

    /// Raw query text for comment search in the all-comments panel.
    public var commentSearchText: String { commentsStore.searchState.text }

    /// Server-side search results (capped).
    public var commentSearchResults: [CommentTimelineRow] { commentsStore.searchState.results }

    /// Whether there are additional server-side comment search results to page in.
    public var commentSearchHasMoreResults: Bool { commentsStore.searchState.hasMoreResults }

    /// Whether a server-side comment search request is in flight.
    public var isSearchingComments: Bool { commentsStore.searchState.isSearching }

    /// Optional error surfaced when searching comments fails.
    public var commentSearchError: String? { commentsStore.searchState.error }

    /// Whether the comment submenu is currently showing the all-comments browser.
    /// Used by window-level keyboard handling (Escape/Cmd+[) to route back to thread mode.
    public var isAllCommentsBrowserActive: Bool { commentsStore.overlayState.isAllCommentsBrowserActive }

    /// Signal to request return from all-comments browser back to local thread comments.
    public var returnToThreadCommentsSignal: Int { commentsStore.overlayState.returnToThreadCommentsSignal }

    /// Whether the mouse is hovering over the "Add Tag" button
    public var isHoveringAddTagButton: Bool { commentsStore.overlayState.isHoveringAddTagButton }

    /// Whether the mouse is hovering over the "Add Comment" button
    public var isHoveringAddCommentButton: Bool { commentsStore.overlayState.isHoveringAddCommentButton }

    /// Whether a comment creation request is currently in flight
    public var isAddingComment: Bool { commentsStore.threadState.isAddingComment }

    /// All available tags
    public var availableTags: [Tag] { commentsStore.tagIndicatorState.availableTags }

    /// Tags applied to the currently selected segment (for showing checkmarks)
    public var selectedSegmentTags: Set<TagID> { commentsStore.tagIndicatorState.selectedSegmentTags }

    /// Range of frame indices for the segment block currently being hidden with squeeze animation
    public internal(set) var hidingSegmentBlockRange: ClosedRange<Int>? {
        get { shellUIState.hidingSegmentBlockRange }
        set { shellUIState.hidingSegmentBlockRange = newValue }
    }

    /// Dismiss the timeline context menu
    public func dismissTimelineContextMenu() {
        dismissTimelineContextMenu(reason: .standard)
    }

    public func setTimelineContextMenuAnchorIndex(_ index: Int?) {
        timelineContextMenuSegmentIndex = index
    }

    public func setTimelineContextMenuVisible(_ isVisible: Bool) {
        showTimelineContextMenu = isVisible
    }

    public func prepareTimelineContextMenuSelection(
        index: Int,
        location: CGPoint? = nil
    ) {
        timelineContextMenuSegmentIndex = index
        selectedFrameIndex = index
        if let location {
            timelineContextMenuLocation = location
        }
    }

    func dismissTimelineContextMenu(reason: TimelineContextMenuDismissReason) {
        let shouldShowRightClickHint =
            reason == .scroll &&
            timelineContextMenuPresentationSource == .actionBubble &&
            showTimelineContextMenu &&
            !showTagSubmenu &&
            !showCommentSubmenu &&
            !showNewTagInput

        let resetMenuState = {
            self.commentsStore.resetTimelineContextSession(invalidate: self.notifyCommentStateWillChange)
            self.showTimelineContextMenu = false
            self.timelineContextMenuPresentationSource = nil
        }

        let shouldAnimate = showTimelineContextMenu || showTagSubmenu || showCommentSubmenu || showNewTagInput
        if shouldAnimate {
            withAnimation(.easeOut(duration: Self.timelineMenuDismissAnimationDuration)) {
                resetMenuState()
            }
        } else {
            resetMenuState()
        }

        if shouldShowRightClickHint {
            showTimelineTapeRightClickHint()
        }
    }

    /// Dismiss only the comment submenu with an explicit fade-out phase.
    /// This avoids tearing down comment state in the same frame as the transition.
    public func dismissCommentSubmenu() {
        guard showCommentSubmenu else { return }

        withAnimation(.easeOut(duration: Self.timelineMenuDismissAnimationDuration)) {
            self.commentsStore.beginCommentSubmenuDismissal(invalidate: self.notifyCommentStateWillChange)
            self.showTimelineContextMenu = false
            self.showContextMenu = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timelineMenuDismissAnimationDuration) { [weak self] in
            guard let self else { return }
            guard !self.showCommentSubmenu else { return }

            self.commentsStore.finalizeCommentSubmenuDismissal(invalidate: self.notifyCommentStateWillChange)
            self.timelineContextMenuPresentationSource = nil
            self.currentCommentMetricsSource = "timeline_comment_submenu"
        }
    }

    public func requestCloseCommentLinkPopover() {
        commentsStore.requestCloseCommentLinkPopover(invalidate: notifyCommentStateWillChange)
    }

    public func setCommentLinkPopoverPresented(_ isPresented: Bool) {
        commentsStore.setCommentLinkPopoverPresented(
            isPresented,
            invalidate: notifyCommentStateWillChange
        )
    }

    public func requestReturnToThreadComments() {
        commentsStore.requestReturnToThreadComments(invalidate: notifyCommentStateWillChange)
    }

    public func setAllCommentsBrowserActive(_ isActive: Bool) {
        commentsStore.setAllCommentsBrowserActive(isActive, invalidate: notifyCommentStateWillChange)
    }

    public func setHoveringAddTagButton(_ isHovering: Bool) {
        commentsStore.setHoveringAddTagButton(isHovering, invalidate: notifyCommentStateWillChange)
    }

    public func setHoveringAddCommentButton(_ isHovering: Bool) {
        commentsStore.setHoveringAddCommentButton(
            isHovering,
            invalidate: notifyCommentStateWillChange
        )
    }

    public func closeTagSubmenuPreservingDraft() {
        commentsStore.closeTagSubmenuPreservingDraft(invalidate: notifyCommentStateWillChange)
    }

    public func dismissTagEditing() {
        commentsStore.dismissTagEditing(invalidate: notifyCommentStateWillChange)
    }

    public func dismissTimelineContextSubmenus() {
        commentsStore.dismissContextMenuSubmenus(invalidate: notifyCommentStateWillChange)
    }

    func setTagSubmenuVisible(_ isVisible: Bool) {
        commentsStore.setTagSubmenuVisible(isVisible, invalidate: notifyCommentStateWillChange)
    }

    func setCommentSubmenuVisible(_ isVisible: Bool) {
        commentsStore.setCommentSubmenuVisible(isVisible, invalidate: notifyCommentStateWillChange)
    }

    func setNewTagInputVisible(_ isVisible: Bool) {
        commentsStore.setNewTagInputVisible(isVisible, invalidate: notifyCommentStateWillChange)
    }

    func setNewTagDraftName(_ name: String) {
        commentsStore.setNewTagName(name, invalidate: notifyCommentStateWillChange)
    }

    public func setCommentDraftText(_ text: String) {
        commentsStore.setDraftText(text, invalidate: notifyCommentStateWillChange)
    }

    // MARK: - Context Menu Operations

    public func loadTimelineContextMenuData() async {
        async let tagsTask: Void = loadTags()
        async let commentsTask: Void = loadCommentsForSelectedTimelineBlock()
        _ = await (tagsTask, commentsTask)
    }

    @discardableResult
    func presentTimelineContextMenu(
        at anchorIndex: Int,
        menuLocation: CGPoint? = nil,
        source: TimelineContextMenuPresentationSource
    ) -> Bool {
        guard anchorIndex >= 0, anchorIndex < frames.count else { return false }

        clearTimelineTapeRightClickHint()
        commentsStore.resetThreadSession(invalidate: notifyCommentStateWillChange)
        commentsStore.prepareForTimelineContextMenuPresentation(invalidate: notifyCommentStateWillChange)
        timelineContextMenuSegmentIndex = anchorIndex
        selectedFrameIndex = anchorIndex
        commentsStore.clearSelectedSegmentTags(invalidate: notifyCommentStateWillChange)
        timelineContextMenuPresentationSource = source
        resetCommentTimelineState()

        if let resolvedLocation = menuLocation ?? currentMouseLocationInContentCoordinates() {
            timelineContextMenuLocation = resolvedLocation
        }

        showTimelineContextMenu = true
        return true
    }

    public func openTimelineContextMenu(at anchorIndex: Int, menuLocation: CGPoint? = nil) {
        guard presentTimelineContextMenu(
            at: anchorIndex,
            menuLocation: menuLocation,
            source: .secondaryClick
        ) else { return }
        Task { await loadTimelineContextMenuData() }
    }

    public func openTimelineContextMenuForTimelineBlock(_ block: AppBlock) {
        guard block.frameCount > 0 else { return }

        let anchorIndex = Self.resolvePreferredCommentTargetIndex(
            in: block,
            currentIndex: currentIndex,
            selectedFrameIndex: selectedFrameIndex,
            timelineContextMenuSegmentIndex: timelineContextMenuSegmentIndex
        )
        guard presentTimelineContextMenu(
            at: anchorIndex,
            source: .actionBubble
        ) else { return }
        Task { await loadTimelineContextMenuData() }
    }

    public func recordTagSubmenuOpen(source: String, block: AppBlock? = nil) {
        let resolvedBlock: AppBlock?
        if let block {
            resolvedBlock = block
        } else if let index = timelineContextMenuSegmentIndex {
            resolvedBlock = getBlock(forFrameAt: index)
        } else {
            resolvedBlock = nil
        }

        let segmentCount = resolvedBlock.map { getSegmentIds(inBlock: $0).count }
        let frameCount = resolvedBlock?.frameCount
        let selectedTagCount = resolvedBlock?.tagIDs.count ?? selectedSegmentTags.count

        DashboardViewModel.recordTagSubmenuOpen(
            coordinator: coordinator,
            source: source,
            segmentCount: segmentCount,
            frameCount: frameCount,
            selectedTagCount: selectedTagCount
        )
    }

    public func recordCommentSubmenuOpen(source: String, block: AppBlock? = nil) {
        let resolvedBlock: AppBlock?
        if let block {
            resolvedBlock = block
        } else if let index = timelineContextMenuSegmentIndex {
            resolvedBlock = getBlock(forFrameAt: index)
        } else {
            resolvedBlock = nil
        }

        DashboardViewModel.recordCommentSubmenuOpen(
            coordinator: coordinator,
            source: source,
            segmentCount: resolvedBlock.map { getSegmentIds(inBlock: $0).count },
            frameCount: resolvedBlock?.frameCount,
            existingCommentCount: selectedBlockComments.count
        )
    }

    public func showTagSubmenuFromContextMenu(source: String) {
        let shouldRecord = !showTagSubmenu
        commentsStore.showTagSubmenuFromContextMenu(invalidate: notifyCommentStateWillChange)

        if shouldRecord && showTagSubmenu {
            recordTagSubmenuOpen(source: source)
        }
    }

    public func toggleTagSubmenuFromContextMenu(source: String) {
        let shouldRecord = !showTagSubmenu
        commentsStore.toggleTagSubmenuFromContextMenu(invalidate: notifyCommentStateWillChange)

        if shouldRecord && showTagSubmenu {
            recordTagSubmenuOpen(source: source)
        }
    }

    public func openCommentSubmenuFromContextMenu(source: String = "context_menu_click") {
        commentsStore.presentCommentSubmenuFromContextMenu(invalidate: notifyCommentStateWillChange)
        showTimelineContextMenu = false
        currentCommentMetricsSource = source
        recordCommentSubmenuOpen(source: source)
        Task { await loadCommentsForSelectedTimelineBlock() }
    }

    public func presentTagSubmenuInExistingContextMenu(source: String) {
        commentsStore.prepareForTagSubmenuPresentation(invalidate: notifyCommentStateWillChange)
        recordTagSubmenuOpen(source: source)
    }

    public func openTagSubmenuForTimelineBlock(_ block: AppBlock, source: String = "timeline_block") {
        guard block.frameCount > 0 else { return }
        let anchorIndex = Self.resolveTagSubmenuAnchorIndex(
            requestedIndex: block.startIndex,
            in: block
        )
        openTagSubmenu(at: anchorIndex, in: block, source: source)
    }

    public func openTagSubmenuForSelectedCommentTarget(source: String = "comment_target_add_tag") {
        guard let selectionIndex = selectedCommentTargetIndex,
              selectionIndex >= 0,
              selectionIndex < frames.count,
              let block = getBlock(forFrameAt: selectionIndex) else {
            return
        }

        let anchorIndex = Self.resolveTagSubmenuAnchorIndex(
            requestedIndex: selectionIndex,
            in: block
        )

        timelineContextMenuSegmentIndex = anchorIndex
        selectedFrameIndex = anchorIndex

        if showTagSubmenu {
            withAnimation(.easeOut(duration: Self.timelineMenuDismissAnimationDuration)) {
                commentsStore.setTagSubmenuVisible(false, invalidate: notifyCommentStateWillChange)
            }
            return
        }

        clearTimelineTapeRightClickHint()
        withAnimation(.easeOut(duration: Self.timelineMenuDismissAnimationDuration)) {
            showTimelineContextMenu = false
            commentsStore.presentTagSubmenuInsideComment(invalidate: notifyCommentStateWillChange)
        }
        timelineContextMenuPresentationSource = nil
        recordTagSubmenuOpen(source: source, block: block)

        Task { await loadTags() }
    }

    public func openCommentSubmenuForTimelineBlock(_ block: AppBlock, source: String = "timeline_block") {
        guard block.frameCount > 0 else { return }

        let anchorIndex = Self.resolvePreferredCommentTargetIndex(
            in: block,
            currentIndex: currentIndex,
            selectedFrameIndex: selectedFrameIndex,
            timelineContextMenuSegmentIndex: timelineContextMenuSegmentIndex
        )
        clearTimelineTapeRightClickHint()
        timelineContextMenuSegmentIndex = anchorIndex
        selectedFrameIndex = anchorIndex
        commentsStore.resetThreadSession(invalidate: notifyCommentStateWillChange)
        resetCommentTimelineState()
        commentsStore.prepareForCommentSubmenuPresentation(invalidate: notifyCommentStateWillChange)
        currentCommentMetricsSource = source
        timelineContextMenuPresentationSource = nil

        if let pointerLocation = currentMouseLocationInContentCoordinates() {
            timelineContextMenuLocation = pointerLocation
        }

        showTimelineContextMenu = false
        recordCommentSubmenuOpen(source: source, block: block)

        Task { await loadCommentsForSelectedTimelineBlock() }
    }

    var selectedCommentTargetIndex: Int? {
        guard let selectionIndex = timelineContextMenuSegmentIndex,
              selectionIndex >= 0,
              selectionIndex < frames.count else {
            return nil
        }

        guard let block = getBlock(forFrameAt: selectionIndex) else {
            return selectionIndex
        }

        return Self.resolvePreferredCommentTargetIndex(
            in: block,
            currentIndex: currentIndex,
            selectedFrameIndex: selectedFrameIndex,
            timelineContextMenuSegmentIndex: timelineContextMenuSegmentIndex
        )
    }

    static func resolvePreferredCommentTargetIndex(
        in block: AppBlock,
        currentIndex: Int,
        selectedFrameIndex: Int?,
        timelineContextMenuSegmentIndex: Int?
    ) -> Int {
        let candidateIndices = [
            currentIndex,
            selectedFrameIndex,
            timelineContextMenuSegmentIndex
        ]

        for candidateIndex in candidateIndices.compactMap({ $0 }) {
            guard candidateIndex >= block.startIndex, candidateIndex <= block.endIndex else { continue }
            return candidateIndex
        }

        return block.startIndex
    }

    static func resolveTagSubmenuAnchorIndex(
        requestedIndex: Int?,
        in block: AppBlock
    ) -> Int {
        guard let requestedIndex,
              requestedIndex >= block.startIndex,
              requestedIndex <= block.endIndex else {
            return block.startIndex
        }

        return requestedIndex
    }

    private func openTagSubmenu(
        at anchorIndex: Int,
        in block: AppBlock,
        source: String
    ) {
        guard anchorIndex >= 0, anchorIndex < frames.count else { return }

        clearTimelineTapeRightClickHint()
        timelineContextMenuSegmentIndex = anchorIndex
        selectedFrameIndex = anchorIndex
        commentsStore.resetThreadSession(invalidate: notifyCommentStateWillChange)
        resetCommentTimelineState()
        commentsStore.prepareForTagSubmenuPresentation(invalidate: notifyCommentStateWillChange)
        timelineContextMenuPresentationSource = nil

        if let pointerLocation = currentMouseLocationInContentCoordinates() {
            timelineContextMenuLocation = pointerLocation
        }

        showTimelineContextMenu = true
        recordTagSubmenuOpen(source: source, block: block)

        Task { await loadTags() }
    }

    private func currentMouseLocationInContentCoordinates() -> CGPoint? {
        let application = NSApplication.shared
        guard let window = application.keyWindow ?? application.mainWindow,
              let contentView = window.contentView else {
            return nil
        }

        let mouseOnScreen = NSEvent.mouseLocation
        let mouseInWindow = window.convertPoint(fromScreen: mouseOnScreen)
        return CGPoint(x: mouseInWindow.x, y: contentView.bounds.height - mouseInWindow.y)
    }
}
