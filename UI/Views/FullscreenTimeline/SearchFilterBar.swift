import SwiftUI
import Shared
import App
import AppKit

private enum SpotlightFilterChipMetrics {
    static let dropdownYOffset: CGFloat = 44
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
    @State private var showCommentDropdown = false
    @State private var showAdvancedDropdown = false
    @State private var showSearchOrderDropdown = false
    @State private var isClearFiltersHovered = false
    @State private var tabKeyMonitor: Any?

    /// Filter indices for Tab navigation: 1=Order, 2=Apps, 3=Date, 4=Tags, 5=Visibility, 6=Comments, 7=Advanced, 0=back to search
    private let filterCount = 7

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 8) {
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
                        showCommentDropdown = false
                        showAdvancedDropdown = false
                    }
                }
            )
            .dropdownOverlay(isPresented: $showSearchOrderDropdown, yOffset: SpotlightFilterChipMetrics.dropdownYOffset) {
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
                .frame(height: 21)
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
                        showCommentDropdown = false
                        showAdvancedDropdown = false
                    }
                }
            )
            .dropdownOverlay(isPresented: $showAppsDropdown, yOffset: SpotlightFilterChipMetrics.dropdownYOffset) {
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
                    showCommentDropdown = false
                    showAdvancedDropdown = false
                }
            }
            .dropdownOverlay(isPresented: $showDatePopover, yOffset: SpotlightFilterChipMetrics.dropdownYOffset) {
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
                        // Tab order: Order -> Apps -> Date -> Tags -> Visibility -> Comments -> Advanced.
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
                        showCommentDropdown = false
                        showAdvancedDropdown = false
                    }
                }
            )
            .dropdownOverlay(isPresented: $showTagsDropdown, yOffset: SpotlightFilterChipMetrics.dropdownYOffset) {
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
                        showCommentDropdown = false
                        showAdvancedDropdown = false
                    }
                }
            )
            .dropdownOverlay(isPresented: $showVisibilityDropdown, yOffset: SpotlightFilterChipMetrics.dropdownYOffset) {
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

            // Comment presence filter
            CommentFilterChip(
                currentFilter: viewModel.commentFilter,
                isActive: viewModel.commentFilter != .allFrames,
                isOpen: showCommentDropdown,
                action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showCommentDropdown.toggle()
                        showAppsDropdown = false
                        showDatePopover = false
                        showTagsDropdown = false
                        showVisibilityDropdown = false
                        showAdvancedDropdown = false
                    }
                }
            )
            .dropdownOverlay(isPresented: $showCommentDropdown, yOffset: SpotlightFilterChipMetrics.dropdownYOffset) {
                CommentFilterPopover(
                    currentFilter: viewModel.commentFilter,
                    onSelect: { filter in
                        viewModel.setCommentFilter(filter)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showCommentDropdown = false
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
                    showCommentDropdown = false
                }
            }
            .dropdownOverlay(isPresented: $showAdvancedDropdown, yOffset: SpotlightFilterChipMetrics.dropdownYOffset) {
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
                    HStack(spacing: 3) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Clear")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
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
        .padding(.horizontal, 15)
        // Shift chips slightly upward: more top inset, less bottom inset.
        .padding(.top, 10)
        .padding(.bottom, 4)
        .task {
            // Delay loading until after animation completes to avoid choppy animation
            try? await Task.sleep(for: .nanoseconds(Int64(200_000_000)), clock: .continuous) // 200ms
            await viewModel.loadAvailableTags()
        }
        .onChange(of: showAppsDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            // Lazy load apps only when dropdown is opened
            if isOpen {
                viewModel.openFilterSignal = (2, UUID())
                Task {
                    await viewModel.loadAvailableApps()
                }
            }
        }
        .onChange(of: showDatePopover) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if !isOpen {
                viewModel.isDatePopoverHandlingKeys = false
            }
            if isOpen {
                viewModel.openFilterSignal = (3, UUID())
            }
        }
        .onChange(of: showTagsDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                viewModel.openFilterSignal = (4, UUID())
            }
        }
        .onChange(of: showVisibilityDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                viewModel.openFilterSignal = (5, UUID())
            }
        }
        .onChange(of: showCommentDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                viewModel.openFilterSignal = (6, UUID())
            }
        }
        .onChange(of: showAdvancedDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                viewModel.openFilterSignal = (7, UUID())
            }
        }
        .onChange(of: showSearchOrderDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
        }
        .onChange(of: viewModel.closeDropdownsSignal) { newValue in
            // Close all dropdowns when signal is received (from Escape key in parent)
            withAnimation(.easeOut(duration: 0.15)) {
                showAppsDropdown = false
                showDatePopover = false
                showTagsDropdown = false
                showVisibilityDropdown = false
                showCommentDropdown = false
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
            showCommentDropdown = false
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
                showCommentDropdown = true
            case 7:
                showAdvancedDropdown = true
            default:
                // Index 0 means focus search field - parent will handle via onChange
                break
            }
        }
    }

    /// Get the current open filter index (0 if none open)
    private func currentOpenFilterIndex() -> Int {
        if showSearchOrderDropdown { return 1 }
        if showAppsDropdown { return 2 }
        if showDatePopover { return 3 }
        if showTagsDropdown { return 4 }
        if showVisibilityDropdown { return 5 }
        if showCommentDropdown { return 6 }
        if showAdvancedDropdown { return 7 }
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
            // Filter indices: 0=Search, 1=Order, 2=Apps, 3=Date, 4=Tags, 5=Visibility, 6=Comments, 7=Advanced
            let lastSignal = vm.openFilterSignal.index
            let currentIndex = lastSignal > 0 ? lastSignal : 1  // Start from 1 if coming from search


            // Calculate next index based on direction
            let nextIndex: Int
            if isShiftHeld {
                // Shift+Tab: go backward (cycle: 0 -> 7 -> ... -> 1 -> 0)
                nextIndex = currentIndex <= 0 ? filterCount : currentIndex - 1
            } else {
                // Tab: go forward (cycle: 1 -> 2 -> ... -> 7 -> 0 -> 1)
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
            HStack(spacing: 4.5) {
                Image(systemName: icon)
                    .font(.system(size: 11))

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if showChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive
                                ? RetraceMenuStyle.filterStrokeMedium
                                : (isHovered ? Color.white.opacity(0.65) : Color.clear)),
                        lineWidth: (isOpen || isHovered) ? 1.2 : 1
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
    private let iconSize: CGFloat = 15

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
            HStack(spacing: 4.5) {
                // Show exclude indicator
                if isExcludeMode {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 9))
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
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .strikethrough(isExcludeMode, color: .orange)
                        .transition(.opacity)
                } else if sortedApps.count > 1 {
                    // Multiple apps: show icons
                    HStack(spacing: -3) {
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
                        .font(.system(size: 11))
                        .transition(.scale.combined(with: .opacity))
                    Text("Apps")
                        .font(.system(size: 11, weight: .medium))
                        .transition(.opacity)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: sortedApps)
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive
                                ? RetraceMenuStyle.filterStrokeMedium
                                : (isHovered ? Color.white.opacity(0.65) : Color.clear)),
                        lineWidth: (isOpen || isHovered) ? 1.2 : 1
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
            HStack(spacing: 4.5) {
                // Show exclude indicator
                if isExcludeMode {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .transition(.scale.combined(with: .opacity))
                }

                Image(systemName: isActive ? "tag.fill" : "tag")
                    .font(.system(size: 11))

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(isExcludeMode, color: .orange)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive
                                ? RetraceMenuStyle.filterStrokeMedium
                                : (isHovered ? Color.white.opacity(0.65) : Color.clear)),
                        lineWidth: (isOpen || isHovered) ? 1.2 : 1
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
            HStack(spacing: 4.5) {
                Image(systemName: icon)
                    .font(.system(size: 11))

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive
                                ? RetraceMenuStyle.filterStrokeMedium
                                : (isHovered ? Color.white.opacity(0.65) : Color.clear)),
                        lineWidth: (isOpen || isHovered) ? 1.2 : 1
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

// MARK: - Comment Filter Chip

private struct CommentFilterChip: View {
    let currentFilter: CommentFilter
    let isActive: Bool
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var icon: String {
        switch currentFilter {
        case .allFrames: return "text.bubble"
        case .commentsOnly: return "text.bubble.fill"
        case .noComments: return "text.bubble.slash"
        }
    }

    private var label: String {
        switch currentFilter {
        case .allFrames: return "All"
        case .commentsOnly: return "Comments"
        case .noComments: return "No Comments"
        }
    }

    var body: some View {
        Button(action: {
            action()
        }) {
            HStack(spacing: 4.5) {
                Image(systemName: icon)
                    .font(.system(size: 11))

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive
                                ? RetraceMenuStyle.filterStrokeMedium
                                : (isHovered ? Color.white.opacity(0.65) : Color.clear)),
                        lineWidth: (isOpen || isHovered) ? 1.2 : 1
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
        let isHighlighted = isHovered || isOpen

        Button(action: action) {
            HStack(spacing: 4.5) {
                Image(systemName: selection.icon)
                    .font(.system(size: 11))

                Text(selection.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(isHighlighted ? 0.22 : 0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isHovered ? Color.white.opacity(0.65) : RetraceMenuStyle.filterStrokeMedium),
                        lineWidth: 1.2
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
