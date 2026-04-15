import AppKit
import Shared
import SwiftUI

// MARK: - Context Menu Dismiss Overlay

/// Overlay that dismisses the context menu on left-click, lets right-clicks pass through
struct ContextMenuDismissOverlay: NSViewRepresentable {
    @ObservedObject var viewModel: SimpleTimelineViewModel

    func makeNSView(context: Context) -> ContextMenuDismissNSView {
        let view = ContextMenuDismissNSView()
        view.viewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: ContextMenuDismissNSView, context: Context) {
        nsView.viewModel = viewModel
    }
}

/// NSView that handles left-clicks to dismiss, passes right-clicks through
final class ContextMenuDismissNSView: NSView {
    weak var viewModel: SimpleTimelineViewModel?

    override func mouseDown(with event: NSEvent) {
        guard let viewModel else { return }
        DispatchQueue.main.async {
            viewModel.dismissTimelineContextMenu()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else {
            return self
        }

        if event.type == .rightMouseDown {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.dismissTimelineContextMenu()
            }
            return nil
        }

        return self
    }
}

enum TimelineSegmentContextMenuSupport {
    static let menuSize = CGSize(width: 208, height: 172)
    static let tagSubmenuWidth: CGFloat = 188
    static let edgePadding: CGFloat = 16
    static let submenuGap: CGFloat = 4
    static let tagRowOffset: CGFloat = 40

    static func shouldShowAbove(
        location: CGPoint,
        containerSize: CGSize,
        menuHeight: CGFloat = menuSize.height,
        edgePadding: CGFloat = edgePadding
    ) -> Bool {
        location.y + menuHeight > containerSize.height - edgePadding
    }

    static func adjustedMenuPosition(
        location: CGPoint,
        containerSize: CGSize,
        menuSize: CGSize = menuSize,
        edgePadding: CGFloat = edgePadding
    ) -> CGPoint {
        let showAbove = shouldShowAbove(
            location: location,
            containerSize: containerSize,
            menuHeight: menuSize.height,
            edgePadding: edgePadding
        )

        var x = location.x + menuSize.width / 2
        var y = showAbove ? (location.y - menuSize.height / 2) : (location.y + menuSize.height / 2)

        if x + menuSize.width / 2 > containerSize.width - edgePadding {
            x = containerSize.width - menuSize.width / 2 - edgePadding
        }
        if x - menuSize.width / 2 < edgePadding {
            x = menuSize.width / 2 + edgePadding
        }

        if y - menuSize.height / 2 < edgePadding {
            y = menuSize.height / 2 + edgePadding
        }
        if y + menuSize.height / 2 > containerSize.height - edgePadding {
            y = containerSize.height - menuSize.height / 2 - edgePadding
        }

        return CGPoint(x: x, y: y)
    }

    static func submenuPosition(
        menuPosition: CGPoint,
        containerSize: CGSize,
        menuSize: CGSize = menuSize,
        submenuWidth: CGFloat,
        rowOffset: CGFloat,
        edgePadding: CGFloat = edgePadding,
        submenuGap: CGFloat = submenuGap
    ) -> CGPoint {
        var x = menuPosition.x + menuSize.width / 2 + submenuWidth / 2 + submenuGap
        let y = menuPosition.y - menuSize.height / 2 + rowOffset

        if x + submenuWidth / 2 > containerSize.width - edgePadding {
            x = menuPosition.x - menuSize.width / 2 - submenuWidth / 2 - submenuGap
        }

        return CGPoint(x: x, y: y)
    }

    static func transitionAnchorPoint(showAbove: Bool) -> UnitPoint {
        showAbove ? .bottomLeading : .topLeading
    }
}

// MARK: - Timeline Segment Context Menu

/// Context menu for right-clicking on timeline segments (Add Tag, Add Comment, Hide, Delete)
struct TimelineSegmentContextMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @Binding var isPresented: Bool
    let location: CGPoint
    let containerSize: CGSize

    private var selectedTagsForContextMenu: [Tag] {
        viewModel.availableTags
            .filter { !($0.isHidden) && viewModel.selectedSegmentTags.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var adjustedPosition: CGPoint {
        TimelineSegmentContextMenuSupport.adjustedMenuPosition(
            location: location,
            containerSize: containerSize
        )
    }

    private var tagSubmenuPosition: CGPoint {
        TimelineSegmentContextMenuSupport.submenuPosition(
            menuPosition: adjustedPosition,
            containerSize: containerSize,
            submenuWidth: TimelineSegmentContextMenuSupport.tagSubmenuWidth,
            rowOffset: TimelineSegmentContextMenuSupport.tagRowOffset
        )
    }

    private var transitionAnchorPoint: UnitPoint {
        TimelineSegmentContextMenuSupport.transitionAnchorPoint(
            showAbove: TimelineSegmentContextMenuSupport.shouldShowAbove(
                location: location,
                containerSize: containerSize
            )
        )
    }

    var body: some View {
        ZStack {
            ContextMenuDismissOverlay(viewModel: viewModel)

            VStack(alignment: .leading, spacing: 0) {
                TimelineTagMenuButton(
                    selectedTags: selectedTagsForContextMenu,
                    onHoverChanged: { isHovering in
                        viewModel.setHoveringAddTagButton(isHovering)
                        if isHovering && !viewModel.showTagSubmenu {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showTagSubmenuFromContextMenu(source: "context_menu_hover")
                            }
                        }
                    }
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.toggleTagSubmenuFromContextMenu(source: "context_menu_click")
                    }
                }

                TimelineMenuButton(
                    icon: "text.bubble",
                    title: "Add Comment",
                    shortcut: "⌥C",
                    onHoverChanged: { isHovering in
                        if isHovering && viewModel.showTagSubmenu {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.closeTagSubmenuPreservingDraft()
                            }
                        }
                    }
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.openCommentSubmenuFromContextMenu(source: "context_menu_click")
                    }
                }

                TimelineMenuButton(
                    icon: "line.3.horizontal.decrease",
                    title: "Filter App",
                    shortcut: "⌥F",
                    onHoverChanged: { isHovering in
                        if isHovering && (viewModel.showTagSubmenu || viewModel.showCommentSubmenu) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.dismissTimelineContextSubmenus()
                            }
                        }
                    }
                ) {
                    viewModel.toggleQuickAppFilterForSelectedTimelineSegment()
                }

                TimelineMenuButton(
                    icon: "eye.slash",
                    title: "Hide",
                    shortcut: "⌥H",
                    onHoverChanged: { isHovering in
                        if isHovering && (viewModel.showTagSubmenu || viewModel.showCommentSubmenu) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.dismissTimelineContextSubmenus()
                            }
                        }
                    }
                ) {
                    viewModel.hideSelectedTimelineSegment()
                }

                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.vertical, 4)

                TimelineMenuButton(
                    icon: "trash",
                    title: "Delete",
                    shortcut: "⌫",
                    isDestructive: true,
                    onHoverChanged: { isHovering in
                        if isHovering && (viewModel.showTagSubmenu || viewModel.showCommentSubmenu) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.dismissTimelineContextSubmenus()
                            }
                        }
                    }
                ) {
                    viewModel.requestDeleteFromTimelineMenu()
                }
            }
            .padding(.vertical, 8)
            .frame(width: TimelineSegmentContextMenuSupport.menuSize.width)
            .retraceMenuContainer()
            .position(adjustedPosition)

            if viewModel.showTagSubmenu {
                TagSubmenu(viewModel: viewModel)
                    .position(tagSubmenuPosition)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
            }
        }
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: transitionAnchorPoint)),
                removal: .opacity.combined(with: .scale(scale: 0.98, anchor: transitionAnchorPoint))
            )
        )
        .animation(.easeOut(duration: 0.15), value: isPresented)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: viewModel.showTagSubmenu)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: viewModel.showCommentSubmenu)
    }
}

// MARK: - Timeline Menu Button

typealias TimelineMenuButton = RetraceMenuButton

/// Specialized tag row for the timeline context menu.
/// Shows compact selected-tag badges, and only shows the shortcut hint in the neutral "Add Tag" state.
struct TimelineTagMenuButton: View {
    let selectedTags: [Tag]
    var onHoverChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    private var isTagged: Bool { !selectedTags.isEmpty }
    private var icon: String { "tag" }
    private var visibleTags: [Tag] { Array(selectedTags.prefix(2)) }
    private var overflowCount: Int { max(0, selectedTags.count - visibleTags.count) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: RetraceMenuStyle.iconTextSpacing) {
                Image(systemName: icon)
                    .font(.system(size: RetraceMenuStyle.iconSize, weight: RetraceMenuStyle.fontWeight))
                    .foregroundColor(foregroundColor)
                    .frame(width: RetraceMenuStyle.iconFrameWidth)

                if isTagged {
                    HStack(spacing: 4) {
                        ForEach(visibleTags) { tag in
                            tagBadge(tag)
                        }

                        if overflowCount > 0 {
                            Text("+\(overflowCount)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(isHovering ? 0.9 : 0.75))
                                .padding(.horizontal, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Add Tag")
                        .font(RetraceMenuStyle.font)
                        .foregroundColor(foregroundColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    Spacer(minLength: 0)

                    Text("⌥T")
                        .font(RetraceMenuStyle.shortcutFont)
                        .foregroundColor(shortcutColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: RetraceMenuStyle.shortcutColumnMinWidth, alignment: .trailing)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: RetraceMenuStyle.chevronSize, weight: .bold))
                    .foregroundColor(RetraceMenuStyle.chevronColor)
            }
            .padding(.horizontal, RetraceMenuStyle.itemPaddingH)
            .padding(.vertical, RetraceMenuStyle.itemPaddingV)
            .background(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                    .fill(isHovering ? RetraceMenuStyle.itemHoverColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: RetraceMenuStyle.hoverAnimationDuration)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
            onHoverChanged?(hovering)
        }
    }

    private var foregroundColor: Color {
        isHovering ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted
    }

    private var shortcutColor: Color {
        RetraceMenuStyle.textColorMuted.opacity(isHovering ? 0.95 : 0.7)
    }

    @ViewBuilder
    private func tagBadge(_ tag: Tag) -> some View {
        let tint = TagColorStore.color(for: tag)
        HStack(spacing: 4) {
            Circle()
                .fill(tint.opacity(0.95))
                .frame(width: 5, height: 5)

            Text(tag.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(isHovering ? 0.95 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: 62)
        .background(
            Capsule()
                .fill(tint.opacity(isHovering ? 0.26 : 0.18))
        )
        .overlay(
            Capsule()
                .stroke(tint.opacity(isHovering ? 0.45 : 0.32), lineWidth: 0.8)
        )
    }
}

// MARK: - Tag Submenu

/// Submenu showing available tags with search/create functionality
struct TagSubmenu: View {
    enum Presentation {
        case contextMenu
        case commentOverlay
    }

    @ObservedObject var viewModel: SimpleTimelineViewModel
    let presentation: Presentation
    @State private var isHoveringSubmenu = false
    @State private var closeTask: Task<Void, Never>?

    init(viewModel: SimpleTimelineViewModel, presentation: Presentation = .contextMenu) {
        self.viewModel = viewModel
        self.presentation = presentation
    }

    private var style: CommentTagPickerStyle {
        switch presentation {
        case .contextMenu:
            return .contextMenu
        case .commentOverlay:
            return .commentOverlay
        }
    }

    var body: some View {
        CommentTagPickerMenu(
            tags: viewModel.availableTags.filter { !$0.isHidden },
            selectedTagIDs: viewModel.selectedSegmentTags,
            style: style,
            onHoverChanged: handleHoverChange,
            onSelectTag: { tag in
                viewModel.toggleTagOnSelectedSegment(tag: tag)
            },
            onCreateTag: { tagName in
                viewModel.createAndAddTag(named: tagName)
            },
            onOpenSettings: openTagSettings
        )
    }

    private func openTagSettings() {
        closeTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            viewModel.closeTagSubmenuPreservingDraft()
            viewModel.setTimelineContextMenuVisible(false)
        }

        TimelineWindowController.shared.hideToShowDashboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            DashboardWindowController.shared.show()
            NotificationCenter.default.post(name: .openSettingsTags, object: nil)
        }
    }

    private func handleHoverChange(_ hovering: Bool) {
        isHoveringSubmenu = hovering
        if !hovering {
            closeTask?.cancel()
            closeTask = Task {
                try? await Task.sleep(for: .nanoseconds(Int64(220_000_000)), clock: .continuous)
                if !Task.isCancelled && !isHoveringSubmenu && !viewModel.isHoveringAddTagButton {
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.closeTagSubmenuPreservingDraft()
                        }
                    }
                }
            }
        } else {
            closeTask?.cancel()
        }
    }
}
