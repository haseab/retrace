import SwiftUI
import Shared
import App
import AppKit

/// Debug logging to file
private func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
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
    @State private var showSortDropdown = false

    // MARK: - Body

    private func logToFile(_ message: String) {
        let logMessage = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
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
                    action: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showSortDropdown.toggle()
                            showAppsDropdown = false
                            showDatePopover = false
                            showTagsDropdown = false
                            showVisibilityDropdown = false
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
                action: {
                    logToFile("[SearchFilterBar] Apps chip CLICKED! showAppsDropdown was \(showAppsDropdown), toggling...")
                    withAnimation(.easeOut(duration: 0.15)) {
                        showAppsDropdown.toggle()
                        showDatePopover = false
                        showTagsDropdown = false
                        showVisibilityDropdown = false
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
                showChevron: true
            ) {
                logToFile("[SearchFilterBar] Date chip CLICKED! showDatePopover was \(showDatePopover), toggling...")
                withAnimation(.easeOut(duration: 0.15)) {
                    showDatePopover.toggle()
                    showAppsDropdown = false
                    showTagsDropdown = false
                    showVisibilityDropdown = false
                }
                logToFile("[SearchFilterBar] Date chip after toggle: showDatePopover=\(showDatePopover)")
            }
            .dropdownOverlay(isPresented: $showDatePopover, yOffset: 56) {
                DateFilterPopover(
                    viewModel: viewModel,
                    isPresented: $showDatePopover
                )
            }

            // Tags filter
            TagsFilterChip(
                selectedTags: viewModel.selectedTags,
                availableTags: viewModel.availableTags,
                filterMode: viewModel.tagFilterMode,
                isActive: viewModel.selectedTags != nil && !viewModel.selectedTags!.isEmpty,
                action: {
                    logToFile("[SearchFilterBar] Tags chip CLICKED! showTagsDropdown was \(showTagsDropdown), toggling...")
                    withAnimation(.easeOut(duration: 0.15)) {
                        showTagsDropdown.toggle()
                        showAppsDropdown = false
                        showDatePopover = false
                        showVisibilityDropdown = false
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
                action: {
                    logToFile("[SearchFilterBar] Visibility chip CLICKED! showVisibilityDropdown was \(showVisibilityDropdown), toggling...")
                    withAnimation(.easeOut(duration: 0.15)) {
                        showVisibilityDropdown.toggle()
                        showAppsDropdown = false
                        showDatePopover = false
                        showTagsDropdown = false
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

            Spacer()

            // Clear all filters button (only shown when filters are active)
            if viewModel.hasActiveFilters {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.clearAllFilters()
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
                .background(Color.white.opacity(0.1))
                .cornerRadius(6)
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
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showSortDropdown
            debugLog("[SearchFilterBar] isDropdownOpen now: \(viewModel.isDropdownOpen)")
            // Lazy load apps only when dropdown is opened
            if isOpen {
                Task {
                    await viewModel.loadAvailableApps()
                }
            }
        }
        .onChange(of: showDatePopover) { isOpen in
            debugLog("[SearchFilterBar] showDatePopover changed to: \(isOpen)")
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showSortDropdown
        }
        .onChange(of: showTagsDropdown) { isOpen in
            debugLog("[SearchFilterBar] showTagsDropdown changed to: \(isOpen)")
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showSortDropdown
        }
        .onChange(of: showVisibilityDropdown) { isOpen in
            debugLog("[SearchFilterBar] showVisibilityDropdown changed to: \(isOpen)")
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showSortDropdown
        }
        .onChange(of: showSortDropdown) { isOpen in
            debugLog("[SearchFilterBar] showSortDropdown changed to: \(isOpen)")
            viewModel.isDropdownOpen = showAppsDropdown || showDatePopover || showTagsDropdown || showVisibilityDropdown || showSortDropdown
        }
        .onChange(of: viewModel.closeDropdownsSignal) { newValue in
            debugLog("[SearchFilterBar] closeDropdownsSignal received: \(newValue)")
            // Close all dropdowns when signal is received (from Escape key in parent)
            withAnimation(.easeOut(duration: 0.15)) {
                showAppsDropdown = false
                showDatePopover = false
                showTagsDropdown = false
                showVisibilityDropdown = false
                showSortDropdown = false
            }
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
}

// MARK: - Filter Chip Button

private struct FilterChip: View {
    let icon: String
    let label: String
    let isActive: Bool
    let showChevron: Bool
    let action: () -> Void

    @State private var isHovered = false

    private func logToFile(_ message: String) {
        let logMessage = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
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
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity(isHovered ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.white.opacity(0.3) : Color.clear, lineWidth: 1)
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
        let logMessage = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
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
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity(isHovered ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.white.opacity(0.3) : Color.clear, lineWidth: 1)
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

// MARK: - Date Filter Popover

private struct DateFilterPopover: View {
    @ObservedObject var viewModel: SearchViewModel
    @Binding var isPresented: Bool

    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()
    @State private var editingDate: EditingDate? = nil
    @State private var displayedMonth: Date = Date()

    /// Focus state to capture focus when popover appears - allows main search field to "steal" focus and dismiss
    @FocusState private var isFocused: Bool

    private let calendar = Calendar.current
    private let weekdaySymbols = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    private enum EditingDate {
        case start
        case end
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Date Range")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.primary)

                Spacer()

                if viewModel.startDate != nil || viewModel.endDate != nil {
                    Button("Clear") {
                        viewModel.setDateRange(start: nil, end: nil)
                        isPresented = false
                    }
                    .buttonStyle(.plain)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.white.opacity(0.1))

            // Date selection rows
            VStack(spacing: 8) {
                dateRow(label: "Start", date: startDate, isEditing: editingDate == .start) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        editingDate = editingDate == .start ? nil : .start
                        displayedMonth = startDate
                    }
                }
                dateRow(label: "End", date: endDate, isEditing: editingDate == .end) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        editingDate = editingDate == .end ? nil : .end
                        displayedMonth = endDate
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Inline calendar (shown when editing)
            if editingDate != nil {
                Divider()
                    .background(Color.white.opacity(0.1))

                inlineCalendar
                    .padding(12)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
                .background(Color.white.opacity(0.1))

            // Apply button
            Button(action: applyCustomRange) {
                Text("Apply")
                    .font(.retraceCaptionBold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.retraceSubmitAccent)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focused($isFocused)
        .modifier(FocusEffectDisabledModifier())
        .onAppear {
            initializeDates()
            // Capture focus when popover appears
            // This allows clicking elsewhere (like main search field) to dismiss by stealing focus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
        .onChange(of: isFocused) { focused in
            // Dismiss when focus is lost (e.g., clicking on main search field)
            if !focused {
                isPresented = false
            }
        }
        .onExitCommand {
            if editingDate != nil {
                withAnimation(.easeOut(duration: 0.15)) {
                    editingDate = nil
                }
            }
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
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 14))
                    .foregroundColor(isEditing ? .accentColor : .secondary)
                    .frame(width: 20)

                Text(label)
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .leading)

                Spacer()

                Text(formatDate(date))
                    .font(.retraceCalloutMedium)
                    .foregroundColor(isEditing ? .accentColor : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isEditing ? Color.accentColor.opacity(0.1) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isEditing ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Inline Calendar

    private var inlineCalendar: some View {
        VStack(spacing: 8) {
            // Month navigation
            HStack {
                Button(action: { changeMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.retraceCaption2Bold)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

                Spacer()

                Text(monthYearString)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Button(action: { changeMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.retraceCaption2Bold)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
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
                        .font(.retraceTinyMedium)
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
                        .font(isToday ? .retraceCaptionBold : .retraceCaption)
                        .foregroundColor(
                            isFuture
                                ? .white.opacity(0.2)
                                : (isSelected ? .white : .white.opacity(isCurrentMonth ? 0.8 : 0.3))
                        )
                        .frame(width: 30, height: 30)
                        .background(
                            ZStack {
                                if isSelected {
                                    Circle()
                                        .fill(Color.accentColor)
                                } else if isToday {
                                    Circle()
                                        .stroke(Color.accentColor, lineWidth: 1)
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
                    .frame(width: 30, height: 30)
            }
        }
    }

    // MARK: - Preset Chip

    private func presetChip(_ label: String, preset: DatePreset) -> some View {
        Button(action: {
            applyPreset(preset)
        }) {
            Text(label)
                .font(.retraceCaption2Medium)
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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
            return calendar.isDate(day, inSameDayAs: startDate)
        case .end:
            return calendar.isDate(day, inSameDayAs: endDate)
        case .none:
            return false
        }
    }

    private func selectDay(_ day: Date) {
        switch editingDate {
        case .start:
            startDate = day
            if startDate > endDate {
                endDate = startDate
            }
        case .end:
            endDate = day
            if endDate < startDate {
                startDate = endDate
            }
        case .none:
            break
        }
    }

    private func initializeDates() {
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        startDate = viewModel.startDate ?? weekAgo
        endDate = viewModel.endDate ?? now
        displayedMonth = endDate
    }

    private func applyCustomRange() {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate

        viewModel.setDateRange(start: start, end: end)
        isPresented = false
    }

    private func applyPreset(_ preset: DatePreset) {
        let now = Date()

        switch preset {
        case .anytime:
            viewModel.setDateRange(start: nil, end: nil)
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now)
            viewModel.setDateRange(start: start, end: end)
        case .yesterday:
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
                let start = calendar.startOfDay(for: yesterday)
                let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: yesterday)
                viewModel.setDateRange(start: start, end: end)
            }
        case .lastWeek:
            if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) {
                let start = calendar.startOfDay(for: weekAgo)
                viewModel.setDateRange(start: start, end: now)
            }
        case .lastMonth:
            if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) {
                let start = calendar.startOfDay(for: monthAgo)
                viewModel.setDateRange(start: start, end: now)
            }
        }

        isPresented = false
    }
}

// MARK: - Date Preset Enum

private enum DatePreset {
    case anytime
    case today
    case yesterday
    case lastWeek
    case lastMonth
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
        let logMessage = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
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
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity(isHovered ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.white.opacity(0.3) : Color.clear, lineWidth: 1)
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
        let logMessage = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
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
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity(isHovered ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.white.opacity(0.3) : Color.clear, lineWidth: 1)
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
                    .fill(Color.white.opacity(isHovered ? 0.15 : 0.1))
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

