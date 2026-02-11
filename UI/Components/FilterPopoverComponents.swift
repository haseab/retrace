import SwiftUI
import Shared
import AppKit
import SwiftyChrono

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
        #if DEBUG
        let _ = print("[FilterPopoverContainer] Rendering with width=\(width)")
        #endif
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
    let showAllOption: Bool
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
        showAllOption: Bool = true,
        onSelectApp: @escaping (String?) -> Void,
        onFilterModeChange: ((AppFilterMode) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.apps = apps
        self.otherApps = otherApps
        self.selectedApps = selectedApps
        self.filterMode = filterMode
        self.allowMultiSelect = allowMultiSelect
        self.showAllOption = showAllOption
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

        // "All Apps" option (only in include mode and not searching, when showAllOption is true)
        if showAllOption && filterMode == .include && searchText.isEmpty {
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
        FilterPopoverContainer(width: 220) {
            // Search field
            FilterSearchField(text: $searchText, placeholder: "Search apps...", isFocused: $isSearchFocused)
                .padding(.top, 8)
                .padding(.bottom, 4)

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
                        // "All Apps" option (only in include mode, when not searching, and when showAllOption is true)
                        if showAllOption && filterMode == .include && searchText.isEmpty {
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
                .frame(maxHeight: 200)
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
    let showAllOption: Bool
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
        showAllOption: Bool = true,
        onSelectTag: @escaping (TagID?) -> Void,
        onFilterModeChange: ((TagFilterMode) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.tags = tags
        self.selectedTags = selectedTags
        self.filterMode = filterMode
        self.allowMultiSelect = allowMultiSelect
        self.showAllOption = showAllOption
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

        // "All Tags" option (only in include mode and not searching, when showAllOption is true)
        if showAllOption && filterMode == .include && searchText.isEmpty {
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
                .padding(.top, 8)
                .padding(.bottom, 4)

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
                            // "All Tags" option (only in include mode, when not searching, and when showAllOption is true)
                            if showAllOption && filterMode == .include && searchText.isEmpty {
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

/// Popover for advanced search metadata filters (window name + browser URL)
public struct AdvancedSearchFilterPopover: View {
    @Binding var windowNameFilter: String?
    @Binding var browserUrlFilter: String?
    @FocusState private var focusedField: Field?
    @State private var isWindowHovered = false
    @State private var isBrowserHovered = false
    @State private var arrowKeyMonitor: Any?

    private enum Field: Hashable {
        case windowName
        case browserUrl
    }

    public init(
        windowNameFilter: Binding<String?>,
        browserUrlFilter: Binding<String?>
    ) {
        self._windowNameFilter = windowNameFilter
        self._browserUrlFilter = browserUrlFilter
    }

    private var hasActiveFilters: Bool {
        (windowNameFilter?.isEmpty == false) ||
        (browserUrlFilter?.isEmpty == false)
    }

    private var windowNameTextBinding: Binding<String> {
        Binding(
            get: { windowNameFilter ?? "" },
            set: { newValue in
                let normalized = newValue.isEmpty ? nil : newValue
                guard normalized != windowNameFilter else { return }
                windowNameFilter = normalized
            }
        )
    }

    private var browserUrlTextBinding: Binding<String> {
        Binding(
            get: { browserUrlFilter ?? "" },
            set: { newValue in
                let normalized = newValue.isEmpty ? nil : newValue
                guard normalized != browserUrlFilter else { return }
                browserUrlFilter = normalized
            }
        )
    }

    private func moveFocusDown() {
        if focusedField == .windowName {
            focusedField = .browserUrl
        }
    }

    private func moveFocusUp() {
        if focusedField == .browserUrl {
            focusedField = .windowName
        }
    }

    private func setupArrowKeyMonitor() {
        guard arrowKeyMonitor == nil else { return }

        arrowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ignore modified arrow commands (cmd/opt/ctrl).
            if event.modifierFlags.contains(.command) ||
                event.modifierFlags.contains(.option) ||
                event.modifierFlags.contains(.control) {
                return event
            }
            guard focusedField != nil else { return event }

            switch event.keyCode {
            case 125: // Down arrow
                moveFocusDown()
                return nil
            case 126: // Up arrow
                moveFocusUp()
                return nil
            default:
                return event
            }
        }
    }

    private func removeArrowKeyMonitor() {
        if let monitor = arrowKeyMonitor {
            NSEvent.removeMonitor(monitor)
            arrowKeyMonitor = nil
        }
    }

    public var body: some View {
        FilterPopoverContainer(width: 300) {
            HStack {
                Text("Advanced Filters")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if hasActiveFilters {
                    Button("Clear") {
                        windowNameFilter = nil
                        browserUrlFilter = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.65))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
                .background(Color.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Window Name")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    TextField("Search titles...", text: windowNameTextBinding)
                        .focused($focusedField, equals: .windowName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    focusedField == .windowName
                                        ? RetraceMenuStyle.filterStrokeStrong
                                        : (isWindowHovered
                                            ? RetraceMenuStyle.filterStrokeStrong
                                            : RetraceMenuStyle.filterStrokeSubtle),
                                    lineWidth: 1
                                )
                        )
                        .onHover { hovering in
                            isWindowHovered = hovering
                        }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Browser URL")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    TextField("Search URLs...", text: browserUrlTextBinding)
                        .focused($focusedField, equals: .browserUrl)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    focusedField == .browserUrl
                                        ? RetraceMenuStyle.filterStrokeStrong
                                        : (isBrowserHovered
                                            ? RetraceMenuStyle.filterStrokeStrong
                                            : RetraceMenuStyle.filterStrokeSubtle),
                                    lineWidth: 1
                                )
                        )
                        .onHover { hovering in
                            isBrowserHovered = hovering
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedField = .windowName
            }
            setupArrowKeyMonitor()
        }
        .onDisappear {
            removeArrowKeyMonitor()
        }
    }
}

/// Popover for selecting visibility filter (visible only, hidden only, all)
public struct VisibilityFilterPopover: View {
    let currentFilter: HiddenFilter
    let onSelect: (HiddenFilter) -> Void
    var onDismiss: (() -> Void)?
    var onKeyboardSelect: (() -> Void)?

    /// Focus state to capture focus when popover appears - allows main search field to "steal" focus and dismiss
    @FocusState private var isFocused: Bool
    @State private var highlightedIndex: Int = 0

    private let options: [HiddenFilter] = [.hide, .onlyHidden, .showAll]

    public init(
        currentFilter: HiddenFilter,
        onSelect: @escaping (HiddenFilter) -> Void,
        onDismiss: (() -> Void)? = nil,
        onKeyboardSelect: (() -> Void)? = nil
    ) {
        self.currentFilter = currentFilter
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        self.onKeyboardSelect = onKeyboardSelect
    }

    private func selectHighlightedItem() {
        guard highlightedIndex >= 0, highlightedIndex < options.count else { return }
        onSelect(options[highlightedIndex])
        if let onKeyboardSelect {
            onKeyboardSelect()
        } else {
            onDismiss?()
        }
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
        #if DEBUG
        let _ = print("[DropdownOverlay] Rendering, isPresented=\(isPresented), opensUpward=\(opensUpward), yOffset=\(yOffset)")
        #endif
        content
            .background(GeometryReader { geo in
                Color.clear.onAppear {
                    #if DEBUG
                    print("[DropdownOverlay] Anchor content frame: \(geo.frame(in: .global))")
                    #endif
                }.onChange(of: isPresented) { _ in
                    #if DEBUG
                    print("[DropdownOverlay] Anchor content frame (on change): \(geo.frame(in: .global))")
                    #endif
                }
            })
            .overlay(alignment: opensUpward ? .bottomLeading : .topLeading) {
                if isPresented {
                    #if DEBUG
                    let _ = print("[DropdownOverlay] Showing dropdown content with zIndex=1000")
                    #endif
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
                            #if DEBUG
                            print("[DropdownOverlay] Dropdown content frame: \(geo.frame(in: .global))")
                            #endif
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

/// Popover for selecting date range filter with natural-language input and a single range calendar
public struct DateRangeFilterPopover: View {
    let startDate: Date?
    let endDate: Date?
    let onApply: (Date?, Date?) -> Void
    let onClear: () -> Void
    let width: CGFloat
    let enableKeyboardNavigation: Bool
    let onMoveToNextFilter: (() -> Void)?
    let onCalendarEditingChange: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?

    @State private var localStartDate: Date
    @State private var localEndDate: Date
    @State private var rangeInputText: String = ""
    @State private var parseError: String?
    @State private var isCalendarVisible = false
    @State private var activeCalendarBoundary: CalendarBoundary = .start
    @State private var displayedMonth: Date = Date()
    @State private var focusedItem: Int = 0
    @State private var lastFocusBeforeApply: Int?
    @State private var keyboardMonitor: Any?
    @FocusState private var isRangeInputFocused: Bool

    private let calendar = Calendar.current
    private let weekdaySymbols = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
    private let itemCount = 6

    private enum CalendarBoundary {
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
        width: CGFloat = 300,
        enableKeyboardNavigation: Bool = false,
        onMoveToNextFilter: (() -> Void)? = nil,
        onCalendarEditingChange: ((Bool) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.onApply = onApply
        self.onClear = onClear
        self.width = width
        self.enableKeyboardNavigation = enableKeyboardNavigation
        self.onMoveToNextFilter = onMoveToNextFilter
        self.onCalendarEditingChange = onCalendarEditingChange
        self.onDismiss = onDismiss

        let now = Date()
        _localStartDate = State(initialValue: startDate ?? calendar.date(byAdding: .day, value: -7, to: now)!)
        _localEndDate = State(initialValue: endDate ?? now)
        _displayedMonth = State(initialValue: endDate ?? now)
    }

    public var body: some View {
        FilterPopoverContainer(width: width) {
            // Header
            HStack {
                Text("Date Range")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if startDate != nil || endDate != nil {
                    Button("Clear") {
                        rangeInputText = ""
                        parseError = nil
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

            // Natural language range input
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))

                    TextField("e.g. dec 5 to 8 | last week to now", text: $rangeInputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white)
                        .focused($isRangeInputFocused)
                        .modifier(FocusEffectDisabledModifier())
                        .onChange(of: isRangeInputFocused) { isFocused in
                            if isFocused {
                                focusedItem = -1  // Clear keyboard navigation highlight when text field is focused
                            }
                        }
                        .onSubmit {
                            applyCurrentSelection(moveToNextDropdown: true)
                        }
                        .onChange(of: rangeInputText) { _ in
                            parseError = nil
                        }

                    if !rangeInputText.isEmpty {
                        Button(action: {
                            rangeInputText = ""
                            parseError = nil
                            onClear()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRangeInputFocused ? RetraceMenuStyle.filterStrokeMedium : Color.clear, lineWidth: 1)
                )

                if let parseError {
                    Text(parseError)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange.opacity(0.9))
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
                .background(Color.white.opacity(0.1))

            // Calendar range toggle and hint
            Button(action: {
                withAnimation(.easeOut(duration: 0.15)) {
                    isCalendarVisible.toggle()
                    if isCalendarVisible {
                        displayedMonth = localEndDate
                        activeCalendarBoundary = .start
                        isRangeInputFocused = false
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Text(isCalendarVisible ? "Hide Calendar" : "Browse Calendar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)

                    Spacer()

                    if isCalendarVisible {
                        Text(activeCalendarBoundary == .start ? "Pick start" : "Pick end")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(enableKeyboardNavigation && focusedItem == 0 ? Color.white.opacity(0.16) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            enableKeyboardNavigation && focusedItem == 0
                                ? RetraceMenuStyle.filterStrokeMedium
                                : Color.clear,
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            if isCalendarVisible {
                inlineCalendar
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Quick presets (horizontal chips)
            HStack(spacing: 6) {
                presetChip("All", preset: .anytime, isHighlighted: enableKeyboardNavigation && focusedItem == 1)
                presetChip("Today", preset: .today, isHighlighted: enableKeyboardNavigation && focusedItem == 2)
                presetChip("7d", preset: .lastWeek, isHighlighted: enableKeyboardNavigation && focusedItem == 3)
                presetChip("30d", preset: .lastMonth, isHighlighted: enableKeyboardNavigation && focusedItem == 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // Apply button
            Button(action: {
                applyCurrentSelection(moveToNextDropdown: false)
            }) {
                Text("Apply")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(enableKeyboardNavigation && focusedItem == 5 ? RetraceMenuStyle.actionBlue : RetraceMenuStyle.actionBlue.opacity(0.85))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                enableKeyboardNavigation && focusedItem == 5 ? Color.white.opacity(0.35) : Color.clear,
                                lineWidth: 1.5
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .onAppear {
            configureInitialState()

            if enableKeyboardNavigation {
                setupKeyboardMonitor()
            }

            DispatchQueue.main.async {
                isRangeInputFocused = true
            }
        }
        .onDisappear {
            if enableKeyboardNavigation {
                removeKeyboardMonitor()
            }
            onCalendarEditingChange?(false)
        }
        .onChange(of: isCalendarVisible) { isVisible in
            onCalendarEditingChange?(isVisible)
        }
    }

    // MARK: - Inline Calendar

    private var inlineCalendar: some View {
        VStack(spacing: 6) {
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

            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { day in
                    Text(day)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            }

            let days = daysInMonth()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
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
                let normalizedDay = calendar.startOfDay(for: day)
                let isToday = calendar.isDateInToday(normalizedDay)
                let isStart = calendar.isDate(normalizedDay, inSameDayAs: localStartDate)
                let isEnd = calendar.isDate(normalizedDay, inSameDayAs: localEndDate)
                let isInRange = isDateInRange(normalizedDay)
                let isCurrentMonth = calendar.isDate(normalizedDay, equalTo: displayedMonth, toGranularity: .month)
                let isFuture = normalizedDay > calendar.startOfDay(for: Date())

                ZStack(alignment: .center) {
                    // Background connection bar for range
                    if isInRange {
                        HStack(spacing: 0) {
                            // Left half - only show if not the start date
                            Rectangle()
                                .fill(isStart ? Color.clear : RetraceMenuStyle.actionBlue.opacity(0.28))
                                .frame(maxWidth: .infinity, maxHeight: 26)

                            // Right half - only show if not the end date
                            Rectangle()
                                .fill(isEnd ? Color.clear : RetraceMenuStyle.actionBlue.opacity(0.28))
                                .frame(maxWidth: .infinity, maxHeight: 26)
                        }
                    }

                    // Day number button
                    Button(action: {
                        selectDay(normalizedDay)
                    }) {
                        Text("\(calendar.component(.day, from: normalizedDay))")
                            .font(.system(size: 11, weight: (isToday || isStart || isEnd) ? .semibold : .regular))
                            .foregroundColor(
                                isFuture
                                    ? .white.opacity(0.2)
                                    : ((isStart || isEnd)
                                       ? .white
                                       : .white.opacity(isCurrentMonth ? 0.82 : 0.35))
                            )
                            .frame(width: 26, height: 26)
                            .background(
                                ZStack {
                                    if isStart || isEnd {
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
                    .onHover { hovering in
                        if !isFuture {
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Color.clear
                    .frame(width: 26, height: 26)
            }
        }
    }

    // MARK: - Preset Chip

    private func presetChip(_ label: String, preset: DatePreset, isHighlighted: Bool = false) -> some View {
        Button(action: {
            applyPreset(preset)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHighlighted ? .white : .white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHighlighted ? Color.white.opacity(0.2) : Color.white.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isHighlighted ? RetraceMenuStyle.filterStrokeMedium : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Helpers

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private func configureInitialState() {
        let now = Date()
        let fallbackStart = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        localStartDate = calendar.startOfDay(for: startDate ?? fallbackStart)
        localEndDate = calendar.startOfDay(for: endDate ?? now)

        if localEndDate < localStartDate {
            swap(&localStartDate, &localEndDate)
        }

        displayedMonth = localEndDate
        activeCalendarBoundary = .start
        isCalendarVisible = false
        parseError = nil

        if startDate != nil || endDate != nil {
            rangeInputText = formatRangeInput(start: localStartDate, end: localEndDate)
        } else {
            rangeInputText = ""
        }
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

    private func isDateInRange(_ day: Date) -> Bool {
        let normalizedStart = calendar.startOfDay(for: localStartDate)
        let normalizedEnd = calendar.startOfDay(for: localEndDate)
        return day >= normalizedStart && day <= normalizedEnd
    }

    private func selectDay(_ day: Date) {
        if activeCalendarBoundary == .start {
            localStartDate = day
            localEndDate = day
            activeCalendarBoundary = .end
        } else {
            if day < localStartDate {
                localEndDate = localStartDate
                localStartDate = day
            } else {
                localEndDate = day
            }
            activeCalendarBoundary = .start
        }

        rangeInputText = formatRangeInput(start: localStartDate, end: localEndDate)
        parseError = nil
    }

    @discardableResult
    private func applyInputTextToLocalRange(applyImmediately: Bool) -> Bool {
        let trimmed = rangeInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parseError = "Enter a range like \"Dec 5 to 8\"."
            return false
        }

        guard let parsedRange = parseDateRangeInput(trimmed) else {
            parseError = "Couldn’t parse that date range."
            return false
        }

        localStartDate = parsedRange.start
        localEndDate = parsedRange.end
        displayedMonth = parsedRange.end
        rangeInputText = formatRangeInput(start: parsedRange.start, end: parsedRange.end)
        parseError = nil
        activeCalendarBoundary = .start

        if applyImmediately {
            applyCustomRange(moveToNextDropdown: false)
        }

        return true
    }

    private func applyCurrentSelection(moveToNextDropdown: Bool = false) {
        let trimmed = rangeInputText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            onClear()
            onDismiss?()
            if moveToNextDropdown {
                onMoveToNextFilter?()
            }
            return
        }

        guard applyInputTextToLocalRange(applyImmediately: false) else {
            if moveToNextDropdown {
                onDismiss?()
                onMoveToNextFilter?()
            }
            return
        }
        applyCustomRange(moveToNextDropdown: moveToNextDropdown)
    }

    private func applyCustomRange(moveToNextDropdown: Bool = false) {
        let start = calendar.startOfDay(for: localStartDate)

        // Set end date to 23:59:59.999 to include the entire day
        // Use bySettingHour to preserve the date's timezone instead of reconstructing with components
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: localEndDate) ?? localEndDate

        // Log the final search range
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy HH:mm:ss"
        formatter.timeZone = TimeZone.current
        Log.debug("[DateParse] ⏰ SEARCH RANGE (local time): \(formatter.string(from: start)) to \(formatter.string(from: end))", category: .ui)

        onApply(start, end)
        onDismiss?()

        if moveToNextDropdown {
            onMoveToNextFilter?()
        }
    }

    private func applyPreset(_ preset: DatePreset) {
        let now = Date()
        switch preset {
        case .anytime:
            rangeInputText = ""
            parseError = nil
            onClear()
            onDismiss?()

        case .today:
            let today = calendar.startOfDay(for: now)
            localStartDate = today
            localEndDate = today
            rangeInputText = formatRangeInput(start: localStartDate, end: localEndDate)
            parseError = nil
            applyCustomRange()

        case .lastWeek:
            if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) {
                localStartDate = calendar.startOfDay(for: weekAgo)
                localEndDate = calendar.startOfDay(for: now)
                rangeInputText = formatRangeInput(start: localStartDate, end: localEndDate)
                parseError = nil
                applyCustomRange()
            }

        case .lastMonth:
            if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) {
                localStartDate = calendar.startOfDay(for: monthAgo)
                localEndDate = calendar.startOfDay(for: now)
                rangeInputText = formatRangeInput(start: localStartDate, end: localEndDate)
                parseError = nil
                applyCustomRange()
            }
        }
    }

    private func formatRangeInput(start: Date, end: Date) -> String {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        let startFormatter = DateFormatter()
        startFormatter.dateFormat = "MMM d"

        let dayOnlyFormatter = DateFormatter()
        dayOnlyFormatter.dateFormat = "d"

        if calendar.isDate(startDay, equalTo: endDay, toGranularity: .month) &&
            calendar.isDate(startDay, equalTo: endDay, toGranularity: .year) {
            if calendar.isDate(startDay, inSameDayAs: endDay) {
                return startFormatter.string(from: startDay)
            }
            return "\(startFormatter.string(from: startDay)) to \(dayOnlyFormatter.string(from: endDay))"
        }

        return "\(startFormatter.string(from: startDay)) to \(startFormatter.string(from: endDay))"
    }

    private func parseDateRangeInput(_ text: String) -> (start: Date, end: Date)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let detectedRange = parseRangeWithDetector(trimmed) {
            let normalized = normalizeRange(detectedRange.start, detectedRange.end)
            return normalized
        }

        if let split = splitRangeText(trimmed),
           let start = parseSingleDate(split.start, relativeTo: nil),
           let end = parseSingleDate(split.end, relativeTo: start) {
            let normalized = normalizeRange(start, end)
            return normalized
        }

        if let single = parseSingleDate(trimmed, relativeTo: nil) {
            let day = calendar.startOfDay(for: single)
            return (day, day)
        }

        return nil
    }

    private func parseRangeWithDetector(_ text: String) -> (start: Date, end: Date)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        guard let first = matches.first, let firstDate = first.date else {
            return nil
        }

        if first.duration > 0 {
            let rawEnd = firstDate.addingTimeInterval(first.duration)
            return (firstDate, rawEnd)
        }

        if matches.count >= 2, let secondDate = matches[1].date {
            return (firstDate, secondDate)
        }

        return nil
    }

    private func splitRangeText(_ text: String) -> (start: String, end: String)? {
        let connectors = [" to ", " through ", " thru ", " until ", " - ", " – ", " — "]

        for connector in connectors {
            if let connectorRange = text.range(of: connector, options: .caseInsensitive) {
                let left = text[..<connectorRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let right = text[connectorRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty, !right.isEmpty {
                    return (String(left), String(right))
                }
            }
        }

        return nil
    }

    private func parseSingleDate(_ text: String, relativeTo referenceDate: Date?) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLower = trimmed.lowercased()
        let now = Date()

        // === PRIMARY: SwiftyChrono NLP Parser ===
        // Use reference date if provided for context-aware parsing
        // forwardDate: 0 disables the "prefer future dates" behavior, perfect for a history search app
        let chrono = Chrono()
        let results = chrono.parse(text: trimmed, refDate: referenceDate ?? now, opt: [.forwardDate: 0])
        if let result = results.first?.start.date {
            return result
        }

        // === FALLBACK: Special cases ===

        // Handle numeric day in context of reference date (e.g., "5 to 8" where "8" should be in same month)
        if let referenceDate, let day = Int(trimmedLower), (1...31).contains(day) {
            var referenceComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            let referenceDay = referenceComponents.day
            referenceComponents.day = day

            if let candidate = calendar.date(from: referenceComponents) {
                if let referenceDay = calendar.dateComponents([.day], from: referenceDate).day,
                   day < referenceDay,
                   let nextMonth = calendar.date(byAdding: .month, value: 1, to: referenceDate) {
                    var nextMonthComponents = calendar.dateComponents([.year, .month], from: nextMonth)
                    nextMonthComponents.day = day
                    let result = calendar.date(from: nextMonthComponents) ?? candidate
                    return result
                }
                return candidate
            }
        }

        // Time-only parsing
        if let timeOnlyDate = parseTimeOnly(trimmedLower, relativeTo: now) {
            return timeOnlyDate
        }

        // NSDataDetector as final fallback
        let normalizedText = normalizeCompactTimeFormat(trimmedLower)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(normalizedText.startIndex..., in: normalizedText)
            if let match = detector.firstMatch(in: normalizedText, options: [], range: range),
               let date = match.date {
                return date
            }
        }

        let formatStrings = [
            "MMM d yyyy h:mm a",
            "MMM d yyyy h:mma",
            "MMM d yyyy ha",
            "MMM d h:mm a",
            "MMM d h:mma",
            "MMM d ha",
            "MMM d h a",
            "MM/dd/yyyy h:mm a",
            "MM/dd h:mm a",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss",
            "MMM d",
            "MMMM d"
        ]

        for formatString in formatStrings {
            let formatter = DateFormatter()
            formatter.dateFormat = formatString
            formatter.timeZone = .current
            formatter.defaultDate = referenceDate ?? now

            if let date = formatter.date(from: text) { return date }
            if let date = formatter.date(from: trimmed) { return date }

            let capitalized = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
            if let date = formatter.date(from: capitalized) { return date }
        }

        return nil
    }

    private func parseTimeOnly(_ text: String, relativeTo now: Date) -> Date? {
        var input = text.trimmingCharacters(in: .whitespaces)
        var isPM = false
        var isAM = false

        if input.hasSuffix("pm") || input.hasSuffix("p") {
            isPM = true
            input = input.replacingOccurrences(of: "pm", with: "")
                .replacingOccurrences(of: "p", with: "")
                .trimmingCharacters(in: .whitespaces)
        } else if input.hasSuffix("am") || input.hasSuffix("a") {
            isAM = true
            input = input.replacingOccurrences(of: "am", with: "")
                .replacingOccurrences(of: "a", with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        var hour: Int?
        var minute = 0

        if input.contains(":") {
            let parts = input.split(separator: ":")
            if parts.count == 2,
               let h = Int(parts[0]),
               let m = Int(parts[1]),
               h >= 0 && h <= 23 && m >= 0 && m <= 59 {
                hour = h
                minute = m
            }
        } else if let numericValue = Int(input) {
            if numericValue >= 0 && numericValue <= 23 {
                hour = numericValue
            } else if numericValue >= 100 && numericValue <= 2359 {
                hour = numericValue / 100
                minute = numericValue % 100
                if hour! > 23 || minute > 59 {
                    return nil
                }
            } else {
                return nil
            }
        }

        guard var finalHour = hour else { return nil }

        if isPM && finalHour < 12 {
            finalHour += 12
        } else if isAM && finalHour == 12 {
            finalHour = 0
        }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = finalHour
        components.minute = minute
        components.second = 0

        return calendar.date(from: components)
    }

    private func normalizeCompactTimeFormat(_ text: String) -> String {
        let pattern = #"(\d{3,4})\s*(am|pm)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }

        var result = text
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches.reversed() {
            guard let numberRange = Range(match.range(at: 1), in: result),
                  let suffixRange = Range(match.range(at: 2), in: result),
                  let fullMatchRange = Range(match.range, in: result) else {
                continue
            }

            let numberStr = String(result[numberRange])
            let suffix = String(result[suffixRange])
            guard let numericValue = Int(numberStr) else { continue }

            let hour: Int
            let minute: Int
            if numericValue >= 100 && numericValue <= 1259 {
                hour = numericValue / 100
                minute = numericValue % 100
            } else {
                continue
            }

            guard hour >= 1 && hour <= 12 && minute >= 0 && minute <= 59 else {
                continue
            }

            let normalizedTime = "\(hour):\(String(format: "%02d", minute))\(suffix)"
            result.replaceSubrange(fullMatchRange, with: normalizedTime)
        }

        return result
    }

    private func extractNumber(from text: String) -> Int? {
        let pattern = "\\d+"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return Int(text[range])
        }
        return nil
    }

    private func normalizeRange(_ start: Date, _ end: Date) -> (start: Date, end: Date) {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        return startDay <= endDay ? (startDay, endDay) : (endDay, startDay)
    }

    // MARK: - Keyboard Navigation

    private func setupKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            switch event.keyCode {
            case 53: // Escape
                // Close calendar first, then dismiss the dropdown on the next Escape.
                if isCalendarVisible {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isCalendarVisible = false
                        activeCalendarBoundary = .start
                    }
                    return nil
                }
                if parseError != nil {
                    parseError = nil
                    return nil
                }
                // Changes are already applied on demand via onChange, so just dismiss
                if let onDismiss {
                    onDismiss()
                } else {
                    withAnimation(.easeOut(duration: 0.15)) {
                        activeCalendarBoundary = .start
                    }
                }
                return nil

            case 36, 76: // Return/Enter
                if isRangeInputFocused {
                    // Match Tab behavior: apply/clear from input, then advance to next filter.
                    applyCurrentSelection(moveToNextDropdown: true)
                    return nil
                }

                if isCalendarVisible {
                    if activeCalendarBoundary == .start {
                        activeCalendarBoundary = .end
                    } else {
                        activeCalendarBoundary = .start
                    }
                    return nil
                }

                activateFocusedItem()
                return nil

            case 126: // Up arrow
                if isRangeInputFocused {
                    withAnimation(.easeOut(duration: 0.1)) {
                        focusedItem = 0
                    }
                    isRangeInputFocused = false
                    return nil
                }
                if isCalendarVisible {
                    navigateCalendar(byDays: -7)
                } else {
                    moveFocusWithArrow(126)
                }
                return nil

            case 125: // Down arrow
                if isRangeInputFocused {
                    withAnimation(.easeOut(duration: 0.1)) {
                        focusedItem = 0
                    }
                    isRangeInputFocused = false
                    return nil
                }
                if isCalendarVisible {
                    navigateCalendar(byDays: 7)
                } else {
                    moveFocusWithArrow(125)
                }
                return nil

            case 123: // Left arrow
                if isRangeInputFocused && !isCalendarVisible { return event }
                if isCalendarVisible {
                    navigateCalendar(byDays: -1)
                } else {
                    moveFocusWithArrow(123)
                }
                return nil

            case 124: // Right arrow
                if isRangeInputFocused && !isCalendarVisible { return event }
                if isCalendarVisible {
                    navigateCalendar(byDays: 1)
                } else {
                    moveFocusWithArrow(124)
                }
                return nil

            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }

    private func activateFocusedItem() {
        switch focusedItem {
        case 0:
            withAnimation(.easeOut(duration: 0.15)) {
                isCalendarVisible.toggle()
                if isCalendarVisible {
                    displayedMonth = localEndDate
                    activeCalendarBoundary = .start
                }
            }
        case 1: applyPreset(.anytime)
        case 2: applyPreset(.today)
        case 3: applyPreset(.lastWeek)
        case 4: applyPreset(.lastMonth)
        case 5: applyCurrentSelection(moveToNextDropdown: false)
        default: break
        }
    }

    private func moveFocusedItem(by offset: Int) {
        withAnimation(.easeOut(duration: 0.1)) {
            focusedItem = max(0, min(itemCount - 1, focusedItem + offset))
            isRangeInputFocused = false
        }
    }

    private func moveFocusWithArrow(_ keyCode: UInt16) {
        withAnimation(.easeOut(duration: 0.1)) {
            switch keyCode {
            case 123: // Left
                if (1...4).contains(focusedItem) {
                    focusedItem = max(1, focusedItem - 1)
                } else if focusedItem == 5 {
                    // Apply button - move up to presets
                    focusedItem = 4
                } else {
                    moveFocusedItem(by: -1)
                }

            case 124: // Right
                if (1...4).contains(focusedItem) {
                    focusedItem = min(4, focusedItem + 1)
                } else if focusedItem == 0 {
                    focusedItem = 1
                } else if focusedItem == 5 {
                    // Apply button - move up to presets
                    focusedItem = 1
                } else {
                    moveFocusedItem(by: 1)
                }

            case 125: // Down
                if focusedItem == 0 {
                    focusedItem = 1
                } else if (1...4).contains(focusedItem) {
                    focusedItem = 5
                } else {
                    moveFocusedItem(by: 1)
                }

            case 126: // Up
                if focusedItem == 0 {
                    isRangeInputFocused = true
                    return
                } else if (1...4).contains(focusedItem) {
                    focusedItem = 0
                } else if focusedItem == 5 {
                    // Apply button - move up to presets
                    focusedItem = 4
                } else {
                    moveFocusedItem(by: -1)
                }

            default:
                break
            }

            isRangeInputFocused = false
        }
    }

    private func navigateCalendar(byDays days: Int) {
        let currentDate = activeCalendarBoundary == .start ? localStartDate : localEndDate
        guard let newDate = calendar.date(byAdding: .day, value: days, to: currentDate) else { return }
        let normalizedDate = calendar.startOfDay(for: newDate)
        guard normalizedDate <= calendar.startOfDay(for: Date()) else { return }

        if activeCalendarBoundary == .start {
            localStartDate = normalizedDate
            if localStartDate > localEndDate {
                localEndDate = localStartDate
            }
        } else {
            localEndDate = normalizedDate
            if localEndDate < localStartDate {
                localStartDate = localEndDate
            }
        }

        rangeInputText = formatRangeInput(start: localStartDate, end: localEndDate)
        parseError = nil

        if !calendar.isDate(normalizedDate, equalTo: displayedMonth, toGranularity: .month) {
            withAnimation(.easeInOut(duration: 0.15)) {
                displayedMonth = normalizedDate
            }
        }
    }
}
