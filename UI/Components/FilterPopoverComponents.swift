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
    let appIconBundleID: String?
    let iconColorOverride: Color?
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let isKeyboardHighlighted: Bool
    let action: () -> Void

    @State private var isHovered = false

    public init(
        icon: Image? = nil,
        appIconBundleID: String? = nil,
        iconColorOverride: Color? = nil,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        isKeyboardHighlighted: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.appIconBundleID = appIconBundleID
        self.iconColorOverride = iconColorOverride
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.isKeyboardHighlighted = isKeyboardHighlighted
        self.action = action
    }

    /// Convenience initializer for SF Symbol icons
    public init(
        systemIcon: String,
        iconColorOverride: Color? = nil,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        isKeyboardHighlighted: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = Image(systemName: systemIcon)
        self.appIconBundleID = nil
        self.iconColorOverride = iconColorOverride
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.isKeyboardHighlighted = isKeyboardHighlighted
        self.action = action
    }

    /// Convenience initializer for NSImage icons (app icons)
    public init(
        nsImage: NSImage?,
        iconColorOverride: Color? = nil,
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
        self.appIconBundleID = nil
        self.iconColorOverride = iconColorOverride
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.isKeyboardHighlighted = isKeyboardHighlighted
        self.action = action
    }

    public init(
        appIconBundleID: String,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        isKeyboardHighlighted: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = nil
        self.appIconBundleID = appIconBundleID
        self.iconColorOverride = nil
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
                if let appIconBundleID {
                    AppIconView(bundleID: appIconBundleID, size: RetraceMenuStyle.iconFrameWidth)
                        .frame(
                            width: RetraceMenuStyle.iconFrameWidth,
                            height: RetraceMenuStyle.iconFrameWidth
                        )
                } else if let icon = icon {
                    icon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: RetraceMenuStyle.iconFrameWidth)
                        .foregroundColor(iconColorOverride ?? (shouldHighlight ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted))
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
        VStack(spacing: 0) {
            content
        }
        .frame(width: width)
        .retraceMenuContainer(addPadding: false)
    }
}

enum DropdownOverlayInteraction {
    static func clickPointInScreen(for event: NSEvent) -> CGPoint? {
        guard let window = event.window ?? NSApp.window(withWindowNumber: event.windowNumber) else {
            return nil
        }

        return window.convertPoint(toScreen: event.locationInWindow)
    }

    static func isUsableFrame(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0
    }

    static func shouldDismiss(
        event: NSEvent,
        triggerFrame: CGRect,
        contentFrame: CGRect
    ) -> Bool {
        guard isUsableFrame(triggerFrame) || isUsableFrame(contentFrame) else {
            return false
        }
        guard let clickPoint = clickPointInScreen(for: event) else {
            return false
        }

        return !triggerFrame.contains(clickPoint) && !contentFrame.contains(clickPoint)
    }
}

// MARK: - Filter Search Field

/// Search field for filter popovers
public struct FilterSearchField: View {
    @Binding var text: String
    let placeholder: String
    var isFocused: Binding<Bool>?

    public init(text: Binding<String>, placeholder: String = "Search...", isFocused: Binding<Bool>? = nil) {
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
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused?.wrappedValue = true
        }
    }

    @ViewBuilder
    private var textField: some View {
        FocusableTextInput(
            text: $text,
            placeholder: placeholder,
            isFocused: isFocused.map { binding in
                { binding.wrappedValue }
            },
            setFocused: isFocused.map { binding in
                { binding.wrappedValue = $0 }
            }
        )
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
    let isLoading: Bool
    let isLoadingOtherApps: Bool
    let onSelectApp: (String?) -> Void
    let onFilterModeChange: ((AppFilterMode) -> Void)?
    var onDismiss: (() -> Void)?

    @State private var searchText = ""
    /// Highlighted item ID: nil means "All Apps", otherwise it's the bundleID
    @State private var highlightedItemID: String? = nil
    /// Special flag to indicate "All Apps" is highlighted (since nil bundleID is ambiguous)
    @State private var isAllAppsHighlighted: Bool = true
    @State private var isSearchFieldFocused = false

    /// Cached initial selection state - used for sorting so list doesn't re-order while open
    @State private var initialSelectedApps: Set<String> = []

    public init(
        apps: [(bundleID: String, name: String)],
        otherApps: [(bundleID: String, name: String)] = [],
        selectedApps: Set<String>?,
        filterMode: AppFilterMode = .include,
        allowMultiSelect: Bool = false,
        showAllOption: Bool = true,
        isLoading: Bool = false,
        isLoadingOtherApps: Bool = false,
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
        self.isLoading = isLoading
        self.isLoadingOtherApps = isLoadingOtherApps
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

    private var prefetchedInstalledAppBundleIDs: [String] {
        Array(filteredApps.prefix(24)).map(\.bundleID)
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
            FilterSearchField(text: $searchText, placeholder: "Search apps...", isFocused: $isSearchFieldFocused)
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
                        if filteredApps.isEmpty && filteredOtherApps.isEmpty && isLoading {
                            VStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading apps…")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }

                        // "All Apps" option (only in include mode, when not searching, and when showAllOption is true)
                        if !(filteredApps.isEmpty && filteredOtherApps.isEmpty && isLoading) &&
                            showAllOption && filterMode == .include && searchText.isEmpty {
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
                                appIconBundleID: app.bundleID,
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

                        if isLoadingOtherApps {
                            Divider()
                                .padding(.vertical, 8)

                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Refreshing Rewind history…")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
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
                        } else if filteredApps.isEmpty && !isLoading {
                            Text(searchText.isEmpty ? "No apps found" : "No matching apps")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 18)
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
            AppMetadataCache.shared.prefetch(bundleIDs: prefetchedInstalledAppBundleIDs)

            // Clear the previous responder first so the main overlay search field
            // does not immediately reclaim keyboard focus from the dropdown field.
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
                isSearchFieldFocused = true
            }
            // Initialize highlight to first item
            resetHighlightToFirst()
        }
        .onDisappear {
            isSearchFieldFocused = false
        }
        .onChange(of: searchText) { _ in
            // Reset highlight to first item when search changes
            resetHighlightToFirst()
        }
        .onChange(of: prefetchedInstalledAppBundleIDs) { bundleIDs in
            AppMetadataCache.shared.prefetch(bundleIDs: bundleIDs)
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
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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
    @State private var isSearchFieldFocused = false

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
            FilterSearchField(text: $searchText, placeholder: "Search tags...", isFocused: $isSearchFieldFocused)
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
                                    iconColorOverride: TagColorStore.color(for: tag),
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

            // Clear the previous responder first so the main overlay search field
            // does not immediately reclaim keyboard focus from the dropdown field.
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
                isSearchFieldFocused = true
            }
            // Initialize highlight to first item
            resetHighlightToFirst()
        }
        .onDisappear {
            isSearchFieldFocused = false
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

/// Popover for advanced search filters (query exclusions + metadata)
public struct AdvancedSearchFilterPopover: View {
    @Binding var windowNameIncludeTerms: [String]
    @Binding var windowNameExcludeTerms: [String]
    @Binding var windowNameFilterMode: AppFilterMode
    @Binding var browserUrlIncludeTerms: [String]
    @Binding var browserUrlExcludeTerms: [String]
    @Binding var browserUrlFilterMode: AppFilterMode
    @Binding var excludedSearchTerms: [String]

    @FocusState private var focusedField: Field?
    @State private var excludedInputText = ""
    @State private var windowInputText = ""
    @State private var browserInputText = ""
    @State private var isExcludeHovered = false
    @State private var isWindowHovered = false
    @State private var isBrowserHovered = false
    @State private var arrowKeyMonitor: Any?
    @State private var lastFocusedField: Field?

    private enum Field: Hashable {
        case excludeTerms
        case windowNameInput
        case browserUrlInput
    }

    public init(
        windowNameIncludeTerms: Binding<[String]>,
        windowNameExcludeTerms: Binding<[String]>,
        windowNameFilterMode: Binding<AppFilterMode>,
        browserUrlIncludeTerms: Binding<[String]>,
        browserUrlExcludeTerms: Binding<[String]>,
        browserUrlFilterMode: Binding<AppFilterMode>,
        excludedSearchTerms: Binding<[String]>
    ) {
        self._windowNameIncludeTerms = windowNameIncludeTerms
        self._windowNameExcludeTerms = windowNameExcludeTerms
        self._windowNameFilterMode = windowNameFilterMode
        self._browserUrlIncludeTerms = browserUrlIncludeTerms
        self._browserUrlExcludeTerms = browserUrlExcludeTerms
        self._browserUrlFilterMode = browserUrlFilterMode
        self._excludedSearchTerms = excludedSearchTerms
    }

    private var normalizedExcludedTerms: [String] {
        deduplicatedTerms(excludedSearchTerms)
    }

    private var normalizedWindowNameIncludeTerms: [String] {
        deduplicatedTerms(windowNameIncludeTerms)
    }

    private var normalizedWindowNameExcludeTerms: [String] {
        deduplicatedTerms(windowNameExcludeTerms)
            .filter { excludeTerm in
                !normalizedWindowNameIncludeTerms.contains { $0.caseInsensitiveCompare(excludeTerm) == .orderedSame }
            }
    }

    private var normalizedBrowserUrlIncludeTerms: [String] {
        deduplicatedTerms(browserUrlIncludeTerms)
    }

    private var normalizedBrowserUrlExcludeTerms: [String] {
        deduplicatedTerms(browserUrlExcludeTerms)
            .filter { excludeTerm in
                !normalizedBrowserUrlIncludeTerms.contains { $0.caseInsensitiveCompare(excludeTerm) == .orderedSame }
            }
    }

    private var hasActiveFilters: Bool {
        !normalizedExcludedTerms.isEmpty ||
        !normalizedWindowNameIncludeTerms.isEmpty ||
        !normalizedWindowNameExcludeTerms.isEmpty ||
        !normalizedBrowserUrlIncludeTerms.isEmpty ||
        !normalizedBrowserUrlExcludeTerms.isEmpty
    }

    private func addExcludedTermFromInput() {
        let candidate = excludedInputText
        excludedInputText = ""
        guard let normalized = Self.normalizedTerm(candidate) else { return }

        var updated = normalizedExcludedTerms
        updated.append(normalized)
        setExcludedTerms(updated)
    }

    private func addWindowNameTermFromInput() {
        let candidate = windowInputText
        windowInputText = ""
        guard let normalized = Self.normalizedTerm(candidate) else { return }

        if windowNameFilterMode == .include {
            var updatedInclude = normalizedWindowNameIncludeTerms
            updatedInclude.append(normalized)
            let filteredExclude = normalizedWindowNameExcludeTerms.filter { $0.caseInsensitiveCompare(normalized) != .orderedSame }
            setWindowNameIncludeTerms(updatedInclude)
            setWindowNameExcludeTerms(filteredExclude)
        } else {
            var updatedExclude = normalizedWindowNameExcludeTerms
            updatedExclude.append(normalized)
            let filteredInclude = normalizedWindowNameIncludeTerms.filter { $0.caseInsensitiveCompare(normalized) != .orderedSame }
            setWindowNameIncludeTerms(filteredInclude)
            setWindowNameExcludeTerms(updatedExclude)
        }
    }

    private func addBrowserUrlTermFromInput() {
        let candidate = browserInputText
        browserInputText = ""
        guard let normalized = Self.normalizedTerm(candidate) else { return }

        if browserUrlFilterMode == .include {
            var updatedInclude = normalizedBrowserUrlIncludeTerms
            updatedInclude.append(normalized)
            let filteredExclude = normalizedBrowserUrlExcludeTerms.filter { $0.caseInsensitiveCompare(normalized) != .orderedSame }
            setBrowserUrlIncludeTerms(updatedInclude)
            setBrowserUrlExcludeTerms(filteredExclude)
        } else {
            var updatedExclude = normalizedBrowserUrlExcludeTerms
            updatedExclude.append(normalized)
            let filteredInclude = normalizedBrowserUrlIncludeTerms.filter { $0.caseInsensitiveCompare(normalized) != .orderedSame }
            setBrowserUrlIncludeTerms(filteredInclude)
            setBrowserUrlExcludeTerms(updatedExclude)
        }
    }

    private func removeTerm(_ term: String, from sourceTerms: [String], setTerms: ([String]) -> Void) {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return }
        let filtered = sourceTerms.filter { existing in
            existing.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != needle
        }
        setTerms(filtered)
    }

    private func setExcludedTerms(_ terms: [String]) {
        let normalized = deduplicatedTerms(terms)
        guard normalized != excludedSearchTerms else { return }
        excludedSearchTerms = normalized
    }

    private func setWindowNameIncludeTerms(_ terms: [String]) {
        let normalized = deduplicatedTerms(terms)
        guard normalized != windowNameIncludeTerms else { return }
        windowNameIncludeTerms = normalized
    }

    private func setWindowNameExcludeTerms(_ terms: [String]) {
        let normalized = deduplicatedTerms(terms)
        guard normalized != windowNameExcludeTerms else { return }
        windowNameExcludeTerms = normalized
    }

    private func setBrowserUrlIncludeTerms(_ terms: [String]) {
        let normalized = deduplicatedTerms(terms)
        guard normalized != browserUrlIncludeTerms else { return }
        browserUrlIncludeTerms = normalized
    }

    private func setBrowserUrlExcludeTerms(_ terms: [String]) {
        let normalized = deduplicatedTerms(terms)
        guard normalized != browserUrlExcludeTerms else { return }
        browserUrlExcludeTerms = normalized
    }

    private struct MetadataChipTerm: Identifiable {
        let term: String
        let mode: AppFilterMode
        var id: String { "\(mode.rawValue):\(term.lowercased())" }
    }

    private var windowNameChips: [MetadataChipTerm] {
        normalizedWindowNameIncludeTerms.map { MetadataChipTerm(term: $0, mode: .include) } +
        normalizedWindowNameExcludeTerms.map { MetadataChipTerm(term: $0, mode: .exclude) }
    }

    private var browserUrlChips: [MetadataChipTerm] {
        normalizedBrowserUrlIncludeTerms.map { MetadataChipTerm(term: $0, mode: .include) } +
        normalizedBrowserUrlExcludeTerms.map { MetadataChipTerm(term: $0, mode: .exclude) }
    }

    private func deduplicatedTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var normalizedTerms: [String] = []

        for term in terms {
            guard let cleaned = Self.normalizedTerm(term) else { continue }
            let key = cleaned.lowercased()
            if seen.insert(key).inserted {
                normalizedTerms.append(cleaned)
            }
        }
        return normalizedTerms
    }

    private static func normalizedTerm(_ term: String) -> String? {
        let collapsed = term
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private func moveFocusDown() {
        switch focusedField {
        case .excludeTerms:
            focusedField = .windowNameInput
        case .windowNameInput:
            focusedField = .browserUrlInput
        default:
            break
        }
    }

    private func moveFocusUp() {
        switch focusedField {
        case .browserUrlInput:
            focusedField = .windowNameInput
        case .windowNameInput:
            focusedField = .excludeTerms
        default:
            break
        }
    }

    private func commitPendingInput(for field: Field?) {
        switch field {
        case .excludeTerms:
            addExcludedTermFromInput()
        case .windowNameInput:
            addWindowNameTermFromInput()
        case .browserUrlInput:
            addBrowserUrlTermFromInput()
        case .none:
            break
        }
    }

    private func commitAllPendingInputs() {
        commitPendingInput(for: .excludeTerms)
        commitPendingInput(for: .windowNameInput)
        commitPendingInput(for: .browserUrlInput)
    }

    private func setupArrowKeyMonitor() {
        guard arrowKeyMonitor == nil else { return }

        arrowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
        FilterPopoverContainer(width: 340) {
            HStack {
                Text("Advanced Filters")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if hasActiveFilters {
                    Button("Clear") {
                        excludedSearchTerms = []
                        windowNameIncludeTerms = []
                        windowNameExcludeTerms = []
                        browserUrlIncludeTerms = []
                        browserUrlExcludeTerms = []
                        windowNameFilterMode = .include
                        browserUrlFilterMode = .include
                        excludedInputText = ""
                        windowInputText = ""
                        browserInputText = ""
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
                    Text("Exclude Frames With Words")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    FocusableTextInput(
                        text: $excludedInputText,
                        placeholder: "Type a word or phrase, then press Return",
                        onSubmit: addExcludedTermFromInput,
                        isFocused: { focusedField == .excludeTerms },
                        setFocused: { isFocused in
                            if isFocused {
                                focusedField = .excludeTerms
                            } else if focusedField == .excludeTerms {
                                focusedField = nil
                            }
                        }
                    )
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    focusedField == .excludeTerms
                                        ? RetraceMenuStyle.filterStrokeStrong
                                        : (isExcludeHovered
                                            ? Color.white.opacity(0.65)
                                            : RetraceMenuStyle.filterStrokeSubtle),
                                    lineWidth: 1
                                )
                        )
                        .onHover { hovering in
                            isExcludeHovered = hovering
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focusedField = .excludeTerms
                        }

                    if !normalizedExcludedTerms.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(normalizedExcludedTerms, id: \.self) { term in
                                    MetadataTermChip(term: term, mode: .exclude) {
                                        removeTerm(term, from: normalizedExcludedTerms, setTerms: setExcludedTerms)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Window Name")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    HStack(spacing: 10) {
                        FocusableTextInput(
                            text: $windowInputText,
                            placeholder: "Search titles...",
                            onSubmit: addWindowNameTermFromInput,
                            isFocused: { focusedField == .windowNameInput },
                            setFocused: { isFocused in
                                if isFocused {
                                    focusedField = .windowNameInput
                                } else if focusedField == .windowNameInput {
                                    focusedField = nil
                                }
                            }
                        )

                        IncludeExcludeModeToggle(mode: $windowNameFilterMode)
                            .frame(width: 138)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                focusedField == .windowNameInput
                                    ? RetraceMenuStyle.filterStrokeStrong
                                    : (isWindowHovered
                                        ? Color.white.opacity(0.65)
                                        : RetraceMenuStyle.filterStrokeSubtle),
                                lineWidth: 1
                            )
                    )
                    .onHover { hovering in
                        isWindowHovered = hovering
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedField = .windowNameInput
                    }

                    if !windowNameChips.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(windowNameChips) { chip in
                                    MetadataTermChip(term: chip.term, mode: chip.mode) {
                                        if chip.mode == .include {
                                            removeTerm(chip.term, from: normalizedWindowNameIncludeTerms, setTerms: setWindowNameIncludeTerms)
                                        } else {
                                            removeTerm(chip.term, from: normalizedWindowNameExcludeTerms, setTerms: setWindowNameExcludeTerms)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Browser URL")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    HStack(spacing: 10) {
                        FocusableTextInput(
                            text: $browserInputText,
                            placeholder: "Search URLs...",
                            onSubmit: addBrowserUrlTermFromInput,
                            isFocused: { focusedField == .browserUrlInput },
                            setFocused: { isFocused in
                                if isFocused {
                                    focusedField = .browserUrlInput
                                } else if focusedField == .browserUrlInput {
                                    focusedField = nil
                                }
                            }
                        )

                        IncludeExcludeModeToggle(mode: $browserUrlFilterMode)
                            .frame(width: 138)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                focusedField == .browserUrlInput
                                    ? RetraceMenuStyle.filterStrokeStrong
                                    : (isBrowserHovered
                                        ? Color.white.opacity(0.65)
                                        : RetraceMenuStyle.filterStrokeSubtle),
                                lineWidth: 1
                            )
                    )
                    .onHover { hovering in
                        isBrowserHovered = hovering
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedField = .browserUrlInput
                    }

                    if !browserUrlChips.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(browserUrlChips) { chip in
                                    MetadataTermChip(term: chip.term, mode: chip.mode) {
                                        if chip.mode == .include {
                                            removeTerm(chip.term, from: normalizedBrowserUrlIncludeTerms, setTerms: setBrowserUrlIncludeTerms)
                                        } else {
                                            removeTerm(chip.term, from: normalizedBrowserUrlExcludeTerms, setTerms: setBrowserUrlExcludeTerms)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .onAppear {
            setExcludedTerms(excludedSearchTerms)
            setWindowNameIncludeTerms(windowNameIncludeTerms)
            setWindowNameExcludeTerms(windowNameExcludeTerms)
            setBrowserUrlIncludeTerms(browserUrlIncludeTerms)
            setBrowserUrlExcludeTerms(browserUrlExcludeTerms)
            lastFocusedField = focusedField
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedField = .excludeTerms
            }
            setupArrowKeyMonitor()
        }
        .onChange(of: focusedField) { newValue in
            let previousField = lastFocusedField
            lastFocusedField = newValue
            guard previousField != newValue else { return }
            commitPendingInput(for: previousField)
        }
        .onDisappear {
            commitAllPendingInputs()
            lastFocusedField = nil
            removeArrowKeyMonitor()
        }
    }
}

struct IncludeExcludeModeToggle: View {
    @Binding var mode: AppFilterMode

    var body: some View {
        HStack(spacing: 6) {
            TogglePillButton(
                title: "Include",
                isSelected: mode == .include,
                selectedTint: RetraceMenuStyle.actionBlue
            ) {
                mode = .include
            }

            TogglePillButton(
                title: "Exclude",
                isSelected: mode == .exclude,
                selectedTint: .orange.opacity(0.9)
            ) {
                mode = .exclude
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.05))
        )
    }
}

private struct TogglePillButton: View {
    let title: String
    let isSelected: Bool
    let selectedTint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSelected ? .white : RetraceMenuStyle.textColorMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            isSelected
                                ? selectedTint
                                : (isHovered ? Color.white.opacity(0.08) : Color.clear)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private struct MetadataTermChip: View {
    let term: String
    let mode: AppFilterMode
    let onRemove: () -> Void

    @State private var isHovered = false

    private var iconName: String {
        mode == .include ? "plus.circle.fill" : "minus.circle.fill"
    }

    private var iconTint: Color {
        mode == .include ? .blue.opacity(0.88) : .orange.opacity(0.9)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(iconTint)

            Text(term)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(isHovered ? 0.2 : 0.14))
        )
        .overlay(
            Capsule()
                .stroke(
                    isHovered ? Color.white.opacity(0.6) : RetraceMenuStyle.filterStrokeSubtle,
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            isHovered = hovering
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

/// Popover for selecting comment-presence filter
public struct CommentFilterPopover: View {
    let currentFilter: CommentFilter
    let onSelect: (CommentFilter) -> Void
    var onDismiss: (() -> Void)?
    var onKeyboardSelect: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var highlightedIndex: Int = 0

    private let options: [CommentFilter] = [.allFrames, .commentsOnly, .noComments]

    public init(
        currentFilter: CommentFilter,
        onSelect: @escaping (CommentFilter) -> Void,
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
                    FilterRow(
                        systemIcon: "text.bubble",
                        title: "All Frames",
                        subtitle: "Show frames regardless of comments",
                        isSelected: currentFilter == .allFrames,
                        isKeyboardHighlighted: highlightedIndex == 0
                    ) {
                        onSelect(.allFrames)
                        onDismiss?()
                    }
                    .id(0)

                    Divider()
                        .padding(.vertical, 4)

                    FilterRow(
                        systemIcon: "text.bubble.fill",
                        title: "Comments Only",
                        subtitle: "Show frames from commented segments",
                        isSelected: currentFilter == .commentsOnly,
                        isKeyboardHighlighted: highlightedIndex == 1
                    ) {
                        onSelect(.commentsOnly)
                        onDismiss?()
                    }
                    .id(1)

                    FilterRow(
                        systemIcon: "text.bubble.slash",
                        title: "No Comments",
                        subtitle: "Show frames from segments without comments",
                        isSelected: currentFilter == .noComments,
                        isKeyboardHighlighted: highlightedIndex == 2
                    ) {
                        onSelect(.noComments)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
            if let index = options.firstIndex(of: currentFilter) {
                highlightedIndex = index
            }
        }
        .onChange(of: isFocused) { focused in
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
    public enum HorizontalAnchor {
        case leading
        case trailing
    }

    @Binding var isPresented: Bool
    let yOffset: CGFloat
    let opensUpward: Bool
    let horizontalAnchor: HorizontalAnchor
    let dismissOnOutsideClick: Bool
    let dropdownContent: () -> DropdownContent

    @State private var triggerFrame: CGRect = .zero
    @State private var contentFrame: CGRect = .zero
    @State private var outsideClickMonitor: Any?

    public init(
        isPresented: Binding<Bool>,
        yOffset: CGFloat = 44,
        opensUpward: Bool = false,
        horizontalAnchor: HorizontalAnchor = .leading,
        dismissOnOutsideClick: Bool = true,
        @ViewBuilder dropdownContent: @escaping () -> DropdownContent
    ) {
        self._isPresented = isPresented
        self.yOffset = yOffset
        self.opensUpward = opensUpward
        self.horizontalAnchor = horizontalAnchor
        self.dismissOnOutsideClick = dismissOnOutsideClick
        self.dropdownContent = dropdownContent
    }

    private var overlayAlignment: Alignment {
        switch (opensUpward, horizontalAnchor) {
        case (false, .leading):
            return .topLeading
        case (false, .trailing):
            return .topTrailing
        case (true, .leading):
            return .bottomLeading
        case (true, .trailing):
            return .bottomTrailing
        }
    }

    private func installOutsideClickMonitorIfNeeded() {
        guard dismissOnOutsideClick else { return }
        guard outsideClickMonitor == nil else { return }

        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            guard isPresented else { return event }
            guard DropdownOverlayInteraction.shouldDismiss(
                event: event,
                triggerFrame: triggerFrame,
                contentFrame: contentFrame
            ) else {
                return event
            }
            isPresented = false
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    public func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                let globalFrame = geo.frame(in: .global)
                Color.clear
                    .onAppear {
                        guard DropdownOverlayInteraction.isUsableFrame(globalFrame),
                              triggerFrame != globalFrame else { return }
                        triggerFrame = globalFrame
                    }
                    .onChange(of: globalFrame) { updatedFrame in
                        guard DropdownOverlayInteraction.isUsableFrame(updatedFrame),
                              triggerFrame != updatedFrame else { return }
                        triggerFrame = updatedFrame
                    }
            })
            .onChange(of: isPresented) { isPresented in
                if isPresented {
                    installOutsideClickMonitorIfNeeded()
                } else {
                    removeOutsideClickMonitor()
                    contentFrame = .zero
                }
            }
            .onDisappear {
                removeOutsideClickMonitor()
            }
            .overlay(alignment: overlayAlignment) {
                if isPresented {
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
                        let globalFrame = geo.frame(in: .global)
                        Color.clear
                            .onAppear {
                                guard DropdownOverlayInteraction.isUsableFrame(globalFrame),
                                      contentFrame != globalFrame else { return }
                                contentFrame = globalFrame
                            }
                            .onChange(of: globalFrame) { updatedFrame in
                                guard DropdownOverlayInteraction.isUsableFrame(updatedFrame),
                                      contentFrame != updatedFrame else { return }
                                contentFrame = updatedFrame
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
        horizontalAnchor: DropdownOverlayModifier<Content>.HorizontalAnchor = .leading,
        dismissOnOutsideClick: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(
            DropdownOverlayModifier(
                isPresented: isPresented,
                yOffset: yOffset,
                opensUpward: opensUpward,
                horizontalAnchor: horizontalAnchor,
                dismissOnOutsideClick: dismissOnOutsideClick,
                dropdownContent: content
            )
        )
    }
}

// MARK: - Date Range Filter Popover

enum DateRangeInputFocusTarget: Equatable {
    case none
    case primary
    case additional(UUID)
}

enum DateRangeInputFocusEvent: Equatable {
    case setPrimary(Bool)
    case setAdditional(UUID, Bool)
    case clear
}

enum DateRangeInputFocusResolver {
    static func resolve(
        current: DateRangeInputFocusTarget,
        event: DateRangeInputFocusEvent
    ) -> DateRangeInputFocusTarget {
        switch event {
        case .clear:
            return .none
        case .setPrimary(true):
            return .primary
        case .setPrimary(false):
            return current == .primary ? .none : current
        case let .setAdditional(id, true):
            return .additional(id)
        case let .setAdditional(id, false):
            return current == .additional(id) ? .none : current
        }
    }

    static func isPrimaryFocused(_ target: DateRangeInputFocusTarget) -> Bool {
        target == .primary
    }

    static func focusedAdditionalID(_ target: DateRangeInputFocusTarget) -> UUID? {
        guard case let .additional(id) = target else { return nil }
        return id
    }
}

struct DateRangeInputParser {
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func parse(_ text: String, now: Date = Date()) -> (start: Date, end: Date)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let naturalLanguageRange = parseNaturalLanguageRange(trimmed, now: now) {
            return naturalLanguageRange
        }

        if let split = splitRangeText(trimmed),
           let start = parseSingleDate(split.start, relativeTo: nil, now: now),
           let end = parseSingleDate(split.end, relativeTo: start, now: now) {
            return normalizeRange(start, end)
        }

        if let detectedRange = parseRangeWithDetector(trimmed, now: now) {
            return normalizeRange(detectedRange.start, detectedRange.end)
        }

        if let single = parseSingleDate(trimmed, relativeTo: nil, now: now) {
            let day = calendar.startOfDay(for: single)
            return (day, day)
        }

        return nil
    }

    private func parseNaturalLanguageRange(_ text: String, now: Date) -> (start: Date, end: Date)? {
        let normalized = normalizeNaturalLanguageRangeText(text)

        switch normalized {
        case "past week":
            return rollingRange(daySpan: 7, now: now)
        case "past month":
            return rollingRange(daySpan: 30, now: now)
        case "this week":
            return currentWeekRange(now: now)
        case "last week":
            return previousWeekRange(now: now)
        case "this month":
            return currentMonthRange(now: now)
        case "last month":
            return previousMonthRange(now: now)
        default:
            break
        }

        if let leadingDaysRange = parseLeadingDaysWithinPeriod(normalized, now: now) {
            return leadingDaysRange
        }

        if let dayCount = captureLeadingCount(
            in: normalized,
            pattern: #"^(?:last|past)\s+(\d+)\s+days?$"#
        ) {
            return rollingRange(daySpan: dayCount, now: now)
        }

        if let weekCount = captureLeadingCount(
            in: normalized,
            pattern: #"^(?:last|past)\s+(\d+)\s+weeks?$"#
        ) {
            return rollingRange(daySpan: weekCount * 7, now: now)
        }

        if let compactDayCount = captureLeadingCount(in: normalized, pattern: #"^(\d+)d$"#) {
            return rollingRange(daySpan: compactDayCount, now: now)
        }

        return nil
    }

    private func parseLeadingDaysWithinPeriod(_ text: String, now: Date) -> (start: Date, end: Date)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^first\s+(\d+)\s+days?\s+of\s+(.+)$"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let countRange = Range(match.range(at: 1), in: text),
              let targetRange = Range(match.range(at: 2), in: text),
              let dayCount = Int(text[countRange]) else {
            return nil
        }

        let rawTarget = String(text[targetRange])
        guard let periodInterval = periodInterval(forLeadingDaysTarget: rawTarget, now: now) else {
            return nil
        }

        return firstDaysRange(dayCount: dayCount, in: periodInterval)
    }

    private func normalizeNaturalLanguageRangeText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func periodInterval(forLeadingDaysTarget target: String, now: Date) -> DateInterval? {
        let cleanedTarget = target
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"^the\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+month$"#, with: "", options: .regularExpression)

        switch cleanedTarget {
        case "week", "this week":
            return mondayAnchoredWeekInterval(containing: now)
        case "last week":
            guard let currentWeek = mondayAnchoredWeekInterval(containing: now),
                  let previousWeekReference = calendar.date(byAdding: .day, value: -1, to: currentWeek.start) else {
                return nil
            }
            return mondayAnchoredWeekInterval(containing: previousWeekReference)
        case "month", "this month":
            return calendar.dateInterval(of: .month, for: now)
        case "last month":
            guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: now) else {
                return nil
            }
            return calendar.dateInterval(of: .month, for: previousMonth)
        default:
            return monthInterval(for: cleanedTarget, now: now)
        }
    }

    private func monthInterval(for target: String, now: Date) -> DateInterval? {
        let startOfCurrentMonth = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let candidateInputs = [
            target,
            target.prefix(1).uppercased() + target.dropFirst()
        ]

        let formatStrings = ["MMMM yyyy", "MMM yyyy", "MMMM", "MMM"]
        for format in formatStrings {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.defaultDate = startOfCurrentMonth

            for candidate in candidateInputs {
                if let monthDate = formatter.date(from: String(candidate)) {
                    return calendar.dateInterval(of: .month, for: monthDate)
                }
            }
        }

        return nil
    }

    private func captureLeadingCount(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return Int(text[captureRange])
    }

    private func rollingRange(daySpan: Int, now: Date) -> (start: Date, end: Date)? {
        let boundedDaySpan = max(1, daySpan)
        let today = calendar.startOfDay(for: now)
        let offset = -(boundedDaySpan - 1)
        let start = calendar.date(byAdding: .day, value: offset, to: today) ?? today
        return normalizeRange(start, today)
    }

    private func currentWeekRange(now: Date) -> (start: Date, end: Date)? {
        guard let interval = mondayAnchoredWeekInterval(containing: now) else {
            return nil
        }

        let start = interval.start
        let today = calendar.startOfDay(for: now)
        return normalizeRange(start, today)
    }

    private func previousWeekRange(now: Date) -> (start: Date, end: Date)? {
        guard let currentWeek = mondayAnchoredWeekInterval(containing: now),
              let previousWeekReference = calendar.date(byAdding: .day, value: -1, to: currentWeek.start),
              let interval = mondayAnchoredWeekInterval(containing: previousWeekReference) else {
            return nil
        }

        let end = interval.end.addingTimeInterval(-1)
        return normalizeRange(interval.start, end)
    }

    private func currentMonthRange(now: Date) -> (start: Date, end: Date)? {
        guard let interval = calendar.dateInterval(of: .month, for: now) else {
            return nil
        }

        let start = interval.start
        let today = calendar.startOfDay(for: now)
        return normalizeRange(start, today)
    }

    private func previousMonthRange(now: Date) -> (start: Date, end: Date)? {
        guard let previousMonthDate = calendar.date(byAdding: .month, value: -1, to: now),
              let interval = calendar.dateInterval(of: .month, for: previousMonthDate) else {
            return nil
        }

        let end = interval.end.addingTimeInterval(-1)
        return normalizeRange(interval.start, end)
    }

    private func mondayAnchoredWeekInterval(containing date: Date) -> DateInterval? {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7

        guard let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: day),
              let end = calendar.date(byAdding: .day, value: 7, to: start) else {
            return nil
        }

        return DateInterval(start: start, end: end)
    }

    private func firstDaysRange(dayCount: Int, in interval: DateInterval) -> (start: Date, end: Date)? {
        let boundedCount = max(1, dayCount)
        let start = calendar.startOfDay(for: interval.start)
        let intervalEndDay = calendar.startOfDay(for: interval.end.addingTimeInterval(-1))
        let candidateEnd = calendar.date(byAdding: .day, value: boundedCount - 1, to: start) ?? start
        let clampedEnd = min(candidateEnd, intervalEndDay)
        return normalizeRange(start, clampedEnd)
    }

    private func parseRangeWithDetector(_ text: String, now: Date) -> (start: Date, end: Date)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        guard let first = matches.first, let firstDate = first.date else {
            return nil
        }

        let firstMatchText = Range(first.range, in: text).map { String(text[$0]) } ?? text
        let adjustedFirstDate = adjustImplicitFutureDateToPast(firstDate, originalText: firstMatchText, now: now)

        if first.duration > 0 {
            let rawEnd = firstDate.addingTimeInterval(first.duration)
            let adjustedEnd = adjustImplicitFutureDateToPast(rawEnd, originalText: firstMatchText, now: now)
            return (adjustedFirstDate, adjustedEnd)
        }

        if matches.count >= 2, let secondDate = matches[1].date {
            let secondMatchText = Range(matches[1].range, in: text).map { String(text[$0]) } ?? text
            let adjustedSecondDate = adjustImplicitFutureDateToPast(secondDate, originalText: secondMatchText, now: now)
            return (adjustedFirstDate, adjustedSecondDate)
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

    private func parseSingleDate(_ text: String, relativeTo referenceDate: Date?, now: Date) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLower = trimmed.lowercased()

        Chrono.defaultImpliedHour = 0
        let chrono = Chrono()
        let results = chrono.parse(text: trimmed, refDate: referenceDate ?? now, opt: [.forwardDate: 0])
        if let result = results.first?.start.date {
            return adjustImplicitFutureDateToPast(result, originalText: trimmedLower, now: now)
        }

        if let referenceDate,
           let day = Int(trimmedLower),
           (1...31).contains(day) {
            var referenceComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            referenceComponents.day = day

            if let candidate = calendar.date(from: referenceComponents) {
                if let referenceDay = calendar.dateComponents([.day], from: referenceDate).day,
                   day < referenceDay,
                   let nextMonth = calendar.date(byAdding: .month, value: 1, to: referenceDate) {
                    var nextMonthComponents = calendar.dateComponents([.year, .month], from: nextMonth)
                    nextMonthComponents.day = day
                    return calendar.date(from: nextMonthComponents) ?? candidate
                }
                return candidate
            }
        }

        if let timeOnlyDate = parseTimeOnly(trimmedLower, relativeTo: now) {
            return timeOnlyDate
        }

        let normalizedText = normalizeCompactTimeFormat(trimmedLower)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(normalizedText.startIndex..., in: normalizedText)
            if let match = detector.firstMatch(in: normalizedText, options: [], range: range),
               let date = match.date {
                return adjustImplicitFutureDateToPast(date, originalText: trimmedLower, now: now)
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

            if let date = formatter.date(from: text) {
                return adjustImplicitFutureDateToPast(date, originalText: trimmedLower, now: now)
            }
            if let date = formatter.date(from: trimmed) {
                return adjustImplicitFutureDateToPast(date, originalText: trimmedLower, now: now)
            }

            let capitalized = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
            if let date = formatter.date(from: capitalized) {
                return adjustImplicitFutureDateToPast(date, originalText: trimmedLower, now: now)
            }
        }

        return nil
    }

    private func adjustImplicitFutureDateToPast(_ date: Date, originalText: String, now: Date) -> Date {
        guard shouldPreferPastYearForImplicitDateText(originalText) else {
            return date
        }

        let cutoff = calendar.startOfDay(for: now)
        var adjusted = date

        while calendar.startOfDay(for: adjusted) > cutoff,
              let previousYear = calendar.date(byAdding: .year, value: -1, to: adjusted) {
            adjusted = previousYear
        }

        return adjusted
    }

    private func shouldPreferPastYearForImplicitDateText(_ text: String) -> Bool {
        guard !textContainsExplicitYear(text) else { return false }
        return textContainsMonthReference(text)
    }

    private func textContainsExplicitYear(_ text: String) -> Bool {
        let patterns = [
            #"\b(?:19|20)\d{2}\b"#,
            #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#
        ]

        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func textContainsMonthReference(_ text: String) -> Bool {
        let patterns = [
            #"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b"#,
            #"\b\d{1,2}[/-]\d{1,2}\b"#
        ]

        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
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

    private func normalizeRange(_ start: Date, _ end: Date) -> (start: Date, end: Date) {
        var startDay = calendar.startOfDay(for: start)
        var endDay = calendar.startOfDay(for: end)
        if endDay < startDay {
            swap(&startDay, &endDay)
        }

        return (startDay, endDay)
    }
}

public enum DateRangeQuickPreset: String, CaseIterable {
    case today = "today"
    case yesterday = "yesterday"
    case lastSevenDays = "last_7_days"
    case lastThirtyDays = "last_30_days"

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .yesterday:
            return "Yesterday"
        case .lastSevenDays:
            return "Last 7 Days"
        case .lastThirtyDays:
            return "Last 30 Days"
        }
    }

    var chipLabel: String {
        switch self {
        case .today:
            return "Today"
        case .yesterday:
            return "1d"
        case .lastSevenDays:
            return "7d"
        case .lastThirtyDays:
            return "30d"
        }
    }

    var shortcutKeyLabel: String {
        switch self {
        case .today:
            return "A"
        case .yesterday:
            return "S"
        case .lastSevenDays:
            return "D"
        case .lastThirtyDays:
            return "F"
        }
    }

    var helpText: String {
        "\(title) (\(shortcutKeyLabel))"
    }

    var focusedItemIndex: Int {
        switch self {
        case .today:
            return 1
        case .yesterday:
            return 2
        case .lastSevenDays:
            return 3
        case .lastThirtyDays:
            return 4
        }
    }

    static func preset(
        for charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Self? {
        guard let key = charactersIgnoringModifiers?.lowercased(),
              key.count == 1 else {
            return nil
        }

        let relevantModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        guard relevantModifiers.intersection(disallowedModifiers).isEmpty else {
            return nil
        }

        switch key {
        case "a":
            return .today
        case "s":
            return .yesterday
        case "d":
            return .lastSevenDays
        case "f":
            return .lastThirtyDays
        default:
            return nil
        }
    }

    func resolvedRange(now: Date = Date(), calendar: Calendar = .current) -> DateRangeCriterion {
        let today = calendar.startOfDay(for: now)
        let startDay: Date
        let endDay: Date

        switch self {
        case .today:
            startDay = today
            endDay = today
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            startDay = yesterday
            endDay = yesterday
        case .lastSevenDays:
            startDay = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            endDay = today
        case .lastThirtyDays:
            startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            endDay = today
        }

        let normalizedStart = calendar.startOfDay(for: startDay)
        let normalizedEndDay = calendar.startOfDay(for: endDay)
        let normalizedEnd = calendar.date(
            bySettingHour: 23,
            minute: 59,
            second: 59,
            of: normalizedEndDay
        ) ?? normalizedEndDay

        return DateRangeCriterion(start: normalizedStart, end: normalizedEnd)
    }

    static func matchingPreset(
        for range: DateRangeCriterion?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Self? {
        guard let range,
              let start = range.start ?? range.end,
              let end = range.end ?? range.start else {
            return nil
        }

        return allCases.first { preset in
            let resolved = preset.resolvedRange(now: now, calendar: calendar)
            guard let resolvedStart = resolved.start,
                  let resolvedEnd = resolved.end else {
                return false
            }

            return calendar.isDate(start, inSameDayAs: resolvedStart)
                && calendar.isDate(end, inSameDayAs: resolvedEnd)
        }
    }
}

/// Popover for selecting one or more date ranges with natural-language input and calendar support.
public struct DateRangeFilterPopover: View {
    let dateRanges: [DateRangeCriterion]
    let onApply: ([DateRangeCriterion]) -> Void
    let onClear: () -> Void
    let width: CGFloat
    let enableKeyboardNavigation: Bool
    let allowMultipleRanges: Bool
    let maxRangeDays: Int?
    let onMoveToNextFilter: (() -> Void)?
    let onCalendarEditingChange: ((Bool) -> Void)?
    let onQuickPresetShortcut: ((DateRangeQuickPreset) -> Void)?
    let onClearShortcut: (() -> Void)?
    let focusPrimaryInputRequestID: UUID?
    let isResetEnabled: Bool
    var onDismiss: (() -> Void)?

    @State private var localStartDate: Date
    @State private var localEndDate: Date
    @State private var rangeInputText: String = ""
    @State private var parseError: String?
    @State private var hasCommittedPrimaryRange = false
    @State private var additionalRangeInputTexts: [String] = []
    // Keep per-row identity stable so TextField bindings do not outlive a removed array index.
    @State private var additionalRangeIDs: [UUID] = []
    @State private var additionalParseErrors: [String?] = []
    @State private var additionalParsedRanges: [DateRangeCriterion?] = []
    @State private var isCalendarVisible = false
    @State private var activeCalendarBoundary: CalendarBoundary = .start
    @State private var activeCalendarTarget: CalendarTarget = .primary
    @State private var lastFocusedCalendarTarget: CalendarTarget = .primary
    @State private var displayedMonth: Date = Date()
    @State private var focusedItem: Int = -1
    @State private var keyboardMonitor: Any?
    @State private var rangeInputFocusTarget: DateRangeInputFocusTarget = .none
    @State private var isHoveringResetButton = false
    @State private var isHoveringPrimaryInput = false
    @State private var hoveredAdditionalRangeID: UUID?
    @State private var isHoveringCalendarToggle = false
    @State private var hoveredQuickPreset: DateRangeQuickPreset?

    private let calendar = Calendar.current
    private var inputParser: DateRangeInputParser {
        DateRangeInputParser(calendar: calendar)
    }
    private let weekdaySymbols = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
    private let primaryRangeFocusedItem = -1
    private let itemCount = 5

    private enum CalendarBoundary {
        case start
        case end
    }

    private enum CalendarTarget: Equatable {
        case primary
        case additional(UUID)
    }

    private var canAddAnotherRange: Bool {
        guard allowMultipleRanges else { return false }
        let additionalCommittedCount = additionalParsedRanges.compactMap { range in
            range?.hasBounds == true ? range : nil
        }.count
        return (hasCommittedPrimaryRange || additionalCommittedCount > 0) && additionalRangeInputTexts.count < 4
    }

    private var activeRangeCount: Int {
        let primaryCount = rangeInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        let additionalCount = additionalRangeInputTexts.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        return primaryCount + additionalCount
    }

    private var isAnyRangeInputFocused: Bool {
        rangeInputFocusTarget != .none
    }

    private var isRangeInputFocused: Bool {
        DateRangeInputFocusResolver.isPrimaryFocused(rangeInputFocusTarget)
    }

    private var focusedAdditionalRangeID: UUID? {
        DateRangeInputFocusResolver.focusedAdditionalID(rangeInputFocusTarget)
    }

    private var isPrimaryInputHighlighted: Bool {
        isRangeInputFocused ||
        isHoveringPrimaryInput ||
        (
            enableKeyboardNavigation &&
            focusedItem == primaryRangeFocusedItem &&
            !isAnyRangeInputFocused &&
            !isCalendarVisible
        )
    }

    private func isAdditionalInputHighlighted(_ id: UUID) -> Bool {
        focusedAdditionalRangeID == id || hoveredAdditionalRangeID == id
    }

    private var isCalendarToggleHighlighted: Bool {
        isCalendarVisible ||
        isHoveringCalendarToggle ||
        (
            enableKeyboardNavigation &&
            focusedItem == 0 &&
            !isAnyRangeInputFocused
        )
    }

    private var calendarToggleForegroundColor: Color {
        .white.opacity(isCalendarToggleHighlighted ? 1 : 0.88)
    }

    private var calendarToggleBackgroundColor: Color {
        isCalendarToggleHighlighted
            ? RetraceMenuStyle.actionBlue
            : Color.white.opacity(0.08)
    }

    private var calendarToggleBorderColor: Color {
        if isCalendarToggleHighlighted {
            return RetraceMenuStyle.actionBlue.opacity(0.55)
        }
        return Color.white.opacity(0.08)
    }

    private var calendarToggleHintColor: Color {
        isCalendarToggleHighlighted ? .white.opacity(0.82) : .white.opacity(0.55)
    }

    public init(
        dateRanges: [DateRangeCriterion] = [],
        onApply: @escaping ([DateRangeCriterion]) -> Void,
        onClear: @escaping () -> Void,
        width: CGFloat = 300,
        enableKeyboardNavigation: Bool = false,
        allowMultipleRanges: Bool = true,
        maxRangeDays: Int? = nil,
        onMoveToNextFilter: (() -> Void)? = nil,
        onCalendarEditingChange: ((Bool) -> Void)? = nil,
        onQuickPresetShortcut: ((DateRangeQuickPreset) -> Void)? = nil,
        onClearShortcut: (() -> Void)? = nil,
        focusPrimaryInputRequestID: UUID? = nil,
        isResetEnabled: Bool = true,
        onDismiss: (() -> Void)? = nil
    ) {
        let maxRangeCount = allowMultipleRanges ? 5 : 1
        self.dateRanges = Array(dateRanges.filter(\.hasBounds).prefix(maxRangeCount))
        self.onApply = onApply
        self.onClear = onClear
        self.width = width
        self.enableKeyboardNavigation = enableKeyboardNavigation
        self.allowMultipleRanges = allowMultipleRanges
        self.maxRangeDays = maxRangeDays.map { max(1, $0) }
        self.onMoveToNextFilter = onMoveToNextFilter
        self.onCalendarEditingChange = onCalendarEditingChange
        self.onQuickPresetShortcut = onQuickPresetShortcut
        self.onClearShortcut = onClearShortcut
        self.focusPrimaryInputRequestID = focusPrimaryInputRequestID
        self.isResetEnabled = isResetEnabled
        self.onDismiss = onDismiss

        let now = Date()
        let primaryRange = self.dateRanges.first
        let primaryStart = primaryRange?.start ?? primaryRange?.end ?? calendar.date(byAdding: .day, value: -7, to: now)!
        let primaryEnd = primaryRange?.end ?? primaryRange?.start ?? now
        _localStartDate = State(initialValue: primaryStart)
        _localEndDate = State(initialValue: primaryEnd)
        _displayedMonth = State(initialValue: primaryEnd)
    }

    public var body: some View {
        FilterPopoverContainer(width: width) {
            // Header
            HStack {
                Text("Date Range")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if activeRangeCount > 0 {
                    Button("Reset") {
                        guard isResetEnabled else { return }
                        clearAllRangesAndDismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isResetEnabled ? RetraceMenuStyle.actionBlue : RetraceMenuStyle.textColorMuted.opacity(0.55))
                    .disabled(!isResetEnabled)
                    .onHover { hovering in
                        isHoveringResetButton = hovering
                        if isResetEnabled {
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                    .instantTooltip(
                        allowMultipleRanges ? "Reset Ranges (⌘⌫)" : "Reset Range (⌘⌫)",
                        isVisible: .constant(isHoveringResetButton && isResetEnabled),
                        placement: .bottom
                    )
                }
            }
            .zIndex(isHoveringResetButton ? 10 : 0)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
                .background(Color.white.opacity(0.1))

            // Natural language range input
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))

                    FocusableTextInput(
                        text: $rangeInputText,
                        placeholder: "e.g. Dec 5, 2025 to Dec 8, 2025 | last week to now",
                        font: .systemFont(ofSize: 12, weight: .regular),
                        onSubmit: {
                            applyCurrentSelection(moveToNextDropdown: false)
                        },
                        isFocused: { isRangeInputFocused },
                        setFocused: { isFocused in
                            handleRangeInputFocusEvent(.setPrimary(isFocused))
                        },
                        onBlur: canonicalizeInputTextIfPossible,
                        onClick: {
                            focusTextInput(.primary)
                        }
                    )
                    .modifier(FocusEffectDisabledModifier())
                    .onChange(of: isRangeInputFocused) { isFocused in
                        if isFocused {
                            focusedItem = primaryRangeFocusedItem
                            lastFocusedCalendarTarget = .primary
                            if isCalendarVisible {
                                synchronizeCalendarStateFromTarget(.primary)
                            }
                        }
                    }
                    .onChange(of: rangeInputText) { _ in
                        parseError = nil
                    }

                    if !rangeInputText.isEmpty {
                        Button(action: {
                            rangeInputText = ""
                            parseError = nil
                            hasCommittedPrimaryRange = false
                            applyAllRanges(moveToNextDropdown: false)
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
                        .stroke(
                            isPrimaryInputHighlighted
                                ? RetraceMenuStyle.filterStrokeMedium
                                : Color.clear,
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHoveringPrimaryInput = hovering
                }
                .onTapGesture {
                    focusTextInput(.primary)
                }

                if let parseError {
                    Text(parseError)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange.opacity(0.9))
                        .padding(.horizontal, 2)
                }

                if allowMultipleRanges {
                    ForEach(additionalRangeIDs, id: \.self) { rangeID in
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.3))

                            FocusableTextInput(
                                text: additionalRangeBinding(for: rangeID),
                                placeholder: additionalRangePlaceholder(for: rangeID),
                                font: .systemFont(ofSize: 12, weight: .regular),
                                onSubmit: {
                                    applyAdditionalRangeInput(for: rangeID)
                                },
                                isFocused: { focusedAdditionalRangeID == rangeID },
                                setFocused: { isFocused in
                                    handleRangeInputFocusEvent(.setAdditional(rangeID, isFocused))
                                },
                                onClick: {
                                    focusTextInput(.additional(rangeID))
                                }
                            )
                            .modifier(FocusEffectDisabledModifier())

                            Button(action: {
                                removeAdditionalRange(id: rangeID)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    isAdditionalInputHighlighted(rangeID) ? RetraceMenuStyle.filterStrokeMedium : Color.clear,
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoveredAdditionalRangeID = hovering ? rangeID : (hoveredAdditionalRangeID == rangeID ? nil : hoveredAdditionalRangeID)
                        }
                        .onTapGesture {
                            focusTextInput(.additional(rangeID))
                        }

                        if let additionalError = additionalParseErrorMessage(for: rangeID) {
                            Text(additionalError)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.orange.opacity(0.9))
                                .padding(.horizontal, 2)
                        }
                    }

                    if canAddAnotherRange {
                        Button(action: {
                            addAdditionalRangeInput()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Add another date range")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(.white.opacity(0.78))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.09))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
                .background(Color.white.opacity(0.1))

            // Calendar range toggle and hint
            Button(action: {
                toggleCalendarVisibility()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(calendarToggleForegroundColor)
                    Text(isCalendarVisible ? "Hide Calendar" : "Browse Calendar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(calendarToggleForegroundColor)

                    Spacer()

                    if isCalendarVisible {
                        Text(activeCalendarBoundary == .start ? "Pick start" : "Pick end")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(calendarToggleHintColor)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(calendarToggleBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(calendarToggleBorderColor, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onHover { hovering in
                isHoveringCalendarToggle = hovering
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
                ForEach(DateRangeQuickPreset.allCases, id: \.self) { preset in
                    presetChip(
                        preset,
                        isHighlighted: enableKeyboardNavigation && focusedItem == preset.focusedItemIndex
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .padding(.bottom, 10)
        }
        .onAppear {
            configureInitialState()

            if enableKeyboardNavigation {
                focusedItem = initialKeyboardFocusedItem()
                setupKeyboardMonitor()
            }

            DispatchQueue.main.async {
                if focusPrimaryInputRequestID != nil {
                    focusPrimaryRangeInput()
                } else if enableKeyboardNavigation {
                    setRangeInputFocus(.none)
                } else {
                    setRangeInputFocus(.primary)
                }
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
        .onChange(of: focusedAdditionalRangeID) { focusedID in
            if let focusedID {
                focusedItem = -1
                lastFocusedCalendarTarget = .additional(focusedID)
                if isCalendarVisible {
                    synchronizeCalendarStateFromTarget(.additional(focusedID))
                }
            }
        }
        .onChange(of: focusPrimaryInputRequestID) { requestID in
            guard requestID != nil else { return }
            focusPrimaryRangeInput()
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
                        ZStack {
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
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Rectangle())
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
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
        }
    }

    // MARK: - Preset Chip

    private func presetChip(_ preset: DateRangeQuickPreset, isHighlighted: Bool = false) -> some View {
        Button(action: {
            applyQuickPreset(preset)
        }) {
            HStack(spacing: 0) {
                Text(preset.chipLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isHighlighted ? .white : .white.opacity(0.8))
            }
            .frame(minWidth: 34, minHeight: 24, alignment: .center)
            .padding(.horizontal, 10)
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
            hoveredQuickPreset = hovering ? preset : (hoveredQuickPreset == preset ? nil : hoveredQuickPreset)
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .instantTooltip(preset.helpText, isVisible: .constant(hoveredQuickPreset == preset))
    }

    // MARK: - Helpers

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private func setRangeInputFocus(_ target: DateRangeInputFocusTarget) {
        guard rangeInputFocusTarget != target else { return }
        rangeInputFocusTarget = target
    }

    private func focusTextInput(_ target: DateRangeInputFocusTarget) {
        if isCalendarVisible {
            withAnimation(.easeOut(duration: 0.15)) {
                isCalendarVisible = false
                activeCalendarBoundary = .start
            }
        }
        setRangeInputFocus(target)
    }

    private func handleRangeInputFocusEvent(_ event: DateRangeInputFocusEvent) {
        let resolvedTarget = DateRangeInputFocusResolver.resolve(
            current: rangeInputFocusTarget,
            event: event
        )
        guard resolvedTarget != rangeInputFocusTarget else { return }
        rangeInputFocusTarget = resolvedTarget
    }

    private func configureInitialState() {
        let now = Date()
        let fallbackStart = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let maxRangeCount = allowMultipleRanges ? 5 : 1
        let normalizedRanges = Array(dateRanges.filter(\.hasBounds).prefix(maxRangeCount))
        let primaryRange = normalizedRanges.first
        let primaryStart = primaryRange?.start ?? primaryRange?.end ?? fallbackStart
        let primaryEnd = primaryRange?.end ?? primaryRange?.start ?? now

        let normalizedPrimary = normalizeRange(primaryStart, primaryEnd)
        localStartDate = normalizedPrimary.start
        localEndDate = normalizedPrimary.end

        displayedMonth = localEndDate
        activeCalendarBoundary = .start
        isCalendarVisible = false
        parseError = nil

        if primaryRange != nil {
            rangeInputText = formatRangeInput(start: localStartDate, end: localEndDate)
            hasCommittedPrimaryRange = true
        } else {
            rangeInputText = ""
            hasCommittedPrimaryRange = false
        }

        let extras = allowMultipleRanges ? normalizedRanges.dropFirst() : []
        additionalRangeInputTexts = extras.map { formatRangeInputText(for: $0) }
        additionalRangeIDs = extras.map { _ in UUID() }
        additionalParseErrors = Array(repeating: nil, count: extras.count)
        additionalParsedRanges = Array(extras)
        normalizeAdditionalRangeState()
    }

    private func initialKeyboardFocusedItem(now: Date = Date()) -> Int {
        _ = now
        return primaryRangeFocusedItem
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

    private func resolvedCalendarTarget(_ target: CalendarTarget) -> CalendarTarget {
        switch target {
        case .primary:
            return .primary
        case .additional(let id):
            return additionalRangeIDs.contains(id) ? .additional(id) : .primary
        }
    }

    private func parsedRange(for target: CalendarTarget) -> (start: Date, end: Date)? {
        switch resolvedCalendarTarget(target) {
        case .primary:
            let trimmed = rangeInputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let parsed = parseDateRangeInput(trimmed) else { return nil }
            return parsed

        case .additional(let id):
            guard let index = additionalRangeIndex(for: id),
                  additionalRangeInputTexts.indices.contains(index) else { return nil }

            if additionalParsedRanges.indices.contains(index),
               let parsed = additionalParsedRanges[index],
               parsed.hasBounds,
               let start = parsed.start,
               let end = parsed.end {
                return (calendar.startOfDay(for: start), calendar.startOfDay(for: end))
            }

            let trimmed = additionalRangeInputTexts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let parsed = parseDateRangeInput(trimmed) else { return nil }
            return parsed
        }
    }

    private func synchronizeCalendarStateFromTarget(_ target: CalendarTarget) {
        let resolvedTarget = resolvedCalendarTarget(target)
        activeCalendarTarget = resolvedTarget

        let now = Date()
        let fallbackStart = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let requestedRange = parsedRange(for: resolvedTarget)
        let primaryRange = parsedRange(for: .primary)
        let sourceRange: (start: Date, end: Date)?
        switch resolvedTarget {
        case .primary:
            sourceRange = requestedRange ?? primaryRange
        case .additional:
            // Keep additional inputs independent: if empty/unparseable, do not inherit primary range.
            sourceRange = requestedRange
        }

        localStartDate = calendar.startOfDay(for: sourceRange?.start ?? fallbackStart)
        localEndDate = calendar.startOfDay(for: sourceRange?.end ?? now)
        if localEndDate < localStartDate {
            swap(&localStartDate, &localEndDate)
        }

        displayedMonth = localEndDate
        activeCalendarBoundary = .start
    }

    private func applyCalendarSelectionToActiveTarget(applyImmediately: Bool, moveToNextDropdown: Bool = false) {
        let normalizedRange = normalizeRange(localStartDate, localEndDate)
        localStartDate = normalizedRange.start
        localEndDate = normalizedRange.end
        if let validationError = rangeValidationError(start: localStartDate, end: localEndDate) {
            switch resolvedCalendarTarget(activeCalendarTarget) {
            case .primary:
                parseError = validationError
            case .additional(let id):
                if let index = additionalRangeIndex(for: id),
                   additionalParseErrors.indices.contains(index) {
                    additionalParseErrors[index] = validationError
                }
            }
            return
        }
        let formatted = formatRangeInput(start: localStartDate, end: localEndDate)

        switch resolvedCalendarTarget(activeCalendarTarget) {
        case .primary:
            rangeInputText = formatted
            parseError = nil
            if applyImmediately {
                let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: localEndDate) ?? localEndDate
                applyAllRanges(
                    primaryOverride: DateRangeCriterion(start: localStartDate, end: end),
                    moveToNextDropdown: moveToNextDropdown
                )
            }

        case .additional(let id):
            guard let index = additionalRangeIndex(for: id),
                  additionalRangeInputTexts.indices.contains(index),
                  additionalParseErrors.indices.contains(index),
                  additionalParsedRanges.indices.contains(index) else {
                return
            }
            additionalRangeInputTexts[index] = formatted
            additionalParseErrors[index] = nil
            additionalParsedRanges[index] = normalizedFilterRange(start: localStartDate, end: localEndDate)
            if applyImmediately {
                applyAllRanges(moveToNextDropdown: moveToNextDropdown)
            }
        }
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
            applyCalendarSelectionToActiveTarget(applyImmediately: true)
            return
        }

        applyCalendarSelectionToActiveTarget(applyImmediately: false)
    }

    @discardableResult
    private func applyInputTextToLocalRange(applyImmediately: Bool) -> Bool {
        let trimmed = rangeInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parseError = nil
            hasCommittedPrimaryRange = false
            return true
        }

        guard let parsedRange = parseDateRangeInput(trimmed) else {
            parseError = "Couldn’t parse that date range."
            return false
        }
        if let validationError = rangeValidationError(start: parsedRange.start, end: parsedRange.end) {
            parseError = validationError
            return false
        }

        localStartDate = parsedRange.start
        localEndDate = parsedRange.end
        displayedMonth = parsedRange.end
        rangeInputText = formatRangeInput(start: parsedRange.start, end: parsedRange.end)
        parseError = nil
        hasCommittedPrimaryRange = true
        activeCalendarBoundary = .start

        if applyImmediately {
            applyAllRanges(moveToNextDropdown: false)
        }

        return true
    }

    @discardableResult
    private func applyCurrentSelection(moveToNextDropdown: Bool = false) -> Bool {
        guard applyInputTextToLocalRange(applyImmediately: false) else {
            return false
        }
        applyAllRanges(moveToNextDropdown: moveToNextDropdown)
        return true
    }

    private func applyQuickPreset(_ preset: DateRangeQuickPreset) {
        let range = preset.resolvedRange(now: Date(), calendar: calendar)
        guard let start = range.start,
              let end = range.end else {
            return
        }

        localStartDate = calendar.startOfDay(for: start)
        localEndDate = calendar.startOfDay(for: end)
        displayedMonth = localEndDate
        activeCalendarBoundary = .start
        activeCalendarTarget = .primary
        lastFocusedCalendarTarget = .primary
        focusedItem = preset.focusedItemIndex
        rangeInputText = formatRangeInput(start: start, end: end)
        parseError = nil
        setRangeInputFocus(.none)

        applyAllRanges(primaryOverride: range, moveToNextDropdown: false)
    }

    private func addAdditionalRangeInput() {
        guard allowMultipleRanges else { return }
        guard additionalRangeInputTexts.count < 4 else { return }
        let newID = UUID()
        additionalRangeInputTexts.append("")
        additionalRangeIDs.append(newID)
        additionalParseErrors.append(nil)
        additionalParsedRanges.append(nil)
        normalizeAdditionalRangeState()
        DispatchQueue.main.async {
            setRangeInputFocus(.additional(newID))
        }
    }

    private func removeAdditionalRange(id: UUID) {
        guard allowMultipleRanges else { return }
        guard let index = additionalRangeIndex(for: id),
              additionalRangeInputTexts.indices.contains(index),
              additionalParseErrors.indices.contains(index),
              additionalParsedRanges.indices.contains(index) else {
            return
        }

        additionalRangeInputTexts.remove(at: index)
        additionalRangeIDs.remove(at: index)
        additionalParseErrors.remove(at: index)
        additionalParsedRanges.remove(at: index)
        normalizeAdditionalRangeState()
        if isCalendarVisible {
            synchronizeCalendarStateFromTarget(activeCalendarTarget)
        }
        applyAllRanges(moveToNextDropdown: false)
    }

    @discardableResult
    private func applyAdditionalRangeInput(
        for id: UUID,
        moveToNextDropdown: Bool = false
    ) -> Bool {
        guard allowMultipleRanges else { return false }
        guard let index = additionalRangeIndex(for: id),
              additionalRangeInputTexts.indices.contains(index),
              additionalParseErrors.indices.contains(index),
              additionalParsedRanges.indices.contains(index) else {
            return false
        }

        let trimmed = additionalRangeInputTexts[index].trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            additionalParsedRanges[index] = nil
            additionalParseErrors[index] = nil
            applyAllRanges(moveToNextDropdown: moveToNextDropdown)
            return true
        }

        guard let parsedRange = parseDateRangeInput(trimmed) else {
            additionalParseErrors[index] = "Couldn’t parse that date range."
            return false
        }
        if let validationError = rangeValidationError(start: parsedRange.start, end: parsedRange.end) {
            additionalParseErrors[index] = validationError
            return false
        }

        let normalizedRange = normalizedFilterRange(start: parsedRange.start, end: parsedRange.end)
        additionalParsedRanges[index] = normalizedRange
        additionalParseErrors[index] = nil
        additionalRangeInputTexts[index] = formatRangeInput(start: parsedRange.start, end: parsedRange.end)
        applyAllRanges(moveToNextDropdown: moveToNextDropdown)
        return true
    }

    private func applyAllRanges(
        primaryOverride: DateRangeCriterion? = nil,
        moveToNextDropdown: Bool
    ) {
        normalizeAdditionalRangeState()
        var collected: [DateRangeCriterion] = []

        if let primaryOverride {
            if let start = primaryOverride.start,
               let end = primaryOverride.end,
               let validationError = rangeValidationError(start: start, end: end) {
                parseError = validationError
                return
            }
            collected.append(primaryOverride)
            hasCommittedPrimaryRange = true
            if let start = primaryOverride.start, let end = primaryOverride.end {
                rangeInputText = formatRangeInput(start: start, end: end)
            }
            parseError = nil
        } else {
            let trimmedPrimary = rangeInputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPrimary.isEmpty {
                guard let parsedRange = parseDateRangeInput(trimmedPrimary) else {
                    parseError = "Couldn’t parse that date range."
                    return
                }
                if let validationError = rangeValidationError(start: parsedRange.start, end: parsedRange.end) {
                    parseError = validationError
                    return
                }
                rangeInputText = formatRangeInput(start: parsedRange.start, end: parsedRange.end)
                parseError = nil
                hasCommittedPrimaryRange = true
                collected.append(normalizedFilterRange(start: parsedRange.start, end: parsedRange.end))
            } else {
                parseError = nil
                hasCommittedPrimaryRange = false
            }
        }

        if allowMultipleRanges {
            for index in additionalRangeInputTexts.indices {
                guard additionalParseErrors.indices.contains(index),
                      additionalParsedRanges.indices.contains(index) else {
                    continue
                }

                let trimmed = additionalRangeInputTexts[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    additionalParsedRanges[index] = nil
                    additionalParseErrors[index] = nil
                    continue
                }

                if let parsedRange = parseDateRangeInput(trimmed) {
                    if let validationError = rangeValidationError(start: parsedRange.start, end: parsedRange.end) {
                        additionalParseErrors[index] = validationError
                        return
                    }
                    let normalizedRange = normalizedFilterRange(start: parsedRange.start, end: parsedRange.end)
                    additionalParsedRanges[index] = normalizedRange
                    additionalParseErrors[index] = nil
                    additionalRangeInputTexts[index] = formatRangeInput(start: parsedRange.start, end: parsedRange.end)
                    collected.append(normalizedRange)
                } else if let parsed = additionalParsedRanges[index], parsed.hasBounds {
                    collected.append(parsed)
                } else {
                    additionalParseErrors[index] = "Couldn’t parse that date range."
                    return
                }
            }
        }

        let maxRangeCount = allowMultipleRanges ? 5 : 1
        let limited = Array(collected.prefix(maxRangeCount))
        if limited.isEmpty {
            onClear()
        } else {
            onApply(limited)
        }

        if moveToNextDropdown {
            if let onMoveToNextFilter {
                onMoveToNextFilter()
            } else {
                onDismiss?()
            }
        }
    }

    private func additionalRangeIndex(for id: UUID) -> Int? {
        additionalRangeIDs.firstIndex(of: id)
    }

    private func additionalRangePlaceholder(for id: UUID) -> String {
        guard let index = additionalRangeIndex(for: id) else {
            return "Additional range"
        }
        return "Additional range #\(index + 2)"
    }

    private func additionalRangeBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                guard let index = additionalRangeIndex(for: id),
                      additionalRangeInputTexts.indices.contains(index) else { return "" }
                return additionalRangeInputTexts[index]
            },
            set: { newValue in
                guard let index = additionalRangeIndex(for: id),
                      additionalRangeInputTexts.indices.contains(index) else { return }
                additionalRangeInputTexts[index] = newValue
                if additionalParseErrors.indices.contains(index) {
                    additionalParseErrors[index] = nil
                }
            }
        )
    }

    private func additionalParseErrorMessage(for id: UUID) -> String? {
        guard let index = additionalRangeIndex(for: id),
              additionalParseErrors.indices.contains(index) else { return nil }
        return additionalParseErrors[index]
    }

    private func normalizeAdditionalRangeState() {
        let targetCount = additionalRangeInputTexts.count

        if additionalParseErrors.count < targetCount {
            additionalParseErrors.append(
                contentsOf: Array(repeating: nil, count: targetCount - additionalParseErrors.count)
            )
        } else if additionalParseErrors.count > targetCount {
            additionalParseErrors.removeLast(additionalParseErrors.count - targetCount)
        }

        if additionalParsedRanges.count < targetCount {
            additionalParsedRanges.append(
                contentsOf: Array(repeating: nil, count: targetCount - additionalParsedRanges.count)
            )
        } else if additionalParsedRanges.count > targetCount {
            additionalParsedRanges.removeLast(additionalParsedRanges.count - targetCount)
        }

        if additionalRangeIDs.count < targetCount {
            additionalRangeIDs.append(
                contentsOf: Array(repeating: (), count: targetCount - additionalRangeIDs.count).map { _ in UUID() }
            )
        } else if additionalRangeIDs.count > targetCount {
            additionalRangeIDs.removeLast(additionalRangeIDs.count - targetCount)
        }

        if let focusedID = focusedAdditionalRangeID,
           !additionalRangeIDs.contains(focusedID) {
            setRangeInputFocus(.none)
        }

        if let hoveredAdditionalRangeID,
           !additionalRangeIDs.contains(hoveredAdditionalRangeID) {
            self.hoveredAdditionalRangeID = nil
        }

        if case .additional(let id) = activeCalendarTarget,
           !additionalRangeIDs.contains(id) {
            activeCalendarTarget = .primary
        }

        if case .additional(let id) = lastFocusedCalendarTarget,
           !additionalRangeIDs.contains(id) {
            lastFocusedCalendarTarget = .primary
        }
    }

    private func normalizedFilterRange(start: Date, end: Date) -> DateRangeCriterion {
        let startDay = calendar.startOfDay(for: start)
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
        if endOfDay < startDay {
            let swappedStart = calendar.startOfDay(for: end)
            let swappedEnd = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: start) ?? start
            return DateRangeCriterion(start: swappedStart, end: swappedEnd)
        }
        return DateRangeCriterion(start: startDay, end: endOfDay)
    }

    private func formatRangeInput(start: Date, end: Date) -> String {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        let fullDateFormatter = DateFormatter()
        fullDateFormatter.dateFormat = "MMM d, yyyy"

        if calendar.isDate(startDay, inSameDayAs: endDay) {
            return fullDateFormatter.string(from: startDay)
        }

        return "\(fullDateFormatter.string(from: startDay)) to \(fullDateFormatter.string(from: endDay))"
    }

    private func formatRangeInputText(for range: DateRangeCriterion) -> String {
        let fullDateFormatter = DateFormatter()
        fullDateFormatter.dateFormat = "MMM d, yyyy"

        if let start = range.start, let end = range.end {
            return formatRangeInput(start: start, end: end)
        }
        if let start = range.start {
            return "From \(fullDateFormatter.string(from: start))"
        }
        if let end = range.end {
            return "Until \(fullDateFormatter.string(from: end))"
        }
        return ""
    }

    /// Normalize freeform user text to the canonical full-year display format without applying filters yet.
    private func canonicalizeInputTextIfPossible() {
        let trimmed = rangeInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let parsedRange = parseDateRangeInput(trimmed) else {
            return
        }

        localStartDate = parsedRange.start
        localEndDate = parsedRange.end
        displayedMonth = parsedRange.end
        rangeInputText = formatRangeInput(start: parsedRange.start, end: parsedRange.end)
        parseError = nil
        activeCalendarBoundary = .start
    }

    private func parseDateRangeInput(_ text: String) -> (start: Date, end: Date)? {
        inputParser.parse(text)
    }

    private func normalizeRange(_ start: Date, _ end: Date) -> (start: Date, end: Date) {
        var startDay = calendar.startOfDay(for: start)
        var endDay = calendar.startOfDay(for: end)
        if endDay < startDay {
            swap(&startDay, &endDay)
        }

        return (startDay, endDay)
    }

    private func rangeValidationError(start: Date, end: Date) -> String? {
        guard let maxRangeDays else { return nil }
        let normalized = normalizeRange(start, end)
        let daySpan = (calendar.dateComponents([.day], from: normalized.start, to: normalized.end).day ?? 0) + 1
        guard daySpan > maxRangeDays else { return nil }
        return "Date range must be \(maxRangeDays) days or less."
    }

    private func clearAllRangesAndDismiss() {
        rangeInputText = ""
        parseError = nil
        hasCommittedPrimaryRange = false
        additionalRangeInputTexts.removeAll()
        additionalRangeIDs.removeAll()
        additionalParseErrors.removeAll()
        additionalParsedRanges.removeAll()
        activeCalendarTarget = .primary
        lastFocusedCalendarTarget = .primary
        activeCalendarBoundary = .start
        isCalendarVisible = false
        setRangeInputFocus(.none)
        onClear()
        onDismiss?()
    }

    private func toggleCalendarVisibility() {
        withAnimation(.easeOut(duration: 0.15)) {
            isCalendarVisible.toggle()
            focusedItem = 0
            setRangeInputFocus(.none)
            if isCalendarVisible {
                synchronizeCalendarStateFromTarget(lastFocusedCalendarTarget)
            } else {
                activeCalendarBoundary = .start
            }
        }
    }

    private func addAnotherRangeAfterPrimarySubmitIfPossible() {
        let hasTypedPrimaryRange = !rangeInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard applyCurrentSelection(moveToNextDropdown: false) else { return }
        guard hasTypedPrimaryRange, canAddAnotherRange else { return }
        addAdditionalRangeInput()
    }

    private func addAnotherRangeAfterAdditionalSubmitIfPossible(for id: UUID) {
        guard let index = additionalRangeIndex(for: id),
              additionalRangeInputTexts.indices.contains(index) else {
            return
        }

        let hasTypedAdditionalRange = !additionalRangeInputTexts[index]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard applyAdditionalRangeInput(for: id, moveToNextDropdown: false) else { return }
        guard hasTypedAdditionalRange, canAddAnotherRange else { return }
        addAdditionalRangeInput()
    }

    // MARK: - Keyboard Navigation

    private func setupKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            switch event.keyCode {
            case 51 where modifiers == [.command], 117 where modifiers == [.command]: // Delete / Forward Delete
                guard isResetEnabled else { return event }
                onClearShortcut?()
                clearAllRangesAndDismiss()
                return nil

            case 53: // Escape
                if isAnyRangeInputFocused {
                    withAnimation(.easeOut(duration: 0.1)) {
                        focusedItem = primaryRangeFocusedItem
                    }
                    setRangeInputFocus(.none)
                    return nil
                }
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
                    if modifiers == [.shift] {
                        addAnotherRangeAfterPrimarySubmitIfPossible()
                    } else {
                        // Match Tab behavior: apply/clear from input, then advance to next filter.
                        _ = applyCurrentSelection(moveToNextDropdown: true)
                    }
                    return nil
                }
                if let additionalID = focusedAdditionalRangeID {
                    if modifiers == [.shift] {
                        addAnotherRangeAfterAdditionalSubmitIfPossible(for: additionalID)
                    } else {
                        _ = applyAdditionalRangeInput(for: additionalID, moveToNextDropdown: true)
                    }
                    return nil
                }

                if isCalendarVisible {
                    if activeCalendarBoundary == .start {
                        activeCalendarBoundary = .end
                    } else {
                        applyCalendarSelectionToActiveTarget(applyImmediately: true)
                    }
                    return nil
                }

                activateFocusedItem()
                return nil

            case 126: // Up arrow
                if isAnyRangeInputFocused {
                    withAnimation(.easeOut(duration: 0.1)) {
                        focusedItem = primaryRangeFocusedItem
                    }
                    setRangeInputFocus(.none)
                    return nil
                }
                if isCalendarVisible {
                    navigateCalendar(byDays: -7)
                } else {
                    moveFocusWithArrow(126)
                }
                return nil

            case 125: // Down arrow
                if isAnyRangeInputFocused {
                    withAnimation(.easeOut(duration: 0.1)) {
                        focusedItem = primaryRangeFocusedItem
                    }
                    setRangeInputFocus(.none)
                    return nil
                }
                if isCalendarVisible {
                    navigateCalendar(byDays: 7)
                } else {
                    moveFocusWithArrow(125)
                }
                return nil

            case 123: // Left arrow
                if isAnyRangeInputFocused && !isCalendarVisible { return event }
                if isCalendarVisible {
                    navigateCalendar(byDays: -1)
                } else {
                    moveFocusWithArrow(123)
                }
                return nil

            case 124: // Right arrow
                if isAnyRangeInputFocused && !isCalendarVisible { return event }
                if isCalendarVisible {
                    navigateCalendar(byDays: 1)
                } else {
                    moveFocusWithArrow(124)
                }
                return nil

            default:
                if let preset = DateRangeQuickPreset.preset(
                    for: event.charactersIgnoringModifiers,
                    modifiers: event.modifierFlags
                ), !isAnyRangeInputFocused {
                    onQuickPresetShortcut?(preset)
                    applyQuickPreset(preset)
                    return nil
                }
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
        case let item where item == primaryRangeFocusedItem:
            focusPrimaryRangeInput()
        case 0:
            withAnimation(.easeOut(duration: 0.15)) {
                isCalendarVisible.toggle()
                if isCalendarVisible {
                    synchronizeCalendarStateFromTarget(lastFocusedCalendarTarget)
                }
            }
        case let item where (1...4).contains(item):
            if let preset = DateRangeQuickPreset.allCases.first(where: { $0.focusedItemIndex == item }) {
                applyQuickPreset(preset)
            }
        default: break
        }
    }

    private func focusPrimaryRangeInput() {
        focusedItem = primaryRangeFocusedItem
        lastFocusedCalendarTarget = .primary
        setRangeInputFocus(.primary)
        if isCalendarVisible {
            synchronizeCalendarStateFromTarget(.primary)
        }
    }

    private func moveFocusedItem(by offset: Int) {
        withAnimation(.easeOut(duration: 0.1)) {
            focusedItem = max(0, min(itemCount - 1, focusedItem + offset))
            setRangeInputFocus(.none)
        }
    }

    private func moveFocusWithArrow(_ keyCode: UInt16) {
        withAnimation(.easeOut(duration: 0.1)) {
            switch keyCode {
            case 123: // Left
                if focusedItem == primaryRangeFocusedItem {
                    return
                }
                if (1...4).contains(focusedItem) {
                    focusedItem = max(1, focusedItem - 1)
                } else {
                    moveFocusedItem(by: -1)
                }

            case 124: // Right
                if focusedItem == primaryRangeFocusedItem {
                    focusedItem = 0
                    break
                }
                if (1...4).contains(focusedItem) {
                    focusedItem = min(4, focusedItem + 1)
                } else if focusedItem == 0 {
                    focusedItem = 1
                } else {
                    moveFocusedItem(by: 1)
                }

            case 125: // Down
                if focusedItem == primaryRangeFocusedItem {
                    focusedItem = 0
                    break
                }
                if focusedItem == 0 {
                    focusedItem = 1
                } else {
                    moveFocusedItem(by: 1)
                }

            case 126: // Up
                if focusedItem == primaryRangeFocusedItem {
                    return
                } else if focusedItem == 0 {
                    focusedItem = primaryRangeFocusedItem
                } else if (1...4).contains(focusedItem) {
                    focusedItem = 0
                } else {
                    setRangeInputFocus(.primary)
                    return
                }

            default:
                break
            }

            setRangeInputFocus(.none)
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

        applyCalendarSelectionToActiveTarget(applyImmediately: false)

        if !calendar.isDate(normalizedDate, equalTo: displayedMonth, toGranularity: .month) {
            withAnimation(.easeInOut(duration: 0.15)) {
                displayedMonth = normalizedDate
            }
        }
    }
}
