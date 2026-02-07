import SwiftUI
import Shared
import App
import AppKit

/// Debug logging to file
private func debugLog(_ message: String) {
    let line = "[\(Log.timestamp())] \(message)\n"
    let path = "/tmp/retrace_debug.log"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

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
    @State private var showSortDropdown = false
    @State private var isClearFiltersHovered = false
    @State private var tabKeyMonitor: Any?

    /// Filter indices for Tab navigation: 1=Apps, 2=Date, 3=Tags, 4=Visibility, 5=Advanced, 0=back to search
    private let filterCount = 5

    // MARK: - Body

    private func logToFile(_ message: String) {
        let logMessage = "[\(Log.timestamp())] \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            let logPath = "/tmp/retrace_debug.log"
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    public var body: some View {
        let _ = logToFile("[SearchFilterBar] Rendering, showAppsDropdown=\(showAppsDropdown), showDatePopover=\(showDatePopover), showTagsDropdown=\(showTagsDropdown), showVisibilityDropdown=\(showVisibilityDropdown)")
        HStack(spacing: 10) {
            // Search mode tabs (Relevant / All)
            SearchModeTabs(viewModel: viewModel)

            // Sort order dropdown (only visible in "All" mode)
            if viewModel.searchMode == .all {
                SortOrderChip(
                    currentOrder: viewModel.sortOrder,
                    isOpen: showSortDropdown,
                    action: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showSortDropdown.toggle()
                            showAppsDropdown = false
                            showDatePopover = false
                            showTagsDropdown = false
                            showVisibilityDropdown = false
                            showAdvancedDropdown = false
                        }
                    }
                )
                .dropdownOverlay(isPresented: $showSortDropdown, yOffset: 56) {
                    SortOrderPopover(
                        currentOrder: viewModel.sortOrder,
                        onSelect: { order in
                            viewModel.setSearchSortOrder(order)
                        },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showSortDropdown = false
                            }
                        }
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
                    logToFile("[SearchFilterBar] Apps chip CLICKED! showAppsDropdown was \(showAppsDropdown), toggling...")
                    withAnimation(.easeOut(duration: 0.15)) {
                        showAppsDropdown.toggle()
                        showDatePopover = false
                        showTagsDropdown = false
                        showVisibilityDropdown = false
                        showAdvancedDropdown = false
                    }
                    logToFile("[SearchFilterBar] Apps chip after toggle: showAppsDropdown=\(showAppsDropdown)")
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
                logToFile("[SearchFilterBar] Date chip CLICKED! showDatePopover was \(showDatePopover), toggling...")
                withAnimation(.easeOut(duration: 0.15)) {
                    showDatePopover.toggle()
                    showAppsDropdown = false
                    showTagsDropdown = false
                    showVisibilityDropdown = false
                    showAdvancedDropdown = false
                }
                logToFile("[SearchFilterBar] Date chip after toggle: showDatePopover=\(showDatePopover)")
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
                    width: 280,
                    enableKeyboardNavigation: true,
                    onMoveToNextFilter: {
                        viewModel.openFilterSignal = (3, UUID())
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showDatePopover = false
                        }
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
                    logToFile("[SearchFilterBar] Tags chip CLICKED! showTagsDropdown was \(showTagsDropdown), toggling...")
                    withAnimation(.easeOut(duration: 0.15)) {
                        showTagsDropdown.toggle()
                        showAppsDropdown = false
                        showDatePopover = false
                        showVisibilityDropdown = false
                        showAdvancedDropdown = false
                    }
                    logToFile("[SearchFilterBar] Tags chip after toggle: showTagsDropdown=\(showTagsDropdown)")
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
                    logToFile("[SearchFilterBar] Visibility chip CLICKED! showVisibilityDropdown was \(showVisibilityDropdown), toggling...")
                    withAnimation(.easeOut(duration: 0.15)) {
                        showVisibilityDropdown.toggle()
                        showAppsDropdown = false
                        showDatePopover = false
                        showTagsDropdown = false
                        showAdvancedDropdown = false
                    }
                    logToFile("[SearchFilterBar] Visibility chip after toggle: showVisibilityDropdown=\(showVisibilityDropdown)")
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
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            await viewModel.loadAvailableTags()
        }
        .onChange(of: showAppsDropdown) { isOpen in
            debugLog("[SearchFilterBar] showAppsDropdown changed to: \(isOpen)")
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSortDropdown
            debugLog("[SearchFilterBar] isDropdownOpen now: \(viewModel.isDropdownOpen)")
            // Lazy load apps only when dropdown is opened
            if isOpen {
                viewModel.openFilterSignal = (1, UUID())
                Task {
                    await viewModel.loadAvailableApps()
                }
            }
        }
        .onChange(of: showDatePopover) { isOpen in
            debugLog("[SearchFilterBar] showDatePopover changed to: \(isOpen)")
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSortDropdown
            if isOpen {
                viewModel.openFilterSignal = (2, UUID())
            }
        }
        .onChange(of: showTagsDropdown) { isOpen in
            debugLog("[SearchFilterBar] showTagsDropdown changed to: \(isOpen)")
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSortDropdown
            if isOpen {
                viewModel.openFilterSignal = (3, UUID())
            }
        }
        .onChange(of: showVisibilityDropdown) { isOpen in
            debugLog("[SearchFilterBar] showVisibilityDropdown changed to: \(isOpen)")
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSortDropdown
            if isOpen {
                viewModel.openFilterSignal = (4, UUID())
            }
        }
        .onChange(of: showAdvancedDropdown) { isOpen in
            debugLog("[SearchFilterBar] showAdvancedDropdown changed to: \(isOpen)")
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSortDropdown
            if isOpen {
                viewModel.openFilterSignal = (5, UUID())
            }
        }
        .onChange(of: showSortDropdown) { isOpen in
            debugLog("[SearchFilterBar] showSortDropdown changed to: \(isOpen)")
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showAdvancedDropdown || showSortDropdown
        }
        .onChange(of: viewModel.closeDropdownsSignal) { newValue in
            debugLog("[SearchFilterBar] closeDropdownsSignal received: \(newValue)")
            // Close all dropdowns when signal is received (from Escape key in parent)
            withAnimation(.easeOut(duration: 0.15)) {
                showAppsDropdown = false
                showDatePopover = false
                showTagsDropdown = false
                showVisibilityDropdown = false
                showAdvancedDropdown = false
                showSortDropdown = false
            }
        }
        .onChange(of: viewModel.openFilterSignal.id) { _ in
            let filterIndex = viewModel.openFilterSignal.index
            debugLog("[SearchFilterBar] openFilterSignal received: index=\(filterIndex)")
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
            showSortDropdown = false

            // Open the requested one
            switch index {
            case 1:
                showAppsDropdown = true
                // Lazy load apps when opening via Tab
                Task {
                    await viewModel.loadAvailableApps()
                }
            case 2:
                showDatePopover = true
            case 3:
                showTagsDropdown = true
            case 4:
                showVisibilityDropdown = true
            case 5:
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
            // Filter indices: 0=Search, 1=Apps, 2=Date, 3=Tags, 4=Visibility, 5=Advanced
            let lastSignal = vm.openFilterSignal.index
            let currentIndex = lastSignal > 0 ? lastSignal : 1  // Start from 1 if coming from search

            debugLog("[SearchFilterBar] Tab pressed in dropdown, lastSignal=\(lastSignal), cycling from \(currentIndex), shift=\(isShiftHeld)")

            // Calculate next index based on direction
            let nextIndex: Int
            if isShiftHeld {
                // Shift+Tab: go backward (cycle: 0 -> 5 -> 4 -> 3 -> 2 -> 1 -> 0)
                nextIndex = currentIndex <= 0 ? filterCount : currentIndex - 1
            } else {
                // Tab: go forward (cycle: 1 -> 2 -> 3 -> 4 -> 5 -> 0 -> 1)
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

    private func logToFile(_ message: String) {
        let logMessage = "[\(Log.timestamp())] \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            let logPath = "/tmp/retrace_debug.log"
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    var body: some View {
        Button(action: {
            logToFile("[FilterChip] Button action triggered for: \(label)")
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

    private func logToFile(_ message: String) {
        let logMessage = "[\(Log.timestamp())] \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            let logPath = "/tmp/retrace_debug.log"
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    var body: some View {
        Button(action: {
            logToFile("[AppsFilterChip] Button action triggered!")
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
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private func appName(for bundleID: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: appURL.path)
        }
        // Fallback: extract last component of bundle ID
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

// MARK: - Search Mode Tabs

private struct SearchModeTabs: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        HStack(spacing: 4) {
            SearchModeTab(
                label: "Relevant",
                isSelected: viewModel.searchMode == .relevant
            ) {
                viewModel.setSearchMode(.relevant)
            }

            SearchModeTab(
                label: "All",
                isSelected: viewModel.searchMode == .all
            ) {
                viewModel.setSearchMode(.all)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
        )
    }
}

private struct SearchModeTab: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(isSelected ? .retraceCalloutBold : .retraceCalloutMedium)
                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.white.opacity(0.2) : (isHovered ? Color.white.opacity(0.1) : Color.clear))
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

    private func logToFile(_ message: String) {
        let logMessage = "[\(Log.timestamp())] \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            let logPath = "/tmp/retrace_debug.log"
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    var body: some View {
        Button(action: {
            logToFile("[TagsFilterChip] Button action triggered!")
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

    private func logToFile(_ message: String) {
        let logMessage = "[\(Log.timestamp())] \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            let logPath = "/tmp/retrace_debug.log"
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    var body: some View {
        Button(action: {
            logToFile("[VisibilityFilterChip] Button action triggered!")
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

// MARK: - Sort Order Chip

private struct SortOrderChip: View {
    let currentOrder: SearchSortOrder
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var icon: String {
        switch currentOrder {
        case .newestFirst: return "arrow.down"
        case .oldestFirst: return "arrow.up"
        }
    }

    private var label: String {
        switch currentOrder {
        case .newestFirst: return "Newest"
        case .oldestFirst: return "Oldest"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))

                Text(label)
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

// MARK: - Sort Order Popover

private struct SortOrderPopover: View {
    let currentOrder: SearchSortOrder
    let onSelect: (SearchSortOrder) -> Void
    var onDismiss: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var highlightedIndex: Int = 0

    private let options: [SearchSortOrder] = [.newestFirst, .oldestFirst]

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
                // Newest First option (default)
                FilterRow(
                    systemIcon: "arrow.down",
                    title: "Newest First",
                    subtitle: "Most recent results first",
                    isSelected: currentOrder == .newestFirst,
                    isKeyboardHighlighted: highlightedIndex == 0
                ) {
                    onSelect(.newestFirst)
                    onDismiss?()
                }
                .id(0)

                Divider()
                    .padding(.vertical, 4)

                // Oldest First option
                FilterRow(
                    systemIcon: "arrow.up",
                    title: "Oldest First",
                    subtitle: "Oldest results first",
                    isSelected: currentOrder == .oldestFirst,
                    isKeyboardHighlighted: highlightedIndex == 1
                ) {
                    onSelect(.oldestFirst)
                    onDismiss?()
                }
                .id(1)
            }
            .padding(.vertical, 8)
        }
        .focused($isFocused)
        .onAppear {
            // Set initial highlight to current selection
            highlightedIndex = options.firstIndex(of: currentOrder) ?? 0
            isFocused = true
        }
        .keyboardNavigation(
            onUpArrow: { moveHighlight(by: -1) },
            onDownArrow: { moveHighlight(by: 1) },
            onReturn: { selectHighlightedItem() }
        )
    }
}
