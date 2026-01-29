import SwiftUI
import Shared
import AppKit

// MARK: - Focus Effect Disabled Modifier (macOS 13.0+ compatible)

/// Modifier that hides the focus ring, with availability check for macOS 14.0+
private struct FocusEffectDisabledModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

// MARK: - Keyboard Navigation Handler

/// View modifier that handles arrow key and return key navigation for filter popovers
/// Compatible with macOS 13.0+
private struct KeyboardNavigationModifier: ViewModifier {
    let onUpArrow: () -> Void
    let onDownArrow: () -> Void
    let onReturn: () -> Void

    @State private var eventMonitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    switch event.keyCode {
                    case 126: // Up arrow
                        self.onUpArrow()
                        return nil // Consume the event
                    case 125: // Down arrow
                        self.onDownArrow()
                        return nil // Consume the event
                    case 36: // Return key
                        self.onReturn()
                        return nil // Consume the event
                    default:
                        return event // Pass through other events
                    }
                }
            }
            .onDisappear {
                if let monitor = eventMonitor {
                    NSEvent.removeMonitor(monitor)
                    eventMonitor = nil
                }
            }
    }
}

extension View {
    func keyboardNavigation(
        onUpArrow: @escaping () -> Void,
        onDownArrow: @escaping () -> Void,
        onReturn: @escaping () -> Void
    ) -> some View {
        modifier(KeyboardNavigationModifier(
            onUpArrow: onUpArrow,
            onDownArrow: onDownArrow,
            onReturn: onReturn
        ))
    }
}

// MARK: - Filter Row

/// Reusable filter row component matching the spotlight search style
/// Used in apps, tags, and visibility filter popovers
public struct FilterRow: View {
    let icon: Image?
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let isKeyboardHighlighted: Bool
    let action: () -> Void

    @State private var isHovered = false

    public init(
        icon: Image? = nil,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        isKeyboardHighlighted: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.isKeyboardHighlighted = isKeyboardHighlighted
        self.action = action
    }

    /// Convenience initializer for SF Symbol icons
    public init(
        systemIcon: String,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        isKeyboardHighlighted: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = Image(systemName: systemIcon)
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.isKeyboardHighlighted = isKeyboardHighlighted
        self.action = action
    }

    /// Convenience initializer for NSImage icons (app icons)
    public init(
        nsImage: NSImage?,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        isKeyboardHighlighted: Bool = false,
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
        self.isKeyboardHighlighted = isKeyboardHighlighted
        self.action = action
    }

    private var shouldHighlight: Bool {
        isHovered || isKeyboardHighlighted
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
                        .foregroundColor(shouldHighlight ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted)
                }

                // Title and optional subtitle
                if let subtitle = subtitle {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(RetraceMenuStyle.font)
                            .foregroundColor(shouldHighlight ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(RetraceMenuStyle.textColorMuted.opacity(0.7))
                            .lineLimit(1)
                    }
                } else {
                    Text(title)
                        .font(RetraceMenuStyle.font)
                        .foregroundColor(shouldHighlight ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted)
                        .lineLimit(1)
                }

                Spacer()

                // Checkmark for selected
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, RetraceMenuStyle.itemPaddingH)
            .padding(.vertical, RetraceMenuStyle.itemPaddingV)
            .background(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                    .fill(shouldHighlight ? RetraceMenuStyle.itemHoverColor : Color.clear)
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
/// Supports include/exclude mode for flexible filtering
public struct AppsFilterPopover: View {
    let apps: [(bundleID: String, name: String)]
    let otherApps: [(bundleID: String, name: String)]
    let selectedApps: Set<String>?
    let filterMode: AppFilterMode
    let allowMultiSelect: Bool
    let onSelectApp: (String?) -> Void
    let onFilterModeChange: ((AppFilterMode) -> Void)?
    var onDismiss: (() -> Void)?

    @State private var searchText = ""
    /// Highlighted item ID: nil means "All Apps", otherwise it's the bundleID
    @State private var highlightedItemID: String? = nil
    /// Special flag to indicate "All Apps" is highlighted (since nil bundleID is ambiguous)
    @State private var isAllAppsHighlighted: Bool = true
    @FocusState private var isSearchFocused: Bool

    /// Cached initial selection state - used for sorting so list doesn't re-order while open
    @State private var initialSelectedApps: Set<String> = []

    public init(
        apps: [(bundleID: String, name: String)],
        otherApps: [(bundleID: String, name: String)] = [],
        selectedApps: Set<String>?,
        filterMode: AppFilterMode = .include,
        allowMultiSelect: Bool = false,
        onSelectApp: @escaping (String?) -> Void,
        onFilterModeChange: ((AppFilterMode) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.apps = apps
        self.otherApps = otherApps
        self.selectedApps = selectedApps
        self.filterMode = filterMode
        self.allowMultiSelect = allowMultiSelect
        self.onSelectApp = onSelectApp
        self.onFilterModeChange = onFilterModeChange
        self.onDismiss = onDismiss
    }

    private var filteredApps: [(bundleID: String, name: String)] {
        let baseApps: [(bundleID: String, name: String)]
        if searchText.isEmpty {
            baseApps = apps
        } else {
            baseApps = apps.filter { app in
                app.bundleID.localizedCaseInsensitiveContains(searchText) ||
                app.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        // Sort using INITIAL selection state so list doesn't jump while navigating
        return baseApps.sorted { app1, app2 in
            let app1Selected = initialSelectedApps.contains(app1.bundleID)
            let app2Selected = initialSelectedApps.contains(app2.bundleID)
            if app1Selected != app2Selected {
                return app1Selected
            }
            return app1.name.localizedCaseInsensitiveCompare(app2.name) == .orderedAscending
        }
    }

    private var filteredOtherApps: [(bundleID: String, name: String)] {
        let baseApps: [(bundleID: String, name: String)]
        if searchText.isEmpty {
            baseApps = otherApps
        } else {
            baseApps = otherApps.filter { app in
                app.bundleID.localizedCaseInsensitiveContains(searchText) ||
                app.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        // Sort using INITIAL selection state so list doesn't jump while navigating
        return baseApps.sorted { app1, app2 in
            let app1Selected = initialSelectedApps.contains(app1.bundleID)
            let app2Selected = initialSelectedApps.contains(app2.bundleID)
            if app1Selected != app2Selected {
                return app1Selected
            }
            return app1.name.localizedCaseInsensitiveCompare(app2.name) == .orderedAscending
        }
    }

    private var isAllAppsSelected: Bool {
        selectedApps == nil || selectedApps!.isEmpty
    }

    private var hasFilterModeSupport: Bool {
        onFilterModeChange != nil
    }

    /// Build a flat list of selectable bundle IDs for keyboard navigation
    /// nil at the start represents "All Apps" option
    private var selectableBundleIDs: [String?] {
        var ids: [String?] = []

        // "All Apps" option (only in include mode and not searching)
        if filterMode == .include && searchText.isEmpty {
            ids.append(nil)
        }

        // Installed apps
        for app in filteredApps {
            ids.append(app.bundleID)
        }

        // Other apps
        for app in filteredOtherApps {
            ids.append(app.bundleID)
        }

        return ids
    }

    private func selectHighlightedItem() {
        if isAllAppsHighlighted {
            onSelectApp(nil)
        } else if let bundleID = highlightedItemID {
            onSelectApp(bundleID)
        }
        if !allowMultiSelect {
            onDismiss?()
        }
    }

    private func moveHighlight(by offset: Int) {
        let ids = selectableBundleIDs
        guard !ids.isEmpty else { return }

        // Find current index
        let currentIndex: Int
        if isAllAppsHighlighted {
            currentIndex = ids.firstIndex(where: { $0 == nil }) ?? 0
        } else if let bundleID = highlightedItemID {
            currentIndex = ids.firstIndex(where: { $0 == bundleID }) ?? 0
        } else {
            currentIndex = 0
        }

        // Calculate new index
        let newIndex = max(0, min(ids.count - 1, currentIndex + offset))
        let newID = ids[newIndex]

        if newID == nil {
            isAllAppsHighlighted = true
            highlightedItemID = nil
        } else {
            isAllAppsHighlighted = false
            highlightedItemID = newID
        }
    }

    /// Check if a specific app is keyboard-highlighted
    private func isAppHighlighted(_ bundleID: String) -> Bool {
        !isAllAppsHighlighted && highlightedItemID == bundleID
    }

    /// Reset highlight to first item
    private func resetHighlightToFirst() {
        let ids = selectableBundleIDs
        if let first = ids.first {
            if first == nil {
                isAllAppsHighlighted = true
                highlightedItemID = nil
            } else {
                isAllAppsHighlighted = false
                highlightedItemID = first
            }
        }
    }

    public var body: some View {
        FilterPopoverContainer {
            // Search field
            FilterSearchField(text: $searchText, placeholder: "Search apps...", isFocused: $isSearchFocused)

            // Include/Exclude toggle (only shown if filter mode change is supported)
            if hasFilterModeSupport {
                Divider()

                HStack(spacing: 0) {
                    FilterModeButton(
                        title: "Include",
                        icon: "checkmark.circle",
                        isSelected: filterMode == .include
                    ) {
                        onFilterModeChange?(.include)
                    }

                    FilterModeButton(
                        title: "Exclude",
                        icon: "minus.circle",
                        isSelected: filterMode == .exclude
                    ) {
                        onFilterModeChange?(.exclude)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Divider()

            // App list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // "All Apps" option (only in include mode and when not searching)
                        if filterMode == .include && searchText.isEmpty {
                            FilterRow(
                                systemIcon: "square.grid.2x2.fill",
                                title: "All Apps",
                                isSelected: isAllAppsSelected,
                                isKeyboardHighlighted: isAllAppsHighlighted
                            ) {
                                onSelectApp(nil)
                                if !allowMultiSelect {
                                    onDismiss?()
                                }
                            }
                            .id("all-apps")

                            Divider()
                                .padding(.vertical, 4)
                        } else if filterMode == .exclude {
                            // In exclude mode, show a hint
                            Text("Select apps to hide")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }

                        // Installed apps
                        ForEach(filteredApps, id: \.bundleID) { app in
                            FilterRow(
                                nsImage: AppIconProvider.shared.icon(for: app.bundleID),
                                title: app.name,
                                isSelected: selectedApps?.contains(app.bundleID) ?? false,
                                isKeyboardHighlighted: isAppHighlighted(app.bundleID)
                            ) {
                                onSelectApp(app.bundleID)
                                if !allowMultiSelect {
                                    onDismiss?()
                                }
                            }
                            .id(app.bundleID)
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
                                    isSelected: selectedApps?.contains(app.bundleID) ?? false,
                                    isKeyboardHighlighted: isAppHighlighted(app.bundleID)
                                ) {
                                    onSelectApp(app.bundleID)
                                    if !allowMultiSelect {
                                        onDismiss?()
                                    }
                                }
                                .id(app.bundleID)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 240)
                .onChange(of: highlightedItemID) { newID in
                    // Scroll to highlighted item
                    if isAllAppsHighlighted {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("all-apps", anchor: .center)
                        }
                    } else if let bundleID = newID {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(bundleID, anchor: .center)
                        }
                    }
                }
                .onChange(of: isAllAppsHighlighted) { highlighted in
                    if highlighted {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("all-apps", anchor: .center)
                        }
                    }
                }
            }
        }
        .onAppear {
            // Capture initial selection state for stable sorting
            initialSelectedApps = selectedApps ?? []

            // Autofocus the search field when popover appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
            // Initialize highlight to first item
            resetHighlightToFirst()
        }
        .onChange(of: searchText) { _ in
            // Reset highlight to first item when search changes
            resetHighlightToFirst()
        }
        .keyboardNavigation(
            onUpArrow: { moveHighlight(by: -1) },
            onDownArrow: { moveHighlight(by: 1) },
            onReturn: { selectHighlightedItem() }
        )
    }
}

// MARK: - Filter Mode Button

/// Toggle button for Include/Exclude filter mode
private struct FilterModeButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? RetraceMenuStyle.actionBlue : (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
            .foregroundColor(isSelected ? .white : RetraceMenuStyle.textColorMuted)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Tags Filter Popover (Reusable)

/// Reusable tags filter popover
public struct TagsFilterPopover: View {
    let tags: [Tag]
    let selectedTags: Set<Int64>?
    let filterMode: TagFilterMode
    let allowMultiSelect: Bool
    let onSelectTag: (TagID?) -> Void
    let onFilterModeChange: ((TagFilterMode) -> Void)?
    var onDismiss: (() -> Void)?

    @State private var searchText = ""
    /// Highlighted tag ID: nil can mean "All Tags" or no selection
    @State private var highlightedTagID: Int64? = nil
    /// Special flag to indicate "All Tags" is highlighted
    @State private var isAllTagsHighlighted: Bool = true
    @FocusState private var isSearchFocused: Bool

    /// Cached initial selection state - used for sorting so list doesn't re-order while open
    @State private var initialSelectedTags: Set<Int64> = []

    public init(
        tags: [Tag],
        selectedTags: Set<Int64>?,
        filterMode: TagFilterMode = .include,
        allowMultiSelect: Bool = false,
        onSelectTag: @escaping (TagID?) -> Void,
        onFilterModeChange: ((TagFilterMode) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.tags = tags
        self.selectedTags = selectedTags
        self.filterMode = filterMode
        self.allowMultiSelect = allowMultiSelect
        self.onSelectTag = onSelectTag
        self.onFilterModeChange = onFilterModeChange
        self.onDismiss = onDismiss
    }

    private var visibleTags: [Tag] {
        tags.filter { !$0.isHidden }
    }

    private var filteredTags: [Tag] {
        let baseTags: [Tag]
        if searchText.isEmpty {
            baseTags = visibleTags
        } else {
            baseTags = visibleTags.filter { tag in
                tag.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        // Sort using INITIAL selection state so list doesn't jump while navigating
        return baseTags.sorted { tag1, tag2 in
            let tag1Selected = initialSelectedTags.contains(tag1.id.value)
            let tag2Selected = initialSelectedTags.contains(tag2.id.value)
            if tag1Selected != tag2Selected {
                return tag1Selected
            }
            return tag1.name.localizedCaseInsensitiveCompare(tag2.name) == .orderedAscending
        }
    }

    private var isAllTagsSelected: Bool {
        selectedTags == nil || selectedTags!.isEmpty
    }

    private var hasFilterModeSupport: Bool {
        onFilterModeChange != nil
    }

    /// Build a flat list of selectable tag IDs for keyboard navigation
    /// nil at the start represents "All Tags" option
    private var selectableTagIDs: [Int64?] {
        var ids: [Int64?] = []

        // "All Tags" option (only in include mode and not searching)
        if filterMode == .include && searchText.isEmpty {
            ids.append(nil)
        }

        // Tags
        for tag in filteredTags {
            ids.append(tag.id.value)
        }

        return ids
    }

    private func selectHighlightedItem() {
        if isAllTagsHighlighted {
            onSelectTag(nil)
        } else if let tagIDValue = highlightedTagID {
            // Find the tag with this ID
            if let tag = filteredTags.first(where: { $0.id.value == tagIDValue }) {
                onSelectTag(tag.id)
            }
        }
        if !allowMultiSelect {
            onDismiss?()
        }
    }

    private func moveHighlight(by offset: Int) {
        let ids = selectableTagIDs
        guard !ids.isEmpty else { return }

        // Find current index
        let currentIndex: Int
        if isAllTagsHighlighted {
            currentIndex = ids.firstIndex(where: { $0 == nil }) ?? 0
        } else if let tagID = highlightedTagID {
            currentIndex = ids.firstIndex(where: { $0 == tagID }) ?? 0
        } else {
            currentIndex = 0
        }

        // Calculate new index
        let newIndex = max(0, min(ids.count - 1, currentIndex + offset))
        let newID = ids[newIndex]

        if newID == nil {
            isAllTagsHighlighted = true
            highlightedTagID = nil
        } else {
            isAllTagsHighlighted = false
            highlightedTagID = newID
        }
    }

    /// Check if a specific tag is keyboard-highlighted
    private func isTagHighlighted(_ tagID: Int64) -> Bool {
        !isAllTagsHighlighted && highlightedTagID == tagID
    }

    /// Reset highlight to first item
    private func resetHighlightToFirst() {
        let ids = selectableTagIDs
        if let first = ids.first {
            if first == nil {
                isAllTagsHighlighted = true
                highlightedTagID = nil
            } else {
                isAllTagsHighlighted = false
                highlightedTagID = first
            }
        }
    }

    public var body: some View {
        FilterPopoverContainer(width: 220) {
            // Search field
            FilterSearchField(text: $searchText, placeholder: "Search tags...", isFocused: $isSearchFocused)

            // Include/Exclude toggle (only shown if filter mode change is supported)
            if hasFilterModeSupport {
                Divider()

                HStack(spacing: 0) {
                    FilterModeButton(
                        title: "Include",
                        icon: "checkmark.circle",
                        isSelected: filterMode == .include
                    ) {
                        onFilterModeChange?(.include)
                    }

                    FilterModeButton(
                        title: "Exclude",
                        icon: "minus.circle",
                        isSelected: filterMode == .exclude
                    ) {
                        onFilterModeChange?(.exclude)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Divider()

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
            } else if filteredTags.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("No matching tags")
                        .font(.retraceCaption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // "All Tags" option (only in include mode and when not searching)
                            if filterMode == .include && searchText.isEmpty {
                                FilterRow(
                                    systemIcon: "tag",
                                    title: "All Tags",
                                    isSelected: isAllTagsSelected,
                                    isKeyboardHighlighted: isAllTagsHighlighted
                                ) {
                                    onSelectTag(nil)
                                    if !allowMultiSelect {
                                        onDismiss?()
                                    }
                                }
                                .id("all-tags")

                                Divider()
                                    .padding(.vertical, 4)
                            } else if filterMode == .exclude && searchText.isEmpty {
                                // In exclude mode, show a hint
                                Text("Select tags to hide")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                            }

                            // Individual tags
                            ForEach(filteredTags) { tag in
                                FilterRow(
                                    systemIcon: "tag.fill",
                                    title: tag.name,
                                    isSelected: selectedTags?.contains(tag.id.value) ?? false,
                                    isKeyboardHighlighted: isTagHighlighted(tag.id.value)
                                ) {
                                    onSelectTag(tag.id)
                                    if !allowMultiSelect {
                                        onDismiss?()
                                    }
                                }
                                .id(tag.id.value)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 200)
                    .onChange(of: highlightedTagID) { newID in
                        // Scroll to highlighted item
                        if isAllTagsHighlighted {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo("all-tags", anchor: .center)
                            }
                        } else if let tagID = newID {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(tagID, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: isAllTagsHighlighted) { highlighted in
                        if highlighted {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo("all-tags", anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            // Capture initial selection state for stable sorting
            initialSelectedTags = selectedTags ?? []

            // Autofocus the search field when popover appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
            // Initialize highlight to first item
            resetHighlightToFirst()
        }
        .onChange(of: searchText) { _ in
            // Reset highlight to first item when search changes
            resetHighlightToFirst()
        }
        .keyboardNavigation(
            onUpArrow: { moveHighlight(by: -1) },
            onDownArrow: { moveHighlight(by: 1) },
            onReturn: { selectHighlightedItem() }
        )
    }
}

// MARK: - Visibility Filter Popover (Reusable)

/// Popover for selecting visibility filter (visible only, hidden only, all)
public struct VisibilityFilterPopover: View {
    let currentFilter: HiddenFilter
    let onSelect: (HiddenFilter) -> Void
    var onDismiss: (() -> Void)?

    /// Focus state to capture focus when popover appears - allows main search field to "steal" focus and dismiss
    @FocusState private var isFocused: Bool
    @State private var highlightedIndex: Int = 0

    private let options: [HiddenFilter] = [.hide, .onlyHidden, .showAll]

    public init(
        currentFilter: HiddenFilter,
        onSelect: @escaping (HiddenFilter) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.currentFilter = currentFilter
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    private func selectHighlightedItem() {
        guard highlightedIndex >= 0, highlightedIndex < options.count else { return }
        onSelect(options[highlightedIndex])
        onDismiss?()
    }

    private func moveHighlight(by offset: Int) {
        highlightedIndex = max(0, min(options.count - 1, highlightedIndex + offset))
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
                        isSelected: currentFilter == .hide,
                        isKeyboardHighlighted: highlightedIndex == 0
                    ) {
                        onSelect(.hide)
                        onDismiss?()
                    }
                    .id(0)

                    Divider()
                        .padding(.vertical, 4)

                    // Hidden Only option
                    FilterRow(
                        systemIcon: "eye.slash",
                        title: "Hidden Only",
                        subtitle: "Show only hidden segments",
                        isSelected: currentFilter == .onlyHidden,
                        isKeyboardHighlighted: highlightedIndex == 1
                    ) {
                        onSelect(.onlyHidden)
                        onDismiss?()
                    }
                    .id(1)

                    // All Segments option
                    FilterRow(
                        systemIcon: "eye.circle",
                        title: "All Segments",
                        subtitle: "Show both visible and hidden",
                        isSelected: currentFilter == .showAll,
                        isKeyboardHighlighted: highlightedIndex == 2
                    ) {
                        onSelect(.showAll)
                        onDismiss?()
                    }
                    .id(2)
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 160)
        }
        .focusable()
        .focused($isFocused)
        .modifier(FocusEffectDisabledModifier())
        .onAppear {
            // Capture focus when popover appears
            // This allows clicking elsewhere (like main search field) to dismiss by stealing focus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
            // Set initial highlight to current selection
            if let index = options.firstIndex(of: currentFilter) {
                highlightedIndex = index
            }
        }
        .onChange(of: isFocused) { focused in
            // Dismiss when focus is lost (e.g., clicking on main search field)
            if !focused {
                onDismiss?()
            }
        }
        .keyboardNavigation(
            onUpArrow: { moveHighlight(by: -1) },
            onDownArrow: { moveHighlight(by: 1) },
            onReturn: { selectHighlightedItem() }
        )
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

// MARK: - Date Range Filter Popover

/// Popover for selecting date range filter with Start/End rows, inline calendar, and quick presets
/// Matches the design from SearchFilterBar's DateFilterPopover
public struct DateRangeFilterPopover: View {
    let startDate: Date?
    let endDate: Date?
    let onApply: (Date?, Date?) -> Void
    let onClear: () -> Void
    var onDismiss: (() -> Void)?

    @State private var localStartDate: Date
    @State private var localEndDate: Date
    @State private var editingDate: EditingDate? = nil
    @State private var displayedMonth: Date = Date()

    private let calendar = Calendar.current
    private let weekdaySymbols = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    private enum EditingDate {
        case start
        case end
    }

    private enum DatePreset {
        case anytime
        case today
        case lastWeek
        case lastMonth
    }

    public init(
        startDate: Date?,
        endDate: Date?,
        onApply: @escaping (Date?, Date?) -> Void,
        onClear: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.onApply = onApply
        self.onClear = onClear
        self.onDismiss = onDismiss

        let now = Date()
        _localStartDate = State(initialValue: startDate ?? calendar.date(byAdding: .day, value: -7, to: now)!)
        _localEndDate = State(initialValue: endDate ?? now)
        _displayedMonth = State(initialValue: endDate ?? now)
    }

    public var body: some View {
        FilterPopoverContainer(width: 260) {
            // Header
            HStack {
                Text("Date Range")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if startDate != nil || endDate != nil {
                    Button("Clear") {
                        onClear()
                        onDismiss?()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
                .background(Color.white.opacity(0.1))

            // Date selection rows
            VStack(spacing: 6) {
                dateRow(label: "Start", date: localStartDate, isEditing: editingDate == .start) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        editingDate = editingDate == .start ? nil : .start
                        displayedMonth = localStartDate
                    }
                }
                dateRow(label: "End", date: localEndDate, isEditing: editingDate == .end) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        editingDate = editingDate == .end ? nil : .end
                        displayedMonth = localEndDate
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Inline calendar (shown when editing)
            if editingDate != nil {
                Divider()
                    .background(Color.white.opacity(0.1))

                inlineCalendar
                    .padding(10)
                    .contentShape(Rectangle())
                    .onTapGesture { } // Prevent tap from bubbling up
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Quick presets (horizontal chips)
            HStack(spacing: 6) {
                presetChip("All", preset: .anytime)
                presetChip("Today", preset: .today)
                presetChip("7d", preset: .lastWeek)
                presetChip("30d", preset: .lastMonth)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()
                .background(Color.white.opacity(0.1))

            // Apply button
            Button(action: applyCustomRange) {
                Text("Apply")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RetraceMenuStyle.actionBlue)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .onAppear {
            // Initialize dates from props
            let now = Date()
            localStartDate = startDate ?? calendar.date(byAdding: .day, value: -7, to: now)!
            localEndDate = endDate ?? now
            displayedMonth = localEndDate
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Collapse calendar when tapping outside of it
            if editingDate != nil {
                withAnimation(.easeOut(duration: 0.15)) {
                    editingDate = nil
                }
            }
        }
    }

    // MARK: - Date Row

    private func dateRow(label: String, date: Date, isEditing: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(isEditing ? .white.opacity(0.9) : .white.opacity(0.5))
                    .frame(width: 18)

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 32, alignment: .leading)

                Spacer()

                Text(formatDate(date))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isEditing ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isEditing ? Color.white.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Inline Calendar

    private var inlineCalendar: some View {
        VStack(spacing: 6) {
            // Month navigation
            HStack {
                Button(action: { changeMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

                Spacer()

                Text(monthYearString)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Button(action: { changeMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }

            // Weekday headers
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { day in
                    Text(day)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            }

            // Calendar grid
            let days = daysInMonth()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(days.indices, id: \.self) { index in
                    dayCell(for: days[index])
                }
            }
        }
    }

    // MARK: - Day Cell

    private func dayCell(for day: Date?) -> some View {
        Group {
            if let day = day {
                let isToday = calendar.isDateInToday(day)
                let isSelected = isDateSelected(day)
                let isCurrentMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
                let isFuture = day > Date()

                Button(action: {
                    selectDay(day)
                }) {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                        .foregroundColor(
                            isFuture
                                ? .white.opacity(0.2)
                                : (isSelected ? .white : .white.opacity(isCurrentMonth ? 0.8 : 0.3))
                        )
                        .frame(width: 26, height: 26)
                        .background(
                            ZStack {
                                if isSelected {
                                    Circle()
                                        .fill(RetraceMenuStyle.actionBlue)
                                } else if isToday {
                                    Circle()
                                        .stroke(RetraceMenuStyle.uiBlue, lineWidth: 1)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .disabled(isFuture)
                .onHover { h in
                    if !isFuture {
                        if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            } else {
                Color.clear
                    .frame(width: 26, height: 26)
            }
        }
    }

    // MARK: - Preset Chip

    private func presetChip(_ label: String, preset: DatePreset) -> some View {
        Button(action: {
            applyPreset(preset)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private func changeMonth(by value: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) {
            withAnimation(.easeInOut(duration: 0.15)) {
                displayedMonth = newMonth
            }
        }
    }

    private func daysInMonth() -> [Date?] {
        var days: [Date?] = []

        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let monthFirstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start) else {
            return days
        }

        var currentDate = monthFirstWeek.start

        for _ in 0..<42 {
            days.append(currentDate)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }

        return days
    }

    private func isDateSelected(_ day: Date) -> Bool {
        switch editingDate {
        case .start:
            return calendar.isDate(day, inSameDayAs: localStartDate)
        case .end:
            return calendar.isDate(day, inSameDayAs: localEndDate)
        case .none:
            return false
        }
    }

    private func selectDay(_ day: Date) {
        switch editingDate {
        case .start:
            localStartDate = day
            if localStartDate > localEndDate {
                localEndDate = localStartDate
            }
        case .end:
            localEndDate = day
            if localEndDate < localStartDate {
                localStartDate = localEndDate
            }
        case .none:
            break
        }

        // Close the calendar after selecting a date
        withAnimation(.easeOut(duration: 0.15)) {
            editingDate = nil
        }
    }

    private func applyCustomRange() {
        let start = calendar.startOfDay(for: localStartDate)
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: localEndDate) ?? localEndDate

        onApply(start, end)
        onDismiss?()
    }

    private func applyPreset(_ preset: DatePreset) {
        let now = Date()

        switch preset {
        case .anytime:
            onClear()
            onDismiss?()
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now)
            onApply(start, end)
            onDismiss?()
        case .lastWeek:
            if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) {
                let start = calendar.startOfDay(for: weekAgo)
                onApply(start, now)
                onDismiss?()
            }
        case .lastMonth:
            if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) {
                let start = calendar.startOfDay(for: monthAgo)
                onApply(start, now)
                onDismiss?()
            }
        }
    }
}
