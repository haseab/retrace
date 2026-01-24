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
            HStack(spacing: 10) {
                // Icon
                if let icon = icon {
                    icon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .foregroundColor(.secondary)
                }

                // Title and optional subtitle
                if let subtitle = subtitle {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.retraceCaption)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(title)
                        .font(.retraceCaption)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                Spacer()

                // Checkmark for selected
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.retraceCaption2Bold)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
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
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.15))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Filter Search Field

/// Search field for filter popovers
public struct FilterSearchField: View {
    @Binding var text: String
    let placeholder: String

    public init(text: Binding<String>, placeholder: String = "Search...") {
        self._text = text
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.retraceCaption2)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.retraceCaption)
        }
        .padding(10)
        .background(Color(white: 0.08))
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
            FilterSearchField(text: $searchText, placeholder: "Search apps...")

            Divider()

            // App list
            ScrollView {
                LazyVStack(spacing: 0) {
                    // "All Apps" option
                    FilterRow(
                        systemIcon: "app.fill",
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

/// A view modifier that displays content as a dropdown overlay below the modified view.
/// Opens instantly without NSPopover window creation overhead.
public struct DropdownOverlayModifier<DropdownContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let yOffset: CGFloat
    let dropdownContent: () -> DropdownContent

    public init(
        isPresented: Binding<Bool>,
        yOffset: CGFloat = 44,
        @ViewBuilder dropdownContent: @escaping () -> DropdownContent
    ) {
        self._isPresented = isPresented
        self.yOffset = yOffset
        self.dropdownContent = dropdownContent
    }

    public func body(content: Content) -> some View {
        let _ = print("[DropdownOverlayModifier] body called, isPresented=\(isPresented)")
        content
            .overlay(alignment: .topLeading) {
                if isPresented {
                    let _ = print("[DropdownOverlayModifier] Rendering dropdown content with background")
                    // Wrap content in a background container to ensure solid background
                    ZStack {
                        // Solid background layer
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .windowBackgroundColor))

                        // Actual content on top
                        dropdownContent()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .contentShape(Rectangle()) // Capture all hits including scroll
                    .offset(y: yOffset)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                    .zIndex(1000) // Ensure dropdown is above everything
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
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(DropdownOverlayModifier(isPresented: isPresented, yOffset: yOffset, dropdownContent: content))
    }
}
