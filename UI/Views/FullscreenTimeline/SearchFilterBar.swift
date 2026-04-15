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
    @State private var datePopoverFocusRequestID: UUID?
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
            .dropdownOverlay(
                isPresented: $showSearchOrderDropdown,
                yOffset: SpotlightFilterChipMetrics.dropdownYOffset,
                dismissOnOutsideClick: false
            ) {
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
            .dropdownOverlay(
                isPresented: $showAppsDropdown,
                yOffset: SpotlightFilterChipMetrics.dropdownYOffset,
                dismissOnOutsideClick: false
            ) {
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
                isActive: !viewModel.effectiveDateRanges.isEmpty,
                isOpen: showDatePopover,
                showChevron: true
            ) {
                withAnimation(.easeOut(duration: 0.15)) {
                    let willOpen = !showDatePopover
                    if willOpen {
                        datePopoverFocusRequestID = UUID()
                    }
                    showDatePopover = willOpen
                    showAppsDropdown = false
                    showTagsDropdown = false
                    showVisibilityDropdown = false
                    showCommentDropdown = false
                    showAdvancedDropdown = false
                }
            }
            .dropdownOverlay(
                isPresented: $showDatePopover,
                yOffset: SpotlightFilterChipMetrics.dropdownYOffset,
                dismissOnOutsideClick: false
            ) {
                DateRangeFilterPopover(
                    dateRanges: viewModel.effectiveDateRanges,
                    onApply: { ranges in
                        viewModel.setDateRanges(ranges)
                    },
                    onClear: {
                        viewModel.setDateRanges([])
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
                    onQuickPresetShortcut: { preset in
                        viewModel.recordKeyboardShortcut("search.date_range.\(preset.rawValue)")
                    },
                    onClearShortcut: {
                        viewModel.recordKeyboardShortcut("search.date_range.clear")
                    },
                    focusPrimaryInputRequestID: datePopoverFocusRequestID,
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
            .dropdownOverlay(
                isPresented: $showTagsDropdown,
                yOffset: SpotlightFilterChipMetrics.dropdownYOffset,
                dismissOnOutsideClick: false
            ) {
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
            .dropdownOverlay(
                isPresented: $showVisibilityDropdown,
                yOffset: SpotlightFilterChipMetrics.dropdownYOffset,
                dismissOnOutsideClick: false
            ) {
                VisibilityFilterPopover(
                    currentFilter: viewModel.hiddenFilter,
                    onSelect: { filter in
                        viewModel.setHiddenFilter(filter)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showVisibilityDropdown = false
                        }
                    },
                    onKeyboardSelect: {
                        // Keep Enter behavior aligned with Tab order:
                        // Visibility -> Comments.
                        viewModel.openFilterSignal = (6, UUID())
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
            .dropdownOverlay(
                isPresented: $showCommentDropdown,
                yOffset: SpotlightFilterChipMetrics.dropdownYOffset,
                dismissOnOutsideClick: false
            ) {
                CommentFilterPopover(
                    currentFilter: viewModel.commentFilter,
                    onSelect: { filter in
                        viewModel.setCommentFilter(filter)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showCommentDropdown = false
                        }
                    },
                    onKeyboardSelect: {
                        // Keep Enter behavior aligned with Tab order:
                        // Comments -> Advanced.
                        viewModel.openFilterSignal = (7, UUID())
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
            .dropdownOverlay(
                isPresented: $showAdvancedDropdown,
                yOffset: SpotlightFilterChipMetrics.dropdownYOffset,
                dismissOnOutsideClick: false
            ) {
                AdvancedSearchFilterPopover(
                    windowNameIncludeTerms: $viewModel.windowNameTerms,
                    windowNameExcludeTerms: $viewModel.windowNameExcludedTerms,
                    windowNameFilterMode: $viewModel.windowNameFilterMode,
                    browserUrlIncludeTerms: $viewModel.browserUrlTerms,
                    browserUrlExcludeTerms: $viewModel.browserUrlExcludedTerms,
                    browserUrlFilterMode: $viewModel.browserUrlFilterMode,
                    excludedSearchTerms: $viewModel.excludedSearchTerms
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
                syncOpenFilterIndex(2)
                Task {
                    await viewModel.loadAvailableApps()
                }
            }
        }
        .onChange(of: showDatePopover) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if !isOpen {
                viewModel.isDatePopoverHandlingKeys = false
                datePopoverFocusRequestID = nil
            }
            if isOpen {
                syncOpenFilterIndex(3)
            }
        }
        .onChange(of: showTagsDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                syncOpenFilterIndex(4)
            }
        }
        .onChange(of: showVisibilityDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                syncOpenFilterIndex(5)
            }
        }
        .onChange(of: showCommentDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                syncOpenFilterIndex(6)
            }
        }
        .onChange(of: showAdvancedDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                syncOpenFilterIndex(7)
            }
        }
        .onChange(of: showSearchOrderDropdown) { isOpen in
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showCommentDropdown || showAdvancedDropdown || showSearchOrderDropdown
            if isOpen {
                syncOpenFilterIndex(1)
            }
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
                datePopoverFocusRequestID = UUID()
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

    private func syncOpenFilterIndex(_ index: Int) {
        let currentID = viewModel.openFilterSignal.id
        if viewModel.openFilterSignal.index != index {
            viewModel.openFilterSignal = (index, currentID)
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
        let ranges = viewModel.effectiveDateRanges
        if ranges.count > 1 {
            return "\(ranges.count) date ranges"
        }

        if let start = ranges.first?.start, let end = ranges.first?.end {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
        } else if let start = ranges.first?.start {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return "From \(formatter.string(from: start))"
        } else if let end = ranges.first?.end {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return "Until \(formatter.string(from: end))"
        }
        return "Date"
    }

    private var hasActiveAdvancedFilters: Bool {
        !viewModel.windowNameTerms.isEmpty ||
        !viewModel.windowNameExcludedTerms.isEmpty ||
        !viewModel.browserUrlTerms.isEmpty ||
        !viewModel.browserUrlExcludedTerms.isEmpty ||
        !viewModel.excludedSearchTerms.isEmpty
    }
}
