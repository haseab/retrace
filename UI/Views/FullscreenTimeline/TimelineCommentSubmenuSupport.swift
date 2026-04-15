import AppKit
import Shared
import SwiftUI

struct TimelineCommentSubmenuActionExecutionEnvironment {
    let dismissTagSubmenu: () -> Void
    let dismissLinkPopover: () -> Void
    let exitAllComments: () -> Void
    let closeSubmenu: () -> Void
    let openAllComments: () -> Void
    let focusSearchField: () -> Void
    let seedHighlightedSelection: () -> Void
    let moveHighlightedSelection: (Int) -> Void
    let openHighlightedSelection: () -> Bool
}

enum TimelineCommentSubmenuBrowserMode: Equatable {
    case thread
    case allComments
}

struct TimelineCommentSubmenuPresentationState: Equatable {
    let isMounted: Bool
    let visibility: Double
}

enum TimelineCommentSubmenuPresentationTransition: Equatable {
    case none
    case show(shouldPrimeMount: Bool)
    case hide(shouldScheduleUnmount: Bool)
}

struct TimelineCommentSubmenuRoutingEnvironment {
    let dismissPendingDeletion: () -> Void
    let openAllComments: (SegmentComment?) -> Void
    let exitAllComments: () -> Void
    let openLinkedComment: (SegmentComment, SegmentID?) -> Void
    let dismissTagSubmenu: () -> Void
    let dismissLinkPopover: () -> Void
    let closeSubmenu: () -> Void
    let setSearchFieldFocused: (Bool) -> Void
}

struct TimelineCommentSubmenuRoutingActions {
    let openAllComments: () -> Void
    let exitAllComments: () -> Void
    let openLinkedComment: (SegmentComment, SegmentID?) -> Void
    let handleKeyEvent: (UInt16, String?, NSEvent.ModifierFlags) -> Bool
}

struct TimelineCommentNavigationRequest: Equatable {
    let comment: SegmentComment
    let preferredSegmentID: SegmentID?
}

struct TimelineCommentTargetPreviewContext {
    let isInLiveMode: Bool
    let liveScreenshot: NSImage?
    let targetFrameID: FrameID?
}

enum TimelineCommentPreviewLoadAction: Equatable {
    case showLiveScreenshot
    case loadFrame(FrameID)
    case clear
}

enum TimelineCommentLinkPopoverSupport {
    static func preparedPendingURL(from currentValue: String) -> String {
        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "https://" : trimmed
    }

    static func normalizedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        return components.url
    }

    static func insertCommandURL(from value: String) -> String? {
        normalizedURL(from: value)?.absoluteString
    }
}

enum TimelineCommentInteractionSupport {
    static func previewLoadAction(
        isInLiveMode: Bool,
        liveScreenshot: NSImage?,
        targetFrameID: FrameID?
    ) -> TimelineCommentPreviewLoadAction {
        if isInLiveMode, liveScreenshot != nil {
            return .showLiveScreenshot
        }
        if let targetFrameID {
            return .loadFrame(targetFrameID)
        }
        return .clear
    }

    static func shouldApplyLoadedPreview(
        isTaskCancelled: Bool,
        requestedFrameID: FrameID,
        currentTargetFrameID: FrameID?
    ) -> Bool {
        !isTaskCancelled && requestedFrameID == currentTargetFrameID
    }

    static func navigationRequest(
        isNavigating: Bool,
        comment: SegmentComment,
        preferredSegmentID: SegmentID?
    ) -> TimelineCommentNavigationRequest? {
        guard !isNavigating else { return nil }
        return TimelineCommentNavigationRequest(
            comment: comment,
            preferredSegmentID: preferredSegmentID
        )
    }

    static func shouldCloseSubmenu(afterNavigation didNavigate: Bool) -> Bool {
        didNavigate
    }
}

enum TimelineCommentSubmenuActionExecutionSupport {
    static func execute(
        _ action: TimelineCommentBrowserKeyboardAction,
        environment: TimelineCommentSubmenuActionExecutionEnvironment
    ) -> Bool {
        switch action {
        case .none:
            return false
        case .dismissTagSubmenu:
            environment.dismissTagSubmenu()
            return true
        case .dismissLinkPopover:
            environment.dismissLinkPopover()
            return true
        case .exitAllComments:
            environment.exitAllComments()
            return true
        case .closeSubmenu:
            environment.closeSubmenu()
            return true
        case .openAllComments:
            environment.openAllComments()
            return true
        case .focusSearchField:
            environment.focusSearchField()
            return true
        case .seedHighlightedSelection:
            environment.seedHighlightedSelection()
            return true
        case let .moveHighlightedSelection(delta):
            environment.moveHighlightedSelection(delta)
            return true
        case .openHighlightedSelection:
            return environment.openHighlightedSelection()
        }
    }
}

struct TimelineCommentSubmenuKeyboardState {
    let isBrowsingAllComments: Bool
    let hasPendingDeleteConfirmation: Bool
    let isTagSubmenuVisible: Bool
    let isLinkPopoverPresented: Bool
    let isSearchFieldFocused: Bool
    let hasActiveCommentSearch: Bool
    let searchResults: [CommentTimelineRow]
    let visibleRows: [CommentTimelineRow]
    let preferredAnchorID: SegmentCommentID?
}

@MainActor
enum TimelineCommentSubmenuKeyboardController {
    static func makeActionEnvironment(
        browserController: TimelineCommentSubmenuBrowserController,
        state: TimelineCommentSubmenuKeyboardState,
        dismissTagSubmenu: @escaping () -> Void,
        dismissLinkPopover: @escaping () -> Void,
        exitAllComments: @escaping () -> Void,
        closeSubmenu: @escaping () -> Void,
        openAllComments: @escaping () -> Void,
        setSearchFieldFocused: @escaping (Bool) -> Void,
        openLinkedComment: @escaping (SegmentComment, SegmentID?) -> Void
    ) -> TimelineCommentSubmenuActionExecutionEnvironment {
        TimelineCommentSubmenuActionExecutionEnvironment(
            dismissTagSubmenu: dismissTagSubmenu,
            dismissLinkPopover: dismissLinkPopover,
            exitAllComments: exitAllComments,
            closeSubmenu: closeSubmenu,
            openAllComments: openAllComments,
            focusSearchField: {
                setSearchFieldFocused(true)
            },
            seedHighlightedSelection: {
                seedHighlightedSelectionIfNeeded(
                    browserController: browserController,
                    state: state
                )
            },
            moveHighlightedSelection: { delta in
                moveHighlightedSelection(
                    browserController: browserController,
                    by: delta,
                    state: state
                )
            },
            openHighlightedSelection: {
                openHighlightedSelection(
                    browserController: browserController,
                    state: state,
                    openComment: openLinkedComment
                )
            }
        )
    }

    static func handleKeyEvent(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags,
        state: TimelineCommentSubmenuKeyboardState,
        environment: TimelineCommentSubmenuActionExecutionEnvironment
    ) -> Bool {
        let action = TimelineCommentBrowserKeyboardSupport.action(
            for: TimelineCommentBrowserKeyboardContext(
                keyCode: keyCode,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                modifiers: modifiers,
                isBrowsingAllComments: state.isBrowsingAllComments,
                hasPendingDeleteConfirmation: state.hasPendingDeleteConfirmation,
                isTagSubmenuVisible: state.isTagSubmenuVisible,
                isLinkPopoverPresented: state.isLinkPopoverPresented,
                isSearchFieldFocused: state.isSearchFieldFocused
            )
        )

        return TimelineCommentSubmenuActionExecutionSupport.execute(
            action,
            environment: environment
        )
    }

    static func syncHighlightedSelection(
        browserController: TimelineCommentSubmenuBrowserController,
        state: TimelineCommentSubmenuKeyboardState
    ) {
        browserController.syncHighlightedSelection(
            resultIDs: keyboardNavigableRows(state: state).map(\.id),
            preferredAnchorID: state.preferredAnchorID
        )
    }

    static func moveHighlightedSelection(
        browserController: TimelineCommentSubmenuBrowserController,
        by delta: Int,
        state: TimelineCommentSubmenuKeyboardState
    ) {
        browserController.moveHighlightedSelection(
            by: delta,
            resultIDs: keyboardNavigableRows(state: state).map(\.id),
            preferredAnchorID: state.preferredAnchorID
        )
    }

    static func seedHighlightedSelectionIfNeeded(
        browserController: TimelineCommentSubmenuBrowserController,
        state: TimelineCommentSubmenuKeyboardState
    ) {
        browserController.seedHighlightedSelectionIfNeeded(
            resultIDs: keyboardNavigableRows(state: state).map(\.id),
            preferredAnchorID: state.preferredAnchorID
        )
    }

    static func openHighlightedSelection(
        browserController: TimelineCommentSubmenuBrowserController,
        state: TimelineCommentSubmenuKeyboardState,
        openComment: (SegmentComment, SegmentID?) -> Void
    ) -> Bool {
        let rows = keyboardNavigableRows(state: state)
        guard let openTarget = browserController.resolvedOpenTarget(
            resultIDs: rows.map(\.id)
        ) else {
            return false
        }

        guard let targetRow = rows.first(where: { $0.id == openTarget.targetID }) else {
            return false
        }

        openComment(targetRow.comment, targetRow.context?.segmentID)
        return true
    }

    private static func keyboardNavigableRows(
        state: TimelineCommentSubmenuKeyboardState
    ) -> [CommentTimelineRow] {
        state.hasActiveCommentSearch ? state.searchResults : state.visibleRows
    }
}

@MainActor
enum TimelineCommentSubmenuLifecycleController {
    static func handleAppear(
        installKeyboardMonitor: (@escaping (NSEvent) -> Bool) -> Void,
        submenuBrowserController: TimelineCommentSubmenuBrowserController,
        browserController: TimelineCommentBrowserWindowController,
        targetPreviewController: TimelineCommentTargetPreviewController,
        composerController: TimelineCommentComposerController,
        setSearchFieldFocused: (Bool) -> Void,
        setAllCommentsBrowserActive: (Bool) -> Void,
        handleKeyEvent: @escaping (NSEvent) -> Bool,
        scheduleDeferredAction: (@escaping () -> Void) -> Void = { action in
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
                action()
            }
        },
        loadTags: @escaping () async -> Void
    ) {
        installKeyboardMonitor(handleKeyEvent)
        submenuBrowserController.resetForAppear()
        browserController.resetForThread()
        setSearchFieldFocused(false)
        setAllCommentsBrowserActive(false)
        targetPreviewController.reset()
        scheduleDeferredAction {
            composerController.isEditorFocused = true
        }
        Task { await loadTags() }
    }

    static func handleModeChange(
        mode: TimelineCommentSubmenuBrowserMode,
        syncHighlightedSelection: () -> Void,
        setSearchFieldFocused: @escaping (Bool) -> Void,
        setAllCommentsBrowserActive: (Bool) -> Void,
        scheduleDeferredAction: (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.async {
                action()
            }
        }
    ) {
        setAllCommentsBrowserActive(mode == .allComments)
        if mode == .allComments {
            syncHighlightedSelection()
            scheduleDeferredAction {
                setSearchFieldFocused(true)
            }
        } else {
            setSearchFieldFocused(false)
        }
    }

    static func handleReturnToThreadCommentsSignal(
        isBrowsingAllComments: Bool,
        exitAllComments: () -> Void
    ) {
        guard isBrowsingAllComments else { return }
        exitAllComments()
    }

    static func handleSearchStateChange(
        syncHighlightedSelection: () -> Void
    ) {
        syncHighlightedSelection()
    }

    static func handleTagSubmenuChange(
        isPresented: Bool,
        mode: TimelineCommentSubmenuBrowserMode,
        isLinkPopoverPresented: Bool,
        composerController: TimelineCommentComposerController,
        scheduleDeferredAction: (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.async {
                action()
            }
        }
    ) {
        if isPresented {
            composerController.isEditorFocused = false
        } else if mode == .thread && !isLinkPopoverPresented {
            scheduleDeferredAction {
                composerController.isEditorFocused = true
            }
        }
    }

    static func handleCloseLinkPopoverSignal(
        composerController: TimelineCommentComposerController
    ) {
        guard composerController.isLinkPopoverPresented else { return }
        composerController.dismissLinkPopover(refocusEditor: true)
    }

    static func handleDisappear(
        removeKeyboardMonitor: () -> Void,
        targetPreviewController: TimelineCommentTargetPreviewController,
        setCommentLinkPopoverPresented: (Bool) -> Void,
        setAllCommentsBrowserActive: (Bool) -> Void,
        setSearchFieldFocused: (Bool) -> Void,
        resetTimelineState: () -> Void
    ) {
        removeKeyboardMonitor()
        setCommentLinkPopoverPresented(false)
        setAllCommentsBrowserActive(false)
        setSearchFieldFocused(false)
        targetPreviewController.reset()
        resetTimelineState()
    }
}

enum TimelineCommentSubmenuPresentationSupport {
    static let animationDuration: Double = 0.16

    static func initialState(isVisible: Bool) -> TimelineCommentSubmenuPresentationState {
        TimelineCommentSubmenuPresentationState(
            isMounted: isVisible,
            visibility: isVisible ? 1 : 0
        )
    }

    static func transition(
        isVisible: Bool,
        isMounted: Bool
    ) -> TimelineCommentSubmenuPresentationTransition {
        if isVisible {
            return .show(shouldPrimeMount: !isMounted)
        }

        if isMounted {
            return .hide(shouldScheduleUnmount: true)
        }

        return .none
    }

    static func shouldFinalizeUnmount(isStillVisible: Bool) -> Bool {
        !isStillVisible
    }
}

@MainActor
enum TimelineCommentSubmenuRoutingSupport {
    static func launchAnchorComment(
        from comments: [SegmentComment]
    ) -> SegmentComment? {
        let sortedComments = comments.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.value < $1.id.value
            }
            return $0.createdAt < $1.createdAt
        }

        guard !sortedComments.isEmpty else { return nil }
        return sortedComments[sortedComments.count / 2]
    }

    static func makeActions(
        browserController: TimelineCommentSubmenuBrowserController,
        state: TimelineCommentSubmenuKeyboardState,
        selectedBlockComments: [SegmentComment],
        environment: TimelineCommentSubmenuRoutingEnvironment
    ) -> TimelineCommentSubmenuRoutingActions {
        let launchAnchorComment = launchAnchorComment(from: selectedBlockComments)
        let openAllComments = {
            environment.dismissPendingDeletion()
            environment.openAllComments(launchAnchorComment)
        }

        return TimelineCommentSubmenuRoutingActions(
            openAllComments: openAllComments,
            exitAllComments: environment.exitAllComments,
            openLinkedComment: environment.openLinkedComment,
            handleKeyEvent: { keyCode, charactersIgnoringModifiers, modifiers in
                let keyboardEnvironment = TimelineCommentSubmenuKeyboardController.makeActionEnvironment(
                    browserController: browserController,
                    state: state,
                    dismissTagSubmenu: environment.dismissTagSubmenu,
                    dismissLinkPopover: environment.dismissLinkPopover,
                    exitAllComments: environment.exitAllComments,
                    closeSubmenu: environment.closeSubmenu,
                    openAllComments: openAllComments,
                    setSearchFieldFocused: environment.setSearchFieldFocused,
                    openLinkedComment: environment.openLinkedComment
                )

                return TimelineCommentSubmenuKeyboardController.handleKeyEvent(
                    keyCode: keyCode,
                    charactersIgnoringModifiers: charactersIgnoringModifiers,
                    modifiers: modifiers,
                    state: state,
                    environment: keyboardEnvironment
                )
            }
        )
    }
}

struct TimelineCommentSubmenuOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let isMounted: Bool
    let visibility: Double
    let availableWidth: CGFloat

    var body: some View {
        if isMounted {
            Color.black.opacity(0.35)
                .opacity(visibility)
                .ignoresSafeArea()
                .allowsHitTesting(viewModel.showCommentSubmenu)
                .onTapGesture {
                    viewModel.dismissCommentSubmenu()
                }

            VStack {
                CommentSubmenu(viewModel: viewModel) {
                    viewModel.dismissCommentSubmenu()
                }
                .frame(maxWidth: min(availableWidth - 40, 560))
            }
            .padding(.horizontal, 20)
            .opacity(visibility)
            .scaleEffect(0.98 + (0.02 * visibility))
            .allowsHitTesting(viewModel.showCommentSubmenu)
        }
    }
}

struct TimelineCommentComposerSection: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @ObservedObject var controller: TimelineCommentComposerController
    let sectionCornerRadius: CGFloat
    let onSubmit: () -> Void

    @FocusState private var isLinkFieldFocused: Bool

    private var trimmedComment: String {
        viewModel.newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var commentDraftBinding: Binding<String> {
        Binding(
            get: { viewModel.newCommentText },
            set: { viewModel.setCommentDraftText($0) }
        )
    }

    private var canSubmit: Bool {
        !trimmedComment.isEmpty && !viewModel.isAddingComment
    }

    var body: some View {
        CommentChromeSectionCard(cornerRadius: sectionCornerRadius) {
            VStack(alignment: .leading, spacing: 10) {
                toolbar

                CommentChromeEditorSurface(
                    isFocused: controller.isEditorFocused,
                    textIsEmpty: viewModel.newCommentText.isEmpty,
                    placeholder: "Write a comment... Markdown supported."
                ) {
                    CommentMarkdownEditor(
                        text: commentDraftBinding,
                        isFocused: $controller.isEditorFocused,
                        onSubmit: submitFromKeyboard,
                        formatting: .init(
                            command: controller.editorCommand,
                            commandNonce: controller.editorCommandNonce,
                            onRequestLink: controller.presentLinkPopover
                        )
                    )
                    .frame(minHeight: 78, maxHeight: 78)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }

                if !viewModel.newCommentAttachmentDrafts.isEmpty {
                    attachmentDraftRow
                }
            }
        }
        .onChange(of: controller.isLinkPopoverPresented) { isPresented in
            if isPresented {
                DispatchQueue.main.async {
                    isLinkFieldFocused = true
                }
            } else {
                isLinkFieldFocused = false
                DispatchQueue.main.async {
                    controller.isEditorFocused = true
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            formattingButton(icon: "bold") { controller.sendEditorCommand(.bold) }
            formattingButton(icon: "italic") { controller.sendEditorCommand(.italic) }
            linkFormattingButton
            formattingButton(icon: "clock") { viewModel.insertCommentTimestampMarkup() }
            formattingButton(icon: "paperclip") { viewModel.selectCommentAttachmentFiles() }
            Spacer()
            CommentChromeCapsuleButton(
                action: onSubmit,
                isEnabled: canSubmit,
                style: .submit
            ) {
                HStack(spacing: 5) {
                    if viewModel.isAddingComment {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewModel.isAddingComment ? "Adding..." : "Add Comment")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var linkFormattingButton: some View {
        formattingButton(icon: "link") { controller.presentLinkPopover() }
            .popover(
                isPresented: $controller.isLinkPopoverPresented,
                attachmentAnchor: .point(.bottom),
                arrowEdge: .top
            ) {
                linkPopoverContent
            }
    }

    private var linkPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert Link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.retracePrimary)

            TextField("https://example.com", text: $controller.pendingLinkURL)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.retracePrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .focused($isLinkFieldFocused)
                .contentShape(Rectangle())
                .onTapGesture {
                    isLinkFieldFocused = true
                }
                .onSubmit {
                    _ = controller.insertLinkFromPopover()
                }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel") {
                    controller.dismissLinkPopover(refocusEditor: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.retraceSecondary)

                Button("Insert") {
                    _ = controller.insertLinkFromPopover()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(controller.normalizedPendingLinkURL == nil ? .retraceSecondary : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            controller.normalizedPendingLinkURL == nil
                            ? Color.white.opacity(0.08)
                            : Color.retraceSubmitAccent.opacity(0.9)
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            controller.normalizedPendingLinkURL == nil
                            ? Color.white.opacity(0.12)
                            : Color.retraceSubmitAccent.opacity(0.35),
                            lineWidth: 1
                        )
                )
                .disabled(controller.normalizedPendingLinkURL == nil)
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(Color.clear)
    }

    private var attachmentDraftRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.newCommentAttachmentDrafts) { draft in
                    attachmentDraftChip(draft)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func submitFromKeyboard() {
        guard canSubmit else { return }
        onSubmit()
    }

    private func formattingButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retracePrimary.opacity(0.9))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }

    private func attachmentDraftChip(_ draft: CommentAttachmentDraft) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.fill")
                .font(.system(size: 10))
                .foregroundColor(.retraceSecondary.opacity(0.9))
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.fileName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.retracePrimary.opacity(0.95))
                    .lineLimit(1)
                if let sizeBytes = draft.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }
            }
            Button(action: { viewModel.removeCommentAttachmentDraft(draft) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.retraceSecondary.opacity(0.9))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        )
    }
}
