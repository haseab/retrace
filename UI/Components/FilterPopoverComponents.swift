import SwiftUI
import Shared
import AppKit

// MARK: - Filter Row

/// Reusable filter row component matching the spotlight search style
/// Used in apps, tags, and visibility filter popovers
public struct FilterRow: View {
    let icon: Image?
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    public init(
        icon: Image? = nil,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.action = action
    }

    /// Convenience initializer for SF Symbol icons
    public init(
        systemIcon: String,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.icon = Image(systemName: systemIcon)
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.action = action
    }

    /// Convenience initializer for NSImage icons (app icons)
    public init(
        nsImage: NSImage?,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        if let nsImage = nsImage {
            self.icon = Image(nsImage: nsImage)
        } else {
            self.icon = Image(systemName: "app.fill")
        }
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: RetraceMenuStyle.iconTextSpacing) {
                // Icon
                if let icon = icon {
                    icon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: RetraceMenuStyle.iconFrameWidth)
                        .foregroundColor(RetraceMenuStyle.textColorMuted)
                }

                // Title and optional subtitle
                if let subtitle = subtitle {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(RetraceMenuStyle.font)
                            .foregroundColor(isHovered ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(RetraceMenuStyle.textColorMuted.opacity(0.7))
                            .lineLimit(1)
                    }
                } else {
                    Text(title)
                        .font(RetraceMenuStyle.font)
                        .foregroundColor(isHovered ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted)
                        .lineLimit(1)
                }

                Spacer()

                // Checkmark for selected
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(RetraceMenuStyle.actionBlue)
                }
            }
            .padding(.horizontal, RetraceMenuStyle.itemPaddingH)
            .padding(.vertical, RetraceMenuStyle.itemPaddingV)
            .background(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                    .fill(isHovered ? RetraceMenuStyle.itemHoverColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: RetraceMenuStyle.hoverAnimationDuration)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

// MARK: - Filter Popover Container

/// Container view for filter popovers with consistent styling
public struct FilterPopoverContainer<Content: View>: View {
    let width: CGFloat
    let content: Content

    public init(width: CGFloat = 260, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    public var body: some View {
        let _ = print("[FilterPopoverContainer] Rendering with width=\(width)")
        VStack(spacing: 0) {
            content
        }
        .frame(width: width)
        .retraceMenuContainer(addPadding: false)
        .clipShape(RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius))
    }
}

// MARK: - Filter Search Field

/// Search field for filter popovers
public struct FilterSearchField: View {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding?

    public init(text: Binding<String>, placeholder: String = "Search...", isFocused: FocusState<Bool>.Binding? = nil) {
        self._text = text
        self.placeholder = placeholder
        self.isFocused = isFocused
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            textField
                .textFieldStyle(.plain)
                .font(RetraceMenuStyle.font)
                .foregroundColor(.white)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, RetraceMenuStyle.searchFieldPaddingH)
        .padding(.vertical, RetraceMenuStyle.searchFieldPaddingV)
        .background(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.searchFieldCornerRadius)
                .fill(RetraceMenuStyle.searchFieldBackground)
        )
    }

    @ViewBuilder
    private var textField: some View {
        if let isFocused = isFocused {
            TextField(placeholder, text: $text)
                .focused(isFocused)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

// MARK: - Apps Filter Popover (Reusable)

/// Reusable apps filter popover that can be used for both single and multi-select
/// Supports showing installed apps first, then "Other Apps" section for uninstalled apps
public struct AppsFilterPopover: View {
    let apps: [(bundleID: String, name: String)]
    let otherApps: [(bundleID: String, name: String)]
    let selectedApps: Set<String>?
    let allowMultiSelect: Bool
    let onSelectApp: (String?) -> Void
    var onDismiss: (() -> Void)?

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    public init(
        apps: [(bundleID: String, name: String)],
        otherApps: [(bundleID: String, name: String)] = [],
        selectedApps: Set<String>?,
        allowMultiSelect: Bool = false,
        onSelectApp: @escaping (String?) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.apps = apps
        self.otherApps = otherApps
        self.selectedApps = selectedApps
        self.allowMultiSelect = allowMultiSelect
        self.onSelectApp = onSelectApp
        self.onDismiss = onDismiss
    }

    private var filteredApps: [(bundleID: String, name: String)] {
        if searchText.isEmpty {
            return apps
        }
        return apps.filter { app in
            app.bundleID.localizedCaseInsensitiveContains(searchText) ||
            app.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredOtherApps: [(bundleID: String, name: String)] {
        if searchText.isEmpty {
            return otherApps
        }
        return otherApps.filter { app in
            app.bundleID.localizedCaseInsensitiveContains(searchText) ||
            app.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var isAllAppsSelected: Bool {
        selectedApps == nil || selectedApps!.isEmpty
    }

    public var body: some View {
        FilterPopoverContainer {
            // Search field
            FilterSearchField(text: $searchText, placeholder: "Search apps...", isFocused: $isSearchFocused)

            Divider()

            // App list
            ScrollView {
                LazyVStack(spacing: 0) {
                    // "All Apps" option
                    FilterRow(
                        systemIcon: "square.grid.2x2.fill",
                        title: "All Apps",
                        isSelected: isAllAppsSelected
                    ) {
                        onSelectApp(nil)
                        if !allowMultiSelect {
                            onDismiss?()
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // Installed apps
                    ForEach(filteredApps, id: \.bundleID) { app in
                        FilterRow(
                            nsImage: AppIconProvider.shared.icon(for: app.bundleID),
                            title: app.name,
                            isSelected: selectedApps?.contains(app.bundleID) ?? false
                        ) {
                            onSelectApp(app.bundleID)
                            if !allowMultiSelect {
                                onDismiss?()
                            }
                        }
                    }

                    // "Other Apps" section (uninstalled apps from history)
                    if !filteredOtherApps.isEmpty {
                        Divider()
                            .padding(.vertical, 8)

                        Text("Other Apps")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)

                        ForEach(filteredOtherApps, id: \.bundleID) { app in
                            FilterRow(
                                systemIcon: "app.dashed",
                                title: app.name,
                                isSelected: selectedApps?.contains(app.bundleID) ?? false
                            ) {
                                onSelectApp(app.bundleID)
                                if !allowMultiSelect {
                                    onDismiss?()
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
        }
        .onAppear {
            // Autofocus the search field when popover appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
    }
}

// MARK: - Tags Filter Popover (Reusable)

/// Reusable tags filter popover
public struct TagsFilterPopover: View {
    let tags: [Tag]
    let selectedTags: Set<Int64>?
    let allowMultiSelect: Bool
    let onSelectTag: (TagID?) -> Void
    var onDismiss: (() -> Void)?

    public init(
        tags: [Tag],
        selectedTags: Set<Int64>?,
        allowMultiSelect: Bool = false,
        onSelectTag: @escaping (TagID?) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.tags = tags
        self.selectedTags = selectedTags
        self.allowMultiSelect = allowMultiSelect
        self.onSelectTag = onSelectTag
        self.onDismiss = onDismiss
    }

    private var visibleTags: [Tag] {
        tags.filter { !$0.isHidden }
    }

    private var isAllTagsSelected: Bool {
        selectedTags == nil || selectedTags!.isEmpty
    }

    public var body: some View {
        FilterPopoverContainer(width: 220) {
            if visibleTags.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag.slash")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("No tags created")
                        .font(.retraceCaption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // "All Tags" option
                        FilterRow(
                            systemIcon: "tag",
                            title: "All Tags",
                            isSelected: isAllTagsSelected
                        ) {
                            onSelectTag(nil)
                            if !allowMultiSelect {
                                onDismiss?()
                            }
                        }

                        Divider()
                            .padding(.vertical, 4)

                        // Individual tags
                        ForEach(visibleTags) { tag in
                            FilterRow(
                                systemIcon: "tag.fill",
                                title: tag.name,
                                isSelected: selectedTags?.contains(tag.id.value) ?? false
                            ) {
                                onSelectTag(tag.id)
                                if !allowMultiSelect {
                                    onDismiss?()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 250)
            }
        }
    }
}

// MARK: - Visibility Filter Popover (Reusable)

/// Popover for selecting visibility filter (visible only, hidden only, all)
public struct VisibilityFilterPopover: View {
    let currentFilter: HiddenFilter
    let onSelect: (HiddenFilter) -> Void
    var onDismiss: (() -> Void)?

    public init(
        currentFilter: HiddenFilter,
        onSelect: @escaping (HiddenFilter) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.currentFilter = currentFilter
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    public var body: some View {
        FilterPopoverContainer(width: 240) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Visible Only option (default)
                    FilterRow(
                        systemIcon: "eye",
                        title: "Visible Only",
                        subtitle: "Show segments that aren't hidden",
                        isSelected: currentFilter == .hide
                    ) {
                        onSelect(.hide)
                        onDismiss?()
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // Hidden Only option
                    FilterRow(
                        systemIcon: "eye.slash",
                        title: "Hidden Only",
                        subtitle: "Show only hidden segments",
                        isSelected: currentFilter == .onlyHidden
                    ) {
                        onSelect(.onlyHidden)
                        onDismiss?()
                    }

                    // All Segments option
                    FilterRow(
                        systemIcon: "eye.circle",
                        title: "All Segments",
                        subtitle: "Show both visible and hidden",
                        isSelected: currentFilter == .showAll
                    ) {
                        onSelect(.showAll)
                        onDismiss?()
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 200)
        }
    }
}

// MARK: - Dropdown Overlay View Modifier

/// A view modifier that displays content as a dropdown overlay above or below the modified view.
/// Opens instantly without NSPopover window creation overhead.
public struct DropdownOverlayModifier<DropdownContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let yOffset: CGFloat
    let opensUpward: Bool
    let dropdownContent: () -> DropdownContent

    public init(
        isPresented: Binding<Bool>,
        yOffset: CGFloat = 44,
        opensUpward: Bool = false,
        @ViewBuilder dropdownContent: @escaping () -> DropdownContent
    ) {
        self._isPresented = isPresented
        self.yOffset = yOffset
        self.opensUpward = opensUpward
        self.dropdownContent = dropdownContent
    }

    public func body(content: Content) -> some View {
        let _ = print("[DropdownOverlay] Rendering, isPresented=\(isPresented), opensUpward=\(opensUpward), yOffset=\(yOffset)")
        content
            .background(GeometryReader { geo in
                Color.clear.onAppear {
                    print("[DropdownOverlay] Anchor content frame: \(geo.frame(in: .global))")
                }.onChange(of: isPresented) { _ in
                    print("[DropdownOverlay] Anchor content frame (on change): \(geo.frame(in: .global))")
                }
            })
            .overlay(alignment: opensUpward ? .bottomLeading : .topLeading) {
                if isPresented {
                    let _ = print("[DropdownOverlay] Showing dropdown content with zIndex=1000")
                    // Wrap content in a background container to ensure solid background
                    ZStack {
                        // Solid background layer
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .windowBackgroundColor))

                        // Actual content on top
                        dropdownContent()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: opensUpward ? -4 : 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .offset(y: opensUpward ? -yOffset : yOffset)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: opensUpward ? .bottom : .top)))
                    .zIndex(1000)
                    .background(GeometryReader { geo in
                        Color.clear.onAppear {
                            print("[DropdownOverlay] Dropdown content frame: \(geo.frame(in: .global))")
                        }
                    })
                }
            }
    }
}

public extension View {
    /// Attaches a dropdown overlay that appears below the view when `isPresented` is true.
    /// Uses a custom overlay approach instead of `.popover()` for instant opening.
    func dropdownOverlay<Content: View>(
        isPresented: Binding<Bool>,
        yOffset: CGFloat = 44,
        opensUpward: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(DropdownOverlayModifier(isPresented: isPresented, yOffset: yOffset, opensUpward: opensUpward, dropdownContent: content))
    }
}
