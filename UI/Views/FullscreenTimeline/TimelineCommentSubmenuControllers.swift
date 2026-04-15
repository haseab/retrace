import AppKit
import Shared
import SwiftUI

@MainActor
final class TimelineCommentSubmenuBrowserController: ObservableObject {
    @Published private(set) var mode: TimelineCommentSubmenuBrowserMode = .thread
    @Published private(set) var highlightedCommentID: SegmentCommentID?

    var isBrowsingAllComments: Bool {
        mode == .allComments
    }

    func resetForAppear() {
        mode = .thread
        highlightedCommentID = nil
    }

    func enterAllComments() {
        mode = .allComments
        highlightedCommentID = nil
    }

    func exitAllComments() {
        mode = .thread
        highlightedCommentID = nil
    }

    func setHighlightedCommentID(_ highlightedCommentID: SegmentCommentID?) {
        self.highlightedCommentID = highlightedCommentID
    }

    func syncHighlightedSelection(
        resultIDs: [SegmentCommentID],
        preferredAnchorID: SegmentCommentID?
    ) {
        highlightedCommentID = TimelineCommentBrowserKeyboardSupport.syncedHighlightedID(
            isBrowsingAllComments: isBrowsingAllComments,
            currentHighlightedID: highlightedCommentID,
            resultIDs: resultIDs,
            preferredAnchorID: preferredAnchorID
        )
    }

    func moveHighlightedSelection(
        by delta: Int,
        resultIDs: [SegmentCommentID],
        preferredAnchorID: SegmentCommentID?
    ) {
        highlightedCommentID = TimelineCommentBrowserKeyboardSupport.movedHighlightedID(
            delta: delta,
            currentHighlightedID: highlightedCommentID,
            resultIDs: resultIDs,
            preferredAnchorID: preferredAnchorID
        )
    }

    func seedHighlightedSelectionIfNeeded(
        resultIDs: [SegmentCommentID],
        preferredAnchorID: SegmentCommentID?
    ) {
        highlightedCommentID = TimelineCommentBrowserKeyboardSupport.seededHighlightedID(
            isBrowsingAllComments: isBrowsingAllComments,
            currentHighlightedID: highlightedCommentID,
            resultIDs: resultIDs,
            preferredAnchorID: preferredAnchorID
        )
    }

    func resolvedOpenTarget(
        resultIDs: [SegmentCommentID]
    ) -> TimelineCommentBrowserOpenTarget? {
        guard let openTarget = TimelineCommentBrowserKeyboardSupport.resolvedOpenTarget(
            isBrowsingAllComments: isBrowsingAllComments,
            highlightedID: highlightedCommentID,
            resultIDs: resultIDs
        ) else {
            return nil
        }

        highlightedCommentID = openTarget.resolvedHighlightedID
        return openTarget
    }
}

@MainActor
final class TimelineCommentComposerController: ObservableObject {
    @Published var isEditorFocused = false
    @Published var isLinkPopoverPresented = false
    @Published var pendingLinkURL = ""
    @Published private(set) var editorCommand: CommentEditorCommand = .bold
    @Published private(set) var editorCommandNonce = 0

    var normalizedPendingLinkURL: String? {
        TimelineCommentLinkPopoverSupport.insertCommandURL(from: pendingLinkURL)
    }

    func sendEditorCommand(_ command: CommentEditorCommand) {
        editorCommand = command
        editorCommandNonce += 1
    }

    func presentLinkPopover() {
        isEditorFocused = false
        isLinkPopoverPresented = true
        pendingLinkURL = TimelineCommentLinkPopoverSupport.preparedPendingURL(from: pendingLinkURL)
    }

    func insertLinkFromPopover() -> Bool {
        guard let normalizedPendingLinkURL else { return false }
        sendEditorCommand(.link(url: normalizedPendingLinkURL))
        isLinkPopoverPresented = false
        isEditorFocused = true
        return true
    }

    func dismissLinkPopover(refocusEditor: Bool) {
        isLinkPopoverPresented = false
        isEditorFocused = refocusEditor
    }
}

@MainActor
final class TimelineCommentDeletionController: ObservableObject {
    @Published var pendingComment: SegmentComment?
    @Published var isDeleting = false

    func requestDelete(_ comment: SegmentComment) {
        pendingComment = comment
        isDeleting = false
    }

    func dismiss() {
        pendingComment = nil
        isDeleting = false
    }

    func confirmDeletion(
        delete: @escaping (SegmentComment) async -> Bool
    ) async -> SegmentCommentID? {
        guard let pendingComment else { return nil }

        isDeleting = true
        let didDelete = await delete(pendingComment)
        isDeleting = false

        if didDelete {
            self.pendingComment = nil
            return pendingComment.id
        }

        return nil
    }
}

@MainActor
final class TimelineCommentTargetPreviewController: ObservableObject {
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var isLoading = false

    private var currentTargetFrameID: FrameID?
    private var loadRevision = 0

    func refresh(
        context: TimelineCommentTargetPreviewContext,
        loadFrame: @escaping (FrameID) async -> NSImage?
    ) async {
        currentTargetFrameID = context.targetFrameID
        loadRevision += 1
        let revision = loadRevision

        switch TimelineCommentInteractionSupport.previewLoadAction(
            isInLiveMode: context.isInLiveMode,
            liveScreenshot: context.liveScreenshot,
            targetFrameID: context.targetFrameID
        ) {
        case .showLiveScreenshot:
            previewImage = context.liveScreenshot
            isLoading = false
        case .clear:
            previewImage = nil
            isLoading = false
        case .loadFrame(let frameID):
            isLoading = true
            let loadedImage = await loadFrame(frameID)
            guard revision == loadRevision,
                  TimelineCommentInteractionSupport.shouldApplyLoadedPreview(
                    isTaskCancelled: Task.isCancelled,
                    requestedFrameID: frameID,
                    currentTargetFrameID: currentTargetFrameID
                  ) else {
                return
            }
            previewImage = loadedImage
            isLoading = false
        }
    }

    func reset() {
        loadRevision += 1
        currentTargetFrameID = nil
        previewImage = nil
        isLoading = false
    }
}

@MainActor
final class TimelineCommentSubmenuInteractionController: ObservableObject {
    private var keyboardMonitor: Any?

    deinit {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func installKeyboardMonitor(handleEvent: @escaping (NSEvent) -> Bool) {
        removeKeyboardMonitor()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handleEvent(event) {
                return nil
            }
            return event
        }
    }

    func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }
}

@MainActor
final class TimelineCommentSubmenuNavigationController: ObservableObject {
    @Published private(set) var isNavigatingLinkedCommentFrame = false

    func openLinkedComment(
        _ comment: SegmentComment,
        preferredSegmentID: SegmentID? = nil,
        navigate: @escaping (TimelineCommentNavigationRequest) async -> Bool,
        onClose: @escaping () -> Void
    ) {
        guard let request = TimelineCommentInteractionSupport.navigationRequest(
            isNavigating: isNavigatingLinkedCommentFrame,
            comment: comment,
            preferredSegmentID: preferredSegmentID
        ) else {
            return
        }

        isNavigatingLinkedCommentFrame = true
        Task { @MainActor in
            defer { isNavigatingLinkedCommentFrame = false }
            let didNavigate = await navigate(request)
            if TimelineCommentInteractionSupport.shouldCloseSubmenu(afterNavigation: didNavigate) {
                onClose()
            }
        }
    }
}
