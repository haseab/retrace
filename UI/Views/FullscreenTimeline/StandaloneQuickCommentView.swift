import SwiftUI
import AppKit
import Shared

private let quickCommentSettingsStore: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

struct StandaloneQuickCommentView: View {
    @ObservedObject var viewModel: QuickCommentComposerViewModel
    let onContextPreviewCollapsedChange: (Bool) -> Void
    let onClose: () -> Void

    @AppStorage("quickCommentContextPreviewCollapsed", store: quickCommentSettingsStore)
    private var isContextPreviewCollapsed = false
    @State private var isShowingSuccess = false
    @State private var successDismissTask: Task<Void, Never>?
    @State private var isShowingTagPicker = false
    @State private var isCommentFocused = false

    private let windowCornerRadius: CGFloat = StandaloneCommentComposerWindowController.windowCornerRadius
    private let quickCommentTagSubmenuVerticalGap: CGFloat = 38
    private let contentSectionSpacing: CGFloat = 12
    private let composerSectionSpacing: CGFloat = 8
    private let composerButtonVerticalPadding: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(
                geometry.size.width - (StandaloneCommentComposerWindowController.rootHorizontalPadding * 2),
                0
            )
            let contentHeight = max(
                geometry.size.height - (StandaloneCommentComposerWindowController.rootVerticalPadding * 2),
                0
            )

            windowContent(contentWidth: contentWidth, contentHeight: contentHeight)
                .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                .padding(.horizontal, StandaloneCommentComposerWindowController.rootHorizontalPadding)
                .padding(.vertical, StandaloneCommentComposerWindowController.rootVerticalPadding)
                .retraceMenuContainer(addPadding: false, cornerRadius: windowCornerRadius)
                .clipShape(RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous))
                .compositingGroup()
        }
        .onAppear {
            onContextPreviewCollapsedChange(isContextPreviewCollapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isCommentFocused = true
            }
        }
        .onChange(of: viewModel.newCommentText) { newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                viewModel.pinTargetForEditing()
            }
        }
        .onChange(of: isContextPreviewCollapsed) { isCollapsed in
            onContextPreviewCollapsedChange(isCollapsed)
        }
        .onChange(of: isCommentFocused) { isFocused in
            guard isFocused, isShowingTagPicker else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                isShowingTagPicker = false
            }
        }
        .onDisappear {
            successDismissTask?.cancel()
            successDismissTask = nil
            isShowingTagPicker = false
        }
    }

    @ViewBuilder
    private func windowContent(contentWidth: CGFloat, contentHeight: CGFloat) -> some View {
        if isShowingSuccess {
            VStack {
                Spacer(minLength: 0)
                successState
                Spacer(minLength: 0)
            }
            .frame(width: contentWidth, height: contentHeight)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: contentSectionSpacing) {
                    header

                    if viewModel.isLoadingTarget && viewModel.target == nil {
                        loadingTargetSection
                    } else if let target = viewModel.target {
                        targetSection(for: target)
                    }

                    composerSection

                    if let messageText = viewModel.messageText {
                        Text(messageText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(viewModel.messageIsError ? .orange : .retraceSecondary)
                    }
                }
                .frame(width: contentWidth, alignment: .topLeading)
            }
        }
    }

    private var header: some View {
        CommentChromeHeader(
            title: "Quick Comment",
            onClose: onClose,
            spacing: 10,
            iconContainerSize: 30,
            iconCornerRadius: 9,
            iconFont: .system(size: 13, weight: .semibold)
        )
    }

    private func targetSection(for target: CommentComposerTargetDisplayInfo) -> some View {
        CommentContextPreviewCard(
            title: target.title,
            subtitle: target.subtitle,
            timestamp: target.timestamp,
            appBundleID: target.appBundleID,
            previewImage: viewModel.previewImage,
            isPreviewLoading: false,
            shouldUseExpandedTitle: target.shouldUseExpandedWindowTitle,
            isCollapsed: isContextPreviewCollapsed,
            onToggleCollapsed: toggleContextPreviewCollapsed
        ) {
            sessionAddedTagRow
        } footerContent: {
            if viewModel.isReadOnlyTarget {
                Text("Rewind segments are read-only. Choose a live Retrace segment to comment or tag.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loadingTargetSection: some View {
        CommentContextPreviewLoadingCard(
            title: "Resolving current moment...",
            detail: "Finding the latest captured frame and segment before this quick-comment window."
        )
    }

    private var composerSection: some View {
        VStack(alignment: .leading, spacing: composerSectionSpacing) {
            CommentChromeEditorSurface(
                isFocused: isCommentFocused,
                textIsEmpty: viewModel.newCommentText.isEmpty,
                placeholder: "Write a comment about what you're seeing right now..."
            ) {
                CommentMarkdownEditor(
                    text: $viewModel.newCommentText,
                    isFocused: $isCommentFocused,
                    onSubmit: submitCommentFromKeyboard,
                    formatting: nil
                )
                .frame(minHeight: 78, maxHeight: 78)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            HStack(spacing: 10) {
                Spacer()
                footerAddTagButton
                submitCommentButton
            }
        }
        .zIndex(isShowingTagPicker ? 3 : 0)
    }

    private var submitCommentButton: some View {
        CommentChromeCapsuleButton(
            action: submitComment,
            isEnabled: viewModel.canSubmitComment,
            verticalPadding: composerButtonVerticalPadding,
            style: .submit
        ) {
            HStack(spacing: 5) {
                if viewModel.isSubmittingComment {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(viewModel.isSubmittingComment ? "Adding..." : "Add Comment")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .keyboardShortcut(.return, modifiers: [.command])
    }

    private var footerAddTagButton: some View {
        CommentChromeCapsuleButton(
            action: toggleFooterTagPicker,
            isEnabled: isFooterAddTagEnabled,
            verticalPadding: composerButtonVerticalPadding,
            style: footerAddTagButtonStyle
        ) {
            HStack(spacing: 6) {
                if viewModel.isLoadingTags {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: footerAddTagIconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(footerAddTagIconColor)
                }

                Text(footerAddTagLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: isShowingTagPicker ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isShowingTagPicker {
                CommentTagPickerMenu(
                    tags: availableFooterTags,
                    selectedTagIDs: viewModel.sessionAddedTagIDs,
                    style: .commentOverlay,
                    dismissOnEscape: dismissFooterTagPicker,
                    onSelectTag: { tag in
                        addFooterTag(tag.id)
                    },
                    onCreateTag: createFooterTag(named:),
                    onOpenSettings: openTagSettings
                )
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: -quickCommentTagSubmenuVerticalGap)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                .zIndex(1)
            }
        }
    }

    private var sessionAddedFooterTagCount: Int {
        viewModel.sessionAddedTagIDs.count
    }

    private var sessionAddedSingleFooterTag: Tag? {
        guard sessionAddedFooterTagCount == 1 else { return nil }
        return viewModel.sessionAddedTags.first
    }

    private var isFooterAddTagEnabled: Bool {
        viewModel.target != nil && !viewModel.isReadOnlyTarget
    }

    private var footerAddTagButtonStyle: CommentChromeCapsuleButtonStyle {
        .tagSelection(isSelected: sessionAddedFooterTagCount > 0)
    }

    private var footerAddTagLabel: String {
        if sessionAddedFooterTagCount == 0 {
            return "Add Tag"
        }
        if let tag = sessionAddedSingleFooterTag {
            return tag.name
        }
        return "\(sessionAddedFooterTagCount) Tags"
    }

    private var footerAddTagIconName: String {
        sessionAddedFooterTagCount == 0 ? "tag" : "tag.fill"
    }

    private var footerAddTagIconColor: Color {
        if let tag = sessionAddedSingleFooterTag {
            return TagColorStore.color(for: tag)
        }
        return footerAddTagButtonStyle.foregroundColor(
            isHovering: false,
            isEnabled: isFooterAddTagEnabled
        )
    }

    @ViewBuilder
    private var sessionAddedTagRow: some View {
        if !viewModel.sessionAddedTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(viewModel.sessionAddedTags) { tag in
                        sessionAddedTagChip(tag)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sessionAddedTagChip(_ tag: Tag) -> some View {
        CommentChromeChip(
            text: tag.name,
            icon: "tag.fill",
            foregroundColor: .white.opacity(0.94),
            backgroundColor: TagColorStore.color(for: tag).opacity(0.24),
            borderColor: TagColorStore.color(for: tag).opacity(0.34)
        )
    }

    private var successState: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(Color.retraceSubmitAccent.opacity(0.18))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color.retraceSubmitAccent.opacity(0.96))
                )

            VStack(spacing: 6) {
                Text("Comment added")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.retracePrimary.opacity(0.98))

                Text("Closing quick comment...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.84))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    private var availableFooterTags: [Tag] {
        viewModel.availableTags
            .filter { !($0.isHidden) }
            .sorted { lhs, rhs in
                let lhsSelected = viewModel.sessionAddedTagIDs.contains(lhs.id)
                let rhsSelected = viewModel.sessionAddedTagIDs.contains(rhs.id)
                if lhsSelected != rhsSelected {
                    return lhsSelected
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func toggleContextPreviewCollapsed() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            isContextPreviewCollapsed.toggle()
        }
        viewModel.recordContextPreviewToggle(isCollapsed: isContextPreviewCollapsed)
    }

    private func toggleFooterTagPicker() {
        let willShowTagPicker = !isShowingTagPicker
        if willShowTagPicker {
            viewModel.pinTargetForEditing()
            viewModel.recordTagSubmenuOpen(source: "quick_comment_add_tag")
            isCommentFocused = false
            Task { await viewModel.loadAvailableTagsForPicker() }
        } else {
            isCommentFocused = true
        }
        withAnimation(.easeOut(duration: 0.12)) {
            isShowingTagPicker = willShowTagPicker
        }
        Log.debug("[QuickComment] Tag picker visible=\(isShowingTagPicker)", category: .ui)
    }

    private func addFooterTag(_ tagID: TagID?) {
        guard let tagID,
              let tag = availableFooterTags.first(where: { $0.id == tagID }) else {
            return
        }
        dismissFooterTagPicker()
        Task { await viewModel.addTag(tag) }
    }

    private func createFooterTag(named tagName: String) {
        let trimmedTagName = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTagName.isEmpty else { return }
        dismissFooterTagPicker()
        Task { await viewModel.createAndAddTag(named: trimmedTagName) }
    }

    private func openTagSettings() {
        dismissFooterTagPicker()
        NSApp.activate(ignoringOtherApps: true)
        DashboardWindowController.shared.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .openSettingsTags, object: nil)
        }
    }

    private func dismissFooterTagPicker() {
        withAnimation(.easeOut(duration: 0.12)) {
            isShowingTagPicker = false
        }
        isCommentFocused = true
    }

    private func submitComment() {
        Task { @MainActor in
            isShowingTagPicker = false
            let didSubmit = await viewModel.submitComment()
            guard didSubmit else { return }

            withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                isShowingSuccess = true
            }

            successDismissTask?.cancel()
            successDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(850), clock: .continuous)
                guard !Task.isCancelled else { return }
                onClose()
            }
        }
    }

    private func submitCommentFromKeyboard() {
        guard viewModel.canSubmitComment else { return }
        submitComment()
    }
}
