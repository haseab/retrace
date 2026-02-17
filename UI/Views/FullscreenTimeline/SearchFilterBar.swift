import SwiftUI
import Shared
import App
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

/// Filter bar for search overlay - displays filter chips below the search field
/// Styled similar to macOS Spotlight/Raycast with pill-shaped buttons
public struct SearchFilterBar: View {

    // MARK: - Properties

    @ObservedObject var viewModel: SearchViewModel
    @State private var showAppsDropdown = false
    @State private var showDatePopover = false
    @State private var showTagsDropdown = false
    @State private var showVisibilityDropdown = false
    @State private var showAdvancedDropdown = false
    @State private var showSearchOrderDropdown = false
    @State private var isClearFiltersHovered = false
    @State private var tabKeyMonitor: Any?

    /// Filter indices for Tab navigation: 1=Relevance/Newest/Oldest, 2=Apps, 3=Date, 4=Tags, 5=Visibility, 6=Advanced, 0=back to search
    private let filterCount = 6

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 10) {
            SearchOrderChip(
                selection: SearchOrderOption.from(
                    mode: viewModel.searchMode,
                    sortOrder: viewModel.sortOrder
                ),
                isOpen: showSearchOrderDropdown,
                action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showSearchOrderDropdown.toggle()
                        showAppsDropdown = false
                        showDatePopover = false
                        showTagsDropdown = false
                        showVisibilityDropdown = false
                        showAdvancedDropdown = false
                    }
                }
            )
            .dropdownOverlay(isPresented: $showSearchOrderDropdown, yOffset: 56) {
                SearchOrderPopover(
                    selection: SearchOrderOption.from(
                        mode: viewModel.searchMode,
                        sortOrder: viewModel.sortOrder
                    ),
                    onSelect: { option in
                        switch option {
                        case .relevance:
                            viewModel.setSearchModeAndSort(mode: .relevant, sortOrder: nil)
                        case .newest:
                            viewModel.setSearchModeAndSort(mode: .all, sortOrder: .newestFirst)
                        case .oldest:
                            viewModel.setSearchModeAndSort(mode: .all, sortOrder: .oldestFirst)
                        }
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showSearchOrderDropdown = false
                        }
                    }
                )
            }

            Divider()
                .frame(height: 28)
                .background(Color.white.opacity(0.2))

            // Apps filter (multi-select) - shows app icons when selected
            AppsFilterChip(
                selectedApps: viewModel.selectedAppFilters,
                filterMode: viewModel.appFilterMode,
                isActive: viewModel.selectedAppFilters != nil && !viewModel.selectedAppFilters!.isEmpty,
                isOpen: showAppsDropdown,
                action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showAppsDropdown.toggle()
                        showDatePopover = false
                        showTagsDropdown = false
                        showVisibilityDropdown = false
                        showAdvancedDropdown = false
                    }
                }
            )
            .dropdownOverlay(isPresented: $showAppsDropdown, yOffset: 56) {
                AppsFilterPopover(
                    apps: viewModel.installedApps.map { ($0.bundleID, $0.name) },
                    otherApps: viewModel.otherApps.map { ($0.bundleID, $0.name) },
                    selectedApps: viewModel.selectedAppFilters,
                    filterMode: viewModel.appFilterMode,
                    allowMultiSelect: true,
                    onSelectApp: { bundleID in
                        viewModel.toggleAppFilter(bundleID)
                    },
                    onFilterModeChange: { mode in
                        viewModel.setAppFilterMode(mode)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showAppsDropdown = false
                        }
                    }
                )
            }

            // Date filter
            FilterChip(
                icon: "calendar",
                label: dateFilterLabel,
                isActive: viewModel.startDate != nil || viewModel.endDate != nil,
                isOpen: showDatePopover,
                showChevron: true
            ) {
                withAnimation(.easeOut(duration: 0.15)) {
                    showDatePopover.toggle()
                    showAppsDropdown = false
                    showTagsDropdown = false
                    showVisibilityDropdown = false
                    showAdvancedDropdown = false
                }
            }
            .dropdownOverlay(isPresented: $showDatePopover, yOffset: 56) {
                DateRangeFilterPopover(
                    startDate: viewModel.startDate,
                    endDate: viewModel.endDate,
                    onApply: { start, end in
                        viewModel.setDateRange(start: start, end: end)
                    },
                    onClear: {
                        viewModel.setDateRange(start: nil, end: nil)
                    },
                    width: 300,
                    enableKeyboardNavigation: true,
                    onMoveToNextFilter: {
                        // Tab order: Relevance -> Apps -> Date -> Tags -> Visibility -> Advanced.
                        // Enter from Date input should advance to Tags, matching Tab behavior.
                        viewModel.openFilterSignal = (4, UUID())
                    },
                    onCalendarEditingChange: { isEditing in
                        viewModel.isDatePopoverHandlingKeys = isEditing
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showDatePopover = false
                        }
                        viewModel.isDatePopoverHandlingKeys = false
                    }
                )
            }

            // Tags filter
            TagsFilterChip(
                selectedTags: viewModel.selectedTags,
                availableTags: viewModel.availableTags,
                filterMode: viewModel.tagFilterMode,
                isActive: viewModel.selectedTags != nil && !viewModel.selectedTags!.isEmpty,
                isOpen: showTagsDropdown,
                action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showTagsDropdown.toggle()
                        showAppsDropdown = false
                        showDatePopover = false
                        showVisibilityDropdown = false
                        showAdvancedDropdown = false
                    }
                }
            )
            .dropdownOverlay(isPresented: $showTagsDropdown, yOffset: 56) {
                TagsFilterPopover(
                    tags: viewModel.availableTags,
                    selectedTags: viewModel.selectedTags,
                    filterMode: viewModel.tagFilterMode,
                    allowMultiSelect: true,
                    onSelectTag: { tagId in
                        viewModel.toggleTagFilter(tagId)
                    },
                    onFilterModeChange: { mode in
                        viewModel.setTagFilterMode(mode)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showTagsDropdown = false
                        }
                    }
                )
            }

            // Visibility filter
            VisibilityFilterChip(
                currentFilter: viewModel.hiddenFilter,
                isActive: viewModel.hiddenFilter != .hide,
                isOpen: showVisibilityDropdown,
                action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showVisibilityDropdown.toggle()
                        showAppsDropdown = false
                        showDatePopover = false
                        showTagsDropdown = false
                        showAdvancedDropdown = false
                    }
                }
            )
            .dropdownOverlay(isPresented: $showVisibilityDropdown, yOffset: 56) {
                VisibilityFilterPopover(
                    currentFilter: viewModel.hiddenFilter,
                    onSelect: { filter in
                        viewModel.setHiddenFilter(filter)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showVisibilityDropdown = false
                        }
                    }
                )
            }

            // Advanced metadata filters (window name + browser URL)
            FilterChip(
                icon: "slider.horizontal.3",
                label: "Advanced",
                isActive: hasActiveAdvancedFilters,
                isOpen: showAdvancedDropdown,
                showChevron: true
            ) {
                withAnimation(.easeOut(duration: 0.15)) {
                    showAdvancedDropdown.toggle()
                    showAppsDropdown = false
                    showDatePopover = false
                    showTagsDropdown = false
                    showVisibilityDropdown = false
                }
            }
            .dropdownOverlay(isPresented: $showAdvancedDropdown, yOffset: 56) {
                AdvancedSearchFilterPopover(
                    windowNameFilter: $viewModel.windowNameFilter,
                    browserUrlFilter: $viewModel.browserUrlFilter
                )
            }

            Spacer()

            // Clear all filters button (only shown when filters are active)
            if viewModel.hasActiveFilters {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.clearAllFilters()
                    }
                    // Re-run search with cleared filters
                    if !viewModel.searchQuery.isEmpty {
                        viewModel.submitSearch()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.retraceTinyBold)
                        Text("Clear")
                            .font(.retraceCaption2Medium)
                    }
                    .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isClearFiltersHovered ? RetraceMenuStyle.filterStrokeStrong : Color.clear,
                            lineWidth: 1.2
                        )
                )
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.1)) {
                        isClearFiltersHovered = hovering
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .task {
            // Delay loading until after animation completes to avoid choppy animation
            try? await Task.sleep(for: .nanoseconds(Int64(200_000_000)), clock: .continuous) // 200ms
            await viewModel.loadAvailableTags()
        }
        .onChange(of: showAppsDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSearchOrderDropdown
            // Lazy load apps only when dropdown is opened
            if isOpen {
                viewModel.openFilterSignal = (2, UUID())
                Task {
                    await viewModel.loadAvailableApps()
                }
            }
        }
        .onChange(of: showDatePopover) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if !isOpen {
                viewModel.isDatePopoverHandlingKeys = false
            }
            if isOpen {
                viewModel.openFilterSignal = (3, UUID())
            }
        }
        .onChange(of: showTagsDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                viewModel.openFilterSignal = (4, UUID())
            }
        }
        .onChange(of: showVisibilityDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                viewModel.openFilterSignal = (5, UUID())
            }
        }
        .onChange(of: showAdvancedDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                viewModel.openFilterSignal = (6, UUID())
            }
        }
        .onChange(of: showSearchOrderDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSearchOrderDropdown
        }
        .onChange(of: viewModel.closeDropdownsSignal) { newValue in
            // Close all dropdowns when signal is received (from Escape key in parent)
            withAnimation(.easeOut(duration: 0.15)) {
                showAppsDropdown = false
                showDatePopover = false
                showTagsDropdown = false
                showVisibilityDropdown = false
                showAdvancedDropdown = false
                showSearchOrderDropdown = false
            }
        }
        .onChange(of: viewModel.openFilterSignal.id) { _ in
            let filterIndex = viewModel.openFilterSignal.index
            openFilterAtIndex(filterIndex)
        }
        .onAppear {
            setupTabKeyMonitor()
        }
        .onDisappear {
            removeTabKeyMonitor()
        }
    }

    // MARK: - Tab Key Navigation

    /// Open a specific filter dropdown by index
    private func openFilterAtIndex(_ index: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            // Close all first
            showAppsDropdown = false
            showDatePopover = false
            showTagsDropdown = false
            showVisibilityDropdown = false
            showAdvancedDropdown = false
            showSearchOrderDropdown = false

            // Open the requested one
            switch index {
            case 1:
                showSearchOrderDropdown = true
            case 2:
                showAppsDropdown = true
                // Lazy load apps when opening via Tab
                Task {
                    await viewModel.loadAvailableApps()
                }
            case 3:
                showDatePopover = true
            case 4:
                showTagsDropdown = true
            case 5:
                showVisibilityDropdown = true
            case 6:
                showAdvancedDropdown = true
            default:
                // Index 0 means focus search field - parent will handle via onChange
                break
            }
        }
    }

    /// Get the current open filter index (0 if none open)
    private func currentOpenFilterIndex() -> Int {
        if showAppsDropdown { return 1 }
        if showDatePopover { return 2 }
        if showTagsDropdown { return 3 }
        if showVisibilityDropdown { return 4 }
        if showAdvancedDropdown { return 5 }
        return 0
    }

    /// Set up Tab key monitor for cycling through filters
    private func setupTabKeyMonitor() {
        // Capture viewModel reference for the closure
        let vm = viewModel
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only handle Tab key (keycode 48)
            guard event.keyCode == 48 else { return event }

            // Check which dropdown is currently open via viewModel's isDropdownOpen
            guard vm.isDropdownOpen else { return event }

            // Check if Shift is held for reverse direction
            let isShiftHeld = event.modifierFlags.contains(.shift)

            // Determine current filter by checking the signal's last index
            // Filter indices: 0=Search, 1=Relevance/Newest/Oldest, 2=Apps, 3=Date, 4=Tags, 5=Visibility, 6=Advanced
            let lastSignal = vm.openFilterSignal.index
            let currentIndex = lastSignal > 0 ? lastSignal : 1  // Start from 1 if coming from search


            // Calculate next index based on direction
            let nextIndex: Int
            if isShiftHeld {
                // Shift+Tab: go backward (cycle: 0 -> 6 -> 5 -> 4 -> 3 -> 2 -> 1 -> 0)
                nextIndex = currentIndex <= 0 ? filterCount : currentIndex - 1
            } else {
                // Tab: go forward (cycle: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 0 -> 1)
                nextIndex = currentIndex >= filterCount ? 0 : currentIndex + 1
            }

            // Signal the change - the onChange handler will open the appropriate dropdown
            vm.openFilterSignal = (nextIndex, UUID())

            return nil // Consume the event
        }
    }

    /// Remove Tab key monitor
    private func removeTabKeyMonitor() {
        if let monitor = tabKeyMonitor {
            NSEvent.removeMonitor(monitor)
            tabKeyMonitor = nil
        }
    }

    // MARK: - Computed Properties

    private var dateFilterLabel: String {
        if let start = viewModel.startDate, let end = viewModel.endDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
        } else if let start = viewModel.startDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return "From \(formatter.string(from: start))"
        } else if let end = viewModel.endDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return "Until \(formatter.string(from: end))"
        }
        return "Date"
    }

    private var hasActiveAdvancedFilters: Bool {
        (viewModel.windowNameFilter?.isEmpty == false) || (viewModel.browserUrlFilter?.isEmpty == false)
    }
}

// MARK: - Filter Chip Button

private struct FilterChip: View {
    let icon: String
    let label: String
    let isActive: Bool
    let isOpen: Bool
    let showChevron: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: {
            action()
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))

                Text(label)
                    .font(.retraceCalloutMedium)
                    .lineLimit(1)

                if showChevron {
                    Image(systemName: "chevron.down")
                        .font(.retraceCaption2)
                }
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        (isHovered || isOpen)
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive ? RetraceMenuStyle.filterStrokeMedium : Color.clear),
                        lineWidth: (isHovered || isOpen) ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Apps Filter Chip (shows app icons)

private struct AppsFilterChip: View {
    let selectedApps: Set<String>?
    let filterMode: AppFilterMode
    let isActive: Bool
    let isOpen: Bool
    let action: () -> Void

    @StateObject private var appMetadata = AppMetadataCache.shared
    @State private var isHovered = false

    private let maxVisibleIcons = 5
    private let iconSize: CGFloat = 20

    private var sortedApps: [String] {
        guard let apps = selectedApps else { return [] }
        return apps.sorted()
    }

    private var isExcludeMode: Bool {
        filterMode == .exclude && isActive
    }

    var body: some View {
        Button(action: {
            action()
        }) {
            HStack(spacing: 6) {
                // Show exclude indicator
                if isExcludeMode {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .transition(.scale.combined(with: .opacity))
                }

                if sortedApps.count == 1 {
                    // Single app: show icon + name
                    let bundleID = sortedApps[0]
                    appIcon(for: bundleID)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .transition(.scale.combined(with: .opacity))

                    Text(appName(for: bundleID))
                        .font(.retraceCaptionMedium)
                        .lineLimit(1)
                        .strikethrough(isExcludeMode, color: .orange)
                        .transition(.opacity)
                } else if sortedApps.count > 1 {
                    // Multiple apps: show icons
                    HStack(spacing: -4) {
                        ForEach(Array(sortedApps.prefix(maxVisibleIcons)), id: \.self) { bundleID in
                            appIcon(for: bundleID)
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .opacity(isExcludeMode ? 0.6 : 1.0)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                    // Show "+X" if more than maxVisibleIcons
                    if sortedApps.count > maxVisibleIcons {
                        Text("+\(sortedApps.count - maxVisibleIcons)")
                            .font(.retraceTinyBold)
                            .foregroundColor(.white.opacity(0.8))
                            .transition(.scale.combined(with: .opacity))
                    }
                } else {
                    // Default state - no apps selected
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 14))
                        .transition(.scale.combined(with: .opacity))
                    Text("Apps")
                        .font(.retraceCalloutMedium)
                        .transition(.opacity)
                }

                Image(systemName: "chevron.down")
                    .font(.retraceCaption2)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: sortedApps)
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        (isHovered || isOpen)
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive ? RetraceMenuStyle.filterStrokeMedium : Color.clear),
                        lineWidth: (isHovered || isOpen) ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .onAppear {
            appMetadata.prefetch(bundleIDs: sortedApps)
        }
        .onChange(of: sortedApps) { bundleIDs in
            appMetadata.prefetch(bundleIDs: bundleIDs)
        }
    }

    private func appIcon(for bundleID: String) -> some View {
        AppIconView(bundleID: bundleID, size: iconSize)
    }

    private func appName(for bundleID: String) -> String {
        appMetadata.name(for: bundleID) ?? fallbackName(for: bundleID)
    }

    private func fallbackName(for bundleID: String) -> String {
        bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

// MARK: - Search Order Dropdown

private enum SearchOrderOption: CaseIterable {
    case relevance
    case newest
    case oldest

    var icon: String {
        switch self {
        case .relevance: return "arrow.up.arrow.down"
        case .newest: return "arrow.down"
        case .oldest: return "arrow.up"
        }
    }

    var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        }
    }

    var subtitle: String {
        switch self {
        case .relevance: return "Best semantic match"
        case .newest: return "Most recent results first"
        case .oldest: return "Oldest results first"
        }
    }

    static func from(mode: SearchMode, sortOrder: SearchSortOrder) -> SearchOrderOption {
        if mode == .relevant {
            return .relevance
        }
        return sortOrder == .oldestFirst ? .oldest : .newest
    }
}

// MARK: - Tags Filter Chip

private struct TagsFilterChip: View {
    let selectedTags: Set<Int64>?
    let availableTags: [Tag]
    let filterMode: TagFilterMode
    let isActive: Bool
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var selectedTagCount: Int {
        selectedTags?.count ?? 0
    }

    private var isExcludeMode: Bool {
        filterMode == .exclude && isActive
    }

    private var label: String {
        if selectedTagCount == 0 {
            return "Tags"
        } else if selectedTagCount == 1, let tagId = selectedTags?.first,
                  let tag = availableTags.first(where: { $0.id.value == tagId }) {
            return tag.name
        } else {
            return "\(selectedTagCount) Tags"
        }
    }

    var body: some View {
        Button(action: {
            action()
        }) {
            HStack(spacing: 6) {
                // Show exclude indicator
                if isExcludeMode {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .transition(.scale.combined(with: .opacity))
                }

                Image(systemName: isActive ? "tag.fill" : "tag")
                    .font(.system(size: 14))

                Text(label)
                    .font(.retraceCalloutMedium)
                    .lineLimit(1)
                    .strikethrough(isExcludeMode, color: .orange)

                Image(systemName: "chevron.down")
                    .font(.retraceCaption2)
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        (isHovered || isOpen)
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive ? RetraceMenuStyle.filterStrokeMedium : Color.clear),
                        lineWidth: (isHovered || isOpen) ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Visibility Filter Chip

private struct VisibilityFilterChip: View {
    let currentFilter: HiddenFilter
    let isActive: Bool
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var icon: String {
        switch currentFilter {
        case .hide: return "eye"
        case .onlyHidden: return "eye.slash"
        case .showAll: return "eye.circle"
        }
    }

    private var label: String {
        switch currentFilter {
        case .hide: return "Visible"
        case .onlyHidden: return "Hidden"
        case .showAll: return "All"
        }
    }

    var body: some View {
        Button(action: {
            action()
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))

                Text(label)
                    .font(.retraceCalloutMedium)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.retraceCaption2)
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        (isHovered || isOpen)
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive ? RetraceMenuStyle.filterStrokeMedium : Color.clear),
                        lineWidth: (isHovered || isOpen) ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

private struct SearchOrderChip: View {
    let selection: SearchOrderOption
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selection.icon)
                    .font(.system(size: 14))

                Text(selection.title)
                    .font(.retraceCalloutMedium)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.retraceCaption2)
            }
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        (isHovered || isOpen) ? RetraceMenuStyle.filterStrokeStrong : Color.clear,
                        lineWidth: (isHovered || isOpen) ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

private struct SearchOrderPopover: View {
    let selection: SearchOrderOption
    let onSelect: (SearchOrderOption) -> Void
    var onDismiss: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var highlightedIndex: Int = 0

    private let options: [SearchOrderOption] = SearchOrderOption.allCases

    private func selectHighlightedItem() {
        guard highlightedIndex >= 0, highlightedIndex < options.count else { return }
        onSelect(options[highlightedIndex])
        onDismiss?()
    }

    private func moveHighlight(by offset: Int) {
        highlightedIndex = max(0, min(options.count - 1, highlightedIndex + offset))
    }

    var body: some View {
        FilterPopoverContainer(width: 200) {
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    if index > 0 {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    FilterRow(
                        systemIcon: option.icon,
                        title: option.title,
                        subtitle: option.subtitle,
                        isSelected: selection == option,
                        isKeyboardHighlighted: highlightedIndex == index
                    ) {
                        onSelect(option)
                        onDismiss?()
                    }
                    .id(index)
                }
            }
            .padding(.vertical, 8)
        }
        .focused($isFocused)
        .onAppear {
            // Set initial highlight to current selection
            highlightedIndex = options.firstIndex(of: selection) ?? 0
            isFocused = true
        }
        .keyboardNavigation(
            onUpArrow: { moveHighlight(by: -1) },
            onDownArrow: { moveHighlight(by: 1) },
            onReturn: { selectHighlightedItem() }
        )
    }
}
