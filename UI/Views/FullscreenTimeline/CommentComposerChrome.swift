import SwiftUI
import AppKit
import Shared

struct CommentChromeHeader<Leading: View, Accessory: View>: View {
    let title: String
    let onClose: () -> Void
    let spacing: CGFloat
    let iconContainerSize: CGFloat
    let iconCornerRadius: CGFloat
    let iconFont: Font
    let leading: Leading
    let accessory: Accessory

    init(
        title: String,
        onClose: @escaping () -> Void,
        spacing: CGFloat = 12,
        iconContainerSize: CGFloat = 34,
        iconCornerRadius: CGFloat = 10,
        iconFont: Font = .system(size: 14, weight: .semibold),
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.onClose = onClose
        self.spacing = spacing
        self.iconContainerSize = iconContainerSize
        self.iconCornerRadius = iconCornerRadius
        self.iconFont = iconFont
        self.leading = leading()
        self.accessory = accessory()
    }

    init(
        title: String,
        onClose: @escaping () -> Void,
        spacing: CGFloat = 12,
        iconContainerSize: CGFloat = 34,
        iconCornerRadius: CGFloat = 10,
        iconFont: Font = .system(size: 14, weight: .semibold),
        @ViewBuilder accessory: () -> Accessory
    ) where Leading == EmptyView {
        self.init(
            title: title,
            onClose: onClose,
            spacing: spacing,
            iconContainerSize: iconContainerSize,
            iconCornerRadius: iconCornerRadius,
            iconFont: iconFont,
            leading: { EmptyView() },
            accessory: accessory
        )
    }

    init(
        title: String,
        onClose: @escaping () -> Void,
        spacing: CGFloat = 12,
        iconContainerSize: CGFloat = 34,
        iconCornerRadius: CGFloat = 10,
        iconFont: Font = .system(size: 14, weight: .semibold)
    ) where Leading == EmptyView, Accessory == EmptyView {
        self.init(
            title: title,
            onClose: onClose,
            spacing: spacing,
            iconContainerSize: iconContainerSize,
            iconCornerRadius: iconCornerRadius,
            iconFont: iconFont,
            leading: { EmptyView() },
            accessory: { EmptyView() }
        )
    }

    var body: some View {
        HStack(spacing: spacing) {
            leading

            RoundedRectangle(cornerRadius: iconCornerRadius)
                .fill(Color.white.opacity(0.08))
                .frame(width: iconContainerSize, height: iconContainerSize)
                .overlay(
                    Image(systemName: "text.bubble.fill")
                        .font(iconFont)
                        .foregroundColor(.retracePrimary.opacity(0.92))
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.retracePrimary)
            }

            Spacer()

            accessory

            CommentChromeCircleButton(
                icon: "xmark",
                action: onClose,
                iconFont: .system(size: 10, weight: .bold),
                baseForeground: .retraceSecondary,
                hoverForeground: Color.retracePrimary.opacity(0.96),
                baseFill: Color.white.opacity(0.08),
                hoverFill: Color.retraceSubmitAccent.opacity(0.13),
                baseStroke: Color.white.opacity(0.14),
                hoverStroke: Color.retraceSubmitAccent.opacity(0.42)
            )
        }
    }
}

struct CommentChromeCircleButton: View {
    let icon: String
    let action: () -> Void
    var iconFont: Font = .system(size: 10, weight: .bold)
    var baseForeground: Color = .retraceSecondary
    var hoverForeground: Color = Color.retracePrimary.opacity(0.96)
    var baseFill: Color = Color.white.opacity(0.08)
    var hoverFill: Color = Color.retraceSubmitAccent.opacity(0.13)
    var baseStroke: Color = Color.white.opacity(0.14)
    var hoverStroke: Color = Color.retraceSubmitAccent.opacity(0.42)
    var onHoverChanged: ((Bool) -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(iconFont)
                .foregroundColor(isHovering ? hoverForeground : baseForeground)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isHovering ? hoverFill : baseFill)
                )
                .overlay(
                    Circle()
                        .stroke(isHovering ? hoverStroke : baseStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            onHoverChanged?(hovering)
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

enum CommentChromeCapsuleButtonStyle: Equatable {
    case accentOutline
    case submit
    case tagSelection(isSelected: Bool)

    func foregroundColor(isHovering: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return .retraceSecondary }

        switch self {
        case .accentOutline:
            return isHovering
                ? Color.retracePrimary.opacity(0.98)
                : Color.retracePrimary.opacity(0.9)
        case .submit:
            return isHovering
                ? Color.retracePrimary.opacity(0.98)
                : Color.retraceSubmitAccent.opacity(0.96)
        case .tagSelection(let isSelected):
            if isSelected {
                return .white
            }
            return isHovering
                ? Color.retracePrimary.opacity(0.98)
                : Color.retraceSecondary.opacity(0.96)
        }
    }

    func backgroundColor(isHovering: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return Color.white.opacity(0.08) }

        switch self {
        case .accentOutline:
            return isHovering
                ? Color.retraceSubmitAccent.opacity(0.13)
                : Color.white.opacity(0.08)
        case .submit:
            return isHovering
                ? Color.retraceSubmitAccent.opacity(0.18)
                : Color.retraceSubmitAccent.opacity(0.14)
        case .tagSelection(let isSelected):
            if isSelected {
                return Color.white.opacity(0.2)
            }
            return isHovering
                ? Color.white.opacity(0.12)
                : Color.white.opacity(0.08)
        }
    }

    func borderColor(isHovering: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return Color.white.opacity(0.12) }

        switch self {
        case .accentOutline:
            return isHovering
                ? Color.retraceSubmitAccent.opacity(0.42)
                : Color.white.opacity(0.14)
        case .submit:
            return isHovering
                ? Color.retraceSubmitAccent.opacity(0.42)
                : Color.retraceSubmitAccent.opacity(0.28)
        case .tagSelection(let isSelected):
            if isSelected {
                return Color.white.opacity(0.24)
            }
            return isHovering
                ? Color.white.opacity(0.18)
                : Color.white.opacity(0.12)
        }
    }
}

struct CommentChromeCapsuleButton<Label: View>: View {
    let action: () -> Void
    var isEnabled: Bool = true
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 6
    var style: CommentChromeCapsuleButtonStyle = .accentOutline
    var onHoverChanged: ((Bool) -> Void)? = nil
    let label: Label

    @State private var isHovering = false

    init(
        action: @escaping () -> Void,
        isEnabled: Bool = true,
        horizontalPadding: CGFloat = 14,
        verticalPadding: CGFloat = 6,
        style: CommentChromeCapsuleButtonStyle = .accentOutline,
        onHoverChanged: ((Bool) -> Void)? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.isEnabled = isEnabled
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.style = style
        self.onHoverChanged = onHoverChanged
        self.label = label()
    }

    var body: some View {
        let isActivelyHovering = isHovering && isEnabled

        Button(action: action) {
            label
                .foregroundColor(style.foregroundColor(isHovering: isActivelyHovering, isEnabled: isEnabled))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    Capsule()
                        .fill(style.backgroundColor(isHovering: isActivelyHovering, isEnabled: isEnabled))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            style.borderColor(isHovering: isActivelyHovering, isEnabled: isEnabled),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovering = hovering
            onHoverChanged?(hovering)
            if hovering && isEnabled {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct CommentChromeChip<Accessory: View>: View {
    let text: String
    let icon: String
    let foregroundColor: Color
    let backgroundColor: Color
    let borderColor: Color
    let accessory: (Bool) -> Accessory

    @State private var isHovering = false

    init(
        text: String,
        icon: String,
        foregroundColor: Color,
        backgroundColor: Color,
        borderColor: Color,
        @ViewBuilder accessory: @escaping (Bool) -> Accessory
    ) {
        self.text = text
        self.icon = icon
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.accessory = accessory
    }

    init(
        text: String,
        icon: String,
        foregroundColor: Color,
        backgroundColor: Color,
        borderColor: Color
    ) where Accessory == EmptyView {
        self.init(
            text: text,
            icon: icon,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
            borderColor: borderColor,
            accessory: { _ in EmptyView() }
        )
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))

            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)

            accessory(isHovering)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(backgroundColor)
        )
        .overlay(
            Capsule()
                .stroke(borderColor, lineWidth: 1)
        )
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct CommentChromeEditorSurface<Editor: View>: View {
    let isFocused: Bool
    let textIsEmpty: Bool
    let placeholder: String
    let editor: Editor

    init(
        isFocused: Bool,
        textIsEmpty: Bool,
        placeholder: String,
        @ViewBuilder editor: () -> Editor
    ) {
        self.isFocused = isFocused
        self.textIsEmpty = textIsEmpty
        self.placeholder = placeholder
        self.editor = editor()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            editor

            if textIsEmpty {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundColor(.retraceSecondary.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isFocused ? Color.white.opacity(0.22) : Color.white.opacity(0.1),
                    lineWidth: 1
                )
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

enum CommentTagPickerStyle {
    case contextMenu
    case commentOverlay

    var backgroundColor: Color {
        switch self {
        case .contextMenu:
            return RetraceMenuStyle.backgroundColor
        case .commentOverlay:
            return RetraceMenuStyle.backgroundColor
        }
    }

    var borderColor: Color {
        switch self {
        case .contextMenu:
            return Color.white.opacity(0.15)
        case .commentOverlay:
            return RetraceMenuStyle.borderColor
        }
    }
}

struct CommentTagPickerMenu: View {
    let tags: [Tag]
    let selectedTagIDs: Set<TagID>
    let style: CommentTagPickerStyle
    let dismissOnEscape: (() -> Void)?
    let onHoverChanged: ((Bool) -> Void)?
    let onSelectTag: (Tag) -> Void
    let onCreateTag: (String) -> Void
    let onOpenSettings: () -> Void

    @State private var searchText = ""
    @State private var highlightedTagID: Int64?
    @State private var isHoveringSettingsButton = false
    @State private var keyboardMonitor: Any?
    @FocusState private var isSearchFocused: Bool

    init(
        tags: [Tag],
        selectedTagIDs: Set<TagID>,
        style: CommentTagPickerStyle = .contextMenu,
        dismissOnEscape: (() -> Void)? = nil,
        onHoverChanged: ((Bool) -> Void)? = nil,
        onSelectTag: @escaping (Tag) -> Void,
        onCreateTag: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.tags = tags
        self.selectedTagIDs = selectedTagIDs
        self.style = style
        self.dismissOnEscape = dismissOnEscape
        self.onHoverChanged = onHoverChanged
        self.onSelectTag = onSelectTag
        self.onCreateTag = onCreateTag
        self.onOpenSettings = onOpenSettings
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleTags: [Tag] {
        let filtered = trimmedSearchText.isEmpty
            ? tags
            : tags.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearchText) }

        return filtered.sorted { lhs, rhs in
            let lhsSelected = selectedTagIDs.contains(lhs.id)
            let rhsSelected = selectedTagIDs.contains(rhs.id)
            if lhsSelected != rhsSelected {
                return lhsSelected
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var exactTagMatch: Bool {
        tags.contains { $0.name.caseInsensitiveCompare(trimmedSearchText) == .orderedSame }
    }

    private var showCreateOption: Bool {
        !trimmedSearchText.isEmpty && !exactTagMatch
    }

    private var visibleTagIDs: [Int64] {
        visibleTags.map { $0.id.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))

                TextField("Search or create...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .focused($isSearchFocused)
                    .onSubmit {
                        selectHighlightedTagOrCreate()
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                isSearchFocused = true
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 6)

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 8)

            if visibleTags.isEmpty && !showCreateOption {
                Text("No tags found")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleTags) { tag in
                            TagSubmenuRow(
                                tag: tag,
                                isSelected: selectedTagIDs.contains(tag.id),
                                isKeyboardHighlighted: highlightedTagID == tag.id.value,
                                onHoverChanged: { hovering in
                                    if hovering {
                                        highlightedTagID = tag.id.value
                                    }
                                }
                            ) {
                                onSelectTag(tag)
                            }
                        }

                        if showCreateOption {
                            Button(action: createTagFromSearch) {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(LinearGradient.retraceAccentGradient)

                                    Text("Create \"\(trimmedSearchText)\"")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(LinearGradient.retraceAccentGradient)

                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() }
                                else { NSCursor.pop() }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 8)
                .padding(.top, 6)

            Button(action: onOpenSettings) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))

                    Text("Tag Settings")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))

                    Spacer()
                }
                .padding(.leading, 0)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHoveringSettingsButton ? Color.white.opacity(0.1) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    isHoveringSettingsButton = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
        .padding(.vertical, 2)
        .frame(width: 180)
        .background(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius)
                .fill(style.backgroundColor)
                .shadow(
                    color: RetraceMenuStyle.shadowColor,
                    radius: RetraceMenuStyle.shadowRadius,
                    y: RetraceMenuStyle.shadowY
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius)
                .stroke(style.borderColor, lineWidth: RetraceMenuStyle.borderWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius))
        .compositingGroup()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
            syncHighlightedTagToFirstVisibleResult()
            installKeyboardMonitor()
        }
        .onChange(of: searchText) { _ in
            syncHighlightedTagToFirstVisibleResult()
        }
        .onChange(of: visibleTagIDs) { _ in
            syncHighlightedTagToFirstVisibleResult()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .onHover { hovering in
            onHoverChanged?(hovering)
        }
        .keyboardNavigation(
            onUpArrow: { moveHighlight(by: -1) },
            onDownArrow: { moveHighlight(by: 1) },
            onReturn: {
                selectHighlightedTagOrCreate()
            }
        )
    }

    private func syncHighlightedTagToFirstVisibleResult() {
        if let highlightedTagID, visibleTagIDs.contains(highlightedTagID) {
            return
        }
        highlightedTagID = visibleTagIDs.first
    }

    private func moveHighlight(by offset: Int) {
        guard !visibleTagIDs.isEmpty else { return }
        let currentIndex: Int
        if let highlightedTagID,
           let existingIndex = visibleTagIDs.firstIndex(of: highlightedTagID) {
            currentIndex = existingIndex
        } else {
            currentIndex = 0
        }

        let nextIndex = max(0, min(visibleTagIDs.count - 1, currentIndex + offset))
        highlightedTagID = visibleTagIDs[nextIndex]
    }

    private func selectHighlightedTagOrCreate() {
        if showCreateOption {
            createTagFromSearch()
        } else if let highlightedTagID,
                  let highlightedTag = visibleTags.first(where: { $0.id.value == highlightedTagID }) {
            onSelectTag(highlightedTag)
        }
    }

    private func createTagFromSearch() {
        guard !trimmedSearchText.isEmpty else { return }
        onCreateTag(trimmedSearchText)
        searchText = ""
    }

    private func installKeyboardMonitor() {
        guard dismissOnEscape != nil else { return }
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                dismissOnEscape?()
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }
}

struct CommentChromeSectionCard<Content: View>: View {
    var cornerRadius: CGFloat = 14
    let content: Content

    init(cornerRadius: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.045),
                                Color.white.opacity(0.022)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}
