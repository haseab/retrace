import SwiftUI
import AppKit
import Shared

/// Dedicated overlay for creating rich comments and browsing the existing thread for the selected block.
struct CommentSubmenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    private let allCommentsSessionController = TimelineCommentAllCommentsSessionController()
    private let allCommentsFlowController = TimelineCommentAllCommentsFlowController()
    @StateObject private var submenuBrowserController = TimelineCommentSubmenuBrowserController()
    @StateObject private var browserController = TimelineCommentBrowserWindowController()
    @StateObject private var composerController = TimelineCommentComposerController()
    @StateObject private var deletionController = TimelineCommentDeletionController()
    @StateObject private var navigationController = TimelineCommentSubmenuNavigationController()
    @StateObject private var interactionController = TimelineCommentSubmenuInteractionController()
    @StateObject private var targetPreviewController = TimelineCommentTargetPreviewController()
    @State private var threadHoveredCommentID: SegmentCommentID?
    let onClose: () -> Void
    @FocusState private var isAllCommentsSearchFieldFocused: Bool
    private let submenuWidth: CGFloat = 450
    private let submenuHeight: CGFloat = 720
    private let sectionCornerRadius: CGFloat = 14
    private let allCommentsPageSize: Int = 10

    private static let threadDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var hasActiveCommentSearch: Bool {
        !viewModel.commentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commentTargetFrameIDValue: Int64? {
        viewModel.selectedCommentComposerTarget?.frameID.value
    }

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { deletionController.pendingComment != nil },
            set: { shouldShow in
                if !shouldShow {
                    deletionController.dismiss()
                }
            }
        )
    }

    private var allCommentsState: TimelineCommentAllCommentsDerivedState {
        TimelineCommentAllCommentsDerivedStateSupport.make(
            rows: viewModel.commentTimelineRows,
            explicitAnchorID: browserController.anchorID,
            fallbackAnchorID: viewModel.commentTimelineAnchorCommentID,
            visibleBeforeCount: browserController.visibleBeforeCount,
            visibleAfterCount: browserController.visibleAfterCount
        )
    }

    private var keyboardState: TimelineCommentSubmenuKeyboardState {
        TimelineCommentSubmenuKeyboardState(
            isBrowsingAllComments: submenuBrowserController.isBrowsingAllComments,
            hasPendingDeleteConfirmation: deletionController.pendingComment != nil,
            isTagSubmenuVisible: viewModel.showTagSubmenu,
            isLinkPopoverPresented: composerController.isLinkPopoverPresented,
            isSearchFieldFocused: isAllCommentsSearchFieldFocused,
            hasActiveCommentSearch: hasActiveCommentSearch,
            searchResults: viewModel.commentSearchResults,
            visibleRows: allCommentsState.visibleRows,
            preferredAnchorID: allCommentsState.anchorID
        )
    }

    private var routingActions: TimelineCommentSubmenuRoutingActions {
        TimelineCommentSubmenuRoutingSupport.makeActions(
            browserController: submenuBrowserController,
            state: keyboardState,
            selectedBlockComments: viewModel.selectedBlockComments,
            environment: .init(
                dismissPendingDeletion: deletionController.dismiss,
                openAllComments: { comment in
                    withAnimation(.easeOut(duration: 0.14)) {
                        allCommentsFlowController.openAllComments(
                            anchoredAt: comment,
                            environment: allCommentsFlowEnvironment()
                        )
                    }
                },
                exitAllComments: {
                    withAnimation(.easeOut(duration: 0.14)) {
                        allCommentsFlowController.exitAllComments(
                            environment: allCommentsFlowEnvironment()
                        )
                    }
                },
                openLinkedComment: { comment, preferredSegmentID in
                    navigationController.openLinkedComment(
                        comment,
                        preferredSegmentID: preferredSegmentID
                    ) { request in
                        await viewModel.navigateToComment(
                            comment: request.comment,
                            preferredSegmentID: request.preferredSegmentID
                        )
                    } onClose: {
                        onClose()
                    }
                },
                dismissTagSubmenu: {
                    withAnimation(.easeOut(duration: 0.12)) {
                        viewModel.dismissTagEditing()
                    }
                },
                dismissLinkPopover: {
                    composerController.dismissLinkPopover(refocusEditor: true)
                },
                closeSubmenu: onClose,
                setSearchFieldFocused: {
                    isAllCommentsSearchFieldFocused = $0
                }
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            commentHeader
            if submenuBrowserController.mode == .thread {
                threadModeContent
            } else {
                allCommentsSection
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
            }
        }
        .frame(width: submenuWidth)
        .frame(height: submenuHeight, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .retraceMenuContainer(addPadding: false)
        .animation(.spring(response: 0.26, dampingFraction: 0.88), value: submenuBrowserController.mode)
        .onAppear {
            TimelineCommentSubmenuLifecycleController.handleAppear(
                installKeyboardMonitor: interactionController.installKeyboardMonitor,
                submenuBrowserController: submenuBrowserController,
                browserController: browserController,
                targetPreviewController: targetPreviewController,
                composerController: composerController,
                setSearchFieldFocused: { isAllCommentsSearchFieldFocused = $0 },
                setAllCommentsBrowserActive: viewModel.setAllCommentsBrowserActive,
                handleKeyEvent: { event in
                    routingActions.handleKeyEvent(
                        event.keyCode,
                        event.charactersIgnoringModifiers,
                        event.modifierFlags
                    )
                }
            ) {
                await viewModel.loadTags()
            }
        }
        .onChange(of: submenuBrowserController.mode) { mode in
            TimelineCommentSubmenuLifecycleController.handleModeChange(
                mode: mode,
                syncHighlightedSelection: {
                    TimelineCommentSubmenuKeyboardController.syncHighlightedSelection(
                        browserController: submenuBrowserController,
                        state: keyboardState
                    )
                },
                setSearchFieldFocused: { isAllCommentsSearchFieldFocused = $0 },
                setAllCommentsBrowserActive: viewModel.setAllCommentsBrowserActive
            )
        }
        .onChange(of: viewModel.returnToThreadCommentsSignal) { _ in
            TimelineCommentSubmenuLifecycleController.handleReturnToThreadCommentsSignal(
                isBrowsingAllComments: submenuBrowserController.isBrowsingAllComments
            ) { routingActions.exitAllComments() }
        }
        .onChange(of: viewModel.commentSearchText) { _ in
            TimelineCommentSubmenuLifecycleController.handleSearchStateChange {
                TimelineCommentSubmenuKeyboardController.syncHighlightedSelection(
                    browserController: submenuBrowserController,
                    state: keyboardState
                )
            }
        }
        .onChange(of: viewModel.commentSearchResults.map { $0.id.value }) { _ in
            TimelineCommentSubmenuLifecycleController.handleSearchStateChange {
                TimelineCommentSubmenuKeyboardController.syncHighlightedSelection(
                    browserController: submenuBrowserController,
                    state: keyboardState
                )
            }
        }
        .onChange(of: viewModel.showTagSubmenu) { isPresented in
            TimelineCommentSubmenuLifecycleController.handleTagSubmenuChange(
                isPresented: isPresented,
                mode: submenuBrowserController.mode,
                isLinkPopoverPresented: composerController.isLinkPopoverPresented,
                composerController: composerController
            )
        }
        .onChange(of: composerController.isLinkPopoverPresented) { isPresented in
            viewModel.setCommentLinkPopoverPresented(isPresented)
        }
        .onChange(of: viewModel.closeCommentLinkPopoverSignal) { _ in
            TimelineCommentSubmenuLifecycleController.handleCloseLinkPopoverSignal(
                composerController: composerController
            )
        }
        .onDisappear {
            TimelineCommentSubmenuLifecycleController.handleDisappear(
                removeKeyboardMonitor: interactionController.removeKeyboardMonitor,
                targetPreviewController: targetPreviewController,
                setCommentLinkPopoverPresented: viewModel.setCommentLinkPopoverPresented,
                setAllCommentsBrowserActive: viewModel.setAllCommentsBrowserActive,
                setSearchFieldFocused: { isAllCommentsSearchFieldFocused = $0 },
                resetTimelineState: viewModel.resetCommentTimelineState
            )
        }
        .task(id: commentTargetFrameIDValue) {
            await targetPreviewController.refresh(
                context: TimelineCommentTargetPreviewContext(
                    isInLiveMode: viewModel.isInLiveMode,
                    liveScreenshot: viewModel.liveScreenshot,
                    targetFrameID: viewModel.selectedCommentComposerTarget?.frameID
                )
            ) { frameID in
                await viewModel.loadCommentPreviewImage(for: frameID)
            }
        }
        .alert(
            "Delete comment?",
            isPresented: isDeleteConfirmationPresented,
            presenting: deletionController.pendingComment
        ) { comment in
            Button("Cancel", role: .cancel) {
                deletionController.dismiss()
            }
            Button(deletionController.isDeleting ? "Deleting..." : "Delete", role: .destructive) {
                Task { @MainActor in
                    _ = await deletionController.confirmDeletion { comment in
                        await viewModel.removeCommentFromSelectedTimelineBlock(comment: comment)
                    }
                }
            }
            .disabled(deletionController.isDeleting)
        } message: { _ in
            Text("This removes the comment from all segments in this selected block. If it has no remaining links, it will be deleted permanently.")
        }
    }

    private var commentHeader: some View {
        TimelineCommentSubmenuHeader(
            isBrowsingAllComments: submenuBrowserController.isBrowsingAllComments,
            onClose: onClose,
            onExitAllComments: routingActions.exitAllComments,
            onOpenAllComments: routingActions.openAllComments
        )
    }

    private var threadModeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let context = viewModel.selectedCommentComposerTarget {
                TimelineCommentTargetSection(
                    viewModel: viewModel,
                    context: context,
                    previewImage: targetPreviewController.previewImage,
                    isPreviewLoading: targetPreviewController.isLoading,
                    onOpenAddTag: {
                        composerController.isEditorFocused = false
                        viewModel.openTagSubmenuForSelectedCommentTarget(source: "comment_target_add_tag")
                    }
                )
                .fixedSize(horizontal: false, vertical: true)
            }

            TimelineCommentThreadSection(
                viewModel: viewModel,
                hoveredCommentID: .init(
                    get: { threadHoveredCommentID },
                    set: { threadHoveredCommentID = $0 }
                ),
                sectionCornerRadius: sectionCornerRadius,
                dateFormatter: Self.threadDateFormatter,
                onDeleteComment: deletionController.requestDelete,
                onOpenComment: { comment in
                    routingActions.openLinkedComment(
                        comment,
                        viewModel.preferredSegmentIDForSelectedBlockComment(comment.id)
                    )
                },
                onOpenAttachment: { attachment in
                    viewModel.openCommentAttachment(attachment)
                }
            )
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .scale(scale: 0.96, anchor: .top).combined(with: .opacity)
                )
            )

            TimelineCommentComposerSection(
                viewModel: viewModel,
                controller: composerController,
                sectionCornerRadius: sectionCornerRadius,
                onSubmit: viewModel.addCommentToSelectedSegment
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var allCommentsSection: some View {
        TimelineCommentAllCommentsHost(
            viewModel: viewModel,
            submenuBrowserController: submenuBrowserController,
            windowController: browserController,
            sectionCornerRadius: sectionCornerRadius,
            pageSize: allCommentsPageSize,
            dateFormatter: Self.threadDateFormatter,
            searchFieldFocus: $isAllCommentsSearchFieldFocused,
            sessionController: allCommentsSessionController,
            flowController: allCommentsFlowController,
            openLinkedComment: routingActions.openLinkedComment
        )
    }

    private func allCommentsFlowEnvironment(
        proxy: ScrollViewProxy? = nil
    ) -> TimelineCommentAllCommentsFlowEnvironment {
        TimelineCommentAllCommentsFlowController.makeEnvironment(
            viewModel: viewModel,
            sessionController: allCommentsSessionController,
            browserController: submenuBrowserController,
            windowController: browserController,
            pageSize: allCommentsPageSize,
            allCommentsState: allCommentsState,
            setSearchFieldFocused: {
                isAllCommentsSearchFieldFocused = $0
            },
            proxy: proxy
        )
    }
}

struct TimelineCommentSubmenuHeader: View {
    let isBrowsingAllComments: Bool
    let onClose: () -> Void
    let onExitAllComments: () -> Void
    let onOpenAllComments: () -> Void

    var body: some View {
        CommentChromeHeader(title: isBrowsingAllComments ? "All Comments" : "Comments", onClose: onClose) {
            if isBrowsingAllComments {
                CommentChromeCircleButton(
                    icon: "chevron.left",
                    action: onExitAllComments,
                    iconFont: .system(size: 12, weight: .semibold),
                    baseForeground: Color.retracePrimary.opacity(0.9),
                    hoverForeground: Color.retracePrimary.opacity(0.98),
                    baseFill: Color.white.opacity(0.08),
                    hoverFill: Color.white.opacity(0.12),
                    baseStroke: .clear,
                    hoverStroke: .clear
                )
            }
        } accessory: {
            if !isBrowsingAllComments {
                CommentChromeCapsuleButton(
                    action: onOpenAllComments,
                    horizontalPadding: 9,
                    verticalPadding: 5,
                    style: .accentOutline
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 10, weight: .semibold))
                        Text("All Comments")
                            .font(.system(size: 11, weight: .semibold))
                        Text("⌥A")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.retraceSecondary.opacity(0.85))
                            .padding(.leading, 2)
                    }
                }
                .help("Open All Comments (Option+A)")
            }
        }
    }
}

struct TimelineCommentTargetSection: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let context: CommentComposerTargetDisplayInfo
    let previewImage: NSImage?
    let isPreviewLoading: Bool
    let onOpenAddTag: () -> Void

    private let tagOverlayOffsetY: CGFloat = 30

    var body: some View {
        CommentContextPreviewCard(
            title: context.title,
            subtitle: context.subtitle,
            timestamp: context.timestamp,
            appBundleID: context.appBundleID,
            previewImage: previewImage,
            isPreviewLoading: isPreviewLoading,
            shouldUseExpandedTitle: context.shouldUseExpandedWindowTitle,
            metadataLayout: .stacked
        ) {
            targetTagRow
        }
        .zIndex(viewModel.showTagSubmenu ? 8 : 1)
    }

    private var targetTagRow: some View {
        let selectedTags = displayTags(orderedBy: context.tagNames)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 8) {
                addTagPill

                if !selectedTags.isEmpty {
                    ForEach(selectedTags) { tag in
                        targetTagChip(tag)
                    }
                } else {
                    ForEach(context.tagNames, id: \.self) { tagName in
                        commentMetaChip(
                            text: tagName,
                            icon: "tag.fill",
                            accent: Color.retracePrimary.opacity(0.9)
                        )
                    }
                }
            }
            .padding(.vertical, 1)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if viewModel.showTagSubmenu {
                TagSubmenu(viewModel: viewModel, presentation: .commentOverlay)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: tagOverlayOffsetY)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                    .zIndex(1)
            }
        }
    }

    private func displayTags(orderedBy tagNames: [String]) -> [Tag] {
        let preferredOrder = Dictionary(
            uniqueKeysWithValues: tagNames.enumerated().map { (offset, name) in
                (name, offset)
            }
        )

        return viewModel.availableTags
            .filter { !($0.isHidden) && viewModel.selectedSegmentTags.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsOrder = preferredOrder[lhs.name] ?? Int.max
                let rhsOrder = preferredOrder[rhs.name] ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func targetTagChip(_ tag: Tag) -> some View {
        CommentChromeChip(
            text: tag.name,
            icon: "tag.fill",
            foregroundColor: Color.retracePrimary.opacity(0.9),
            backgroundColor: Color.white.opacity(0.08),
            borderColor: Color.white.opacity(0.12)
        ) { isHovering in
            if isHovering {
                Button {
                    viewModel.toggleTagOnSelectedSegment(
                        tag: tag,
                        source: "comment_target_tag_chip_remove"
                    )
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 13, height: 13)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    private var addTagPill: some View {
        CommentChromeCapsuleButton(
            action: onOpenAddTag,
            horizontalPadding: 11,
            verticalPadding: 5,
            style: .accentOutline,
            onHoverChanged: { hovering in
                viewModel.setHoveringAddTagButton(hovering)
            }
        ) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))

                Text("Add tag")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
    }

    private func commentMetaChip(text: String, icon: String, accent: Color) -> some View {
        CommentChromeChip(
            text: text,
            icon: icon,
            foregroundColor: accent,
            backgroundColor: Color.white.opacity(0.08),
            borderColor: Color.white.opacity(0.12)
        )
    }
}

struct TimelineCommentThreadSection: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @Binding var hoveredCommentID: SegmentCommentID?
    let sectionCornerRadius: CGFloat
    let dateFormatter: DateFormatter
    let onDeleteComment: (SegmentComment) -> Void
    let onOpenComment: (SegmentComment) -> Void
    let onOpenAttachment: (SegmentCommentAttachment) -> Void

    var body: some View {
        CommentChromeSectionCard(cornerRadius: sectionCornerRadius) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Thread (\(viewModel.selectedBlockComments.count))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.retraceSecondary)
                }

                if viewModel.isLoadingBlockComments {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading thread...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.retraceSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
                } else if let loadError = viewModel.blockCommentsLoadError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.retraceDanger.opacity(0.9))
                        Text(loadError)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.retraceSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
                } else if viewModel.selectedBlockComments.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(viewModel.selectedBlockComments) { comment in
                                threadCard(comment)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .zIndex(0)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.retracePrimary.opacity(0.92))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.06))
                )

            Text("No comments yet.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.retracePrimary.opacity(0.95))

            Text("Start the thread below.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.retraceSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
    }

    private func threadCard(_ comment: SegmentComment) -> some View {
        let presentation = TimelineCommentPresentationSupport.makeThreadCommentCardPresentation(
            comment: comment,
            hoveredCommentID: hoveredCommentID,
            dateFormatter: dateFormatter
        )

        return TimelineThreadCommentCard(
            comment: comment,
            presentation: presentation,
            isHovered: presentation.showsDeleteAction
        ) {
            onDeleteComment(comment)
        } onOpen: {
            onOpenComment(comment)
        } onAttachmentOpen: { attachment in
            onOpenAttachment(attachment)
        } onHoverChanged: { hovering in
            if hovering {
                hoveredCommentID = comment.id
            } else if hoveredCommentID == comment.id {
                hoveredCommentID = nil
            }
        }
    }
}
