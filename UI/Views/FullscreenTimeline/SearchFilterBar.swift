import SwiftUI
import Shared
import App

/// Filter bar for search overlay - displays filter chips below the search field
/// Styled similar to macOS Spotlight/Raycast with pill-shaped buttons
public struct SearchFilterBar: View {

    // MARK: - Properties

    @ObservedObject var viewModel: SearchViewModel
    @State private var showAppsPopover = false
    @State private var showDatePopover = false

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 10) {
            // Search mode tabs (Relevant / All)
            SearchModeTabs(viewModel: viewModel)

            Divider()
                .frame(height: 24)
                .background(Color.white.opacity(0.2))

            // Apps filter
            FilterChip(
                icon: "wrench.and.screwdriver",
                label: viewModel.selectedAppName ?? "Apps",
                isActive: viewModel.selectedAppFilter != nil,
                showChevron: true
            ) {
                showAppsPopover.toggle()
            }
            .popover(isPresented: $showAppsPopover, arrowEdge: .bottom) {
                AppsFilterPopover(
                    viewModel: viewModel,
                    isPresented: $showAppsPopover
                )
            }

            // Date filter
            FilterChip(
                icon: "calendar",
                label: dateFilterLabel,
                isActive: viewModel.startDate != nil || viewModel.endDate != nil,
                showChevron: true
            ) {
                showDatePopover.toggle()
            }
            .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
                DateFilterPopover(
                    viewModel: viewModel,
                    isPresented: $showDatePopover
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
                            .font(.system(size: 10, weight: .semibold))
                        Text("Clear")
                            .font(.system(size: 12, weight: .medium))
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
            // Load available apps when the filter bar appears
            await viewModel.loadAvailableApps()
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if showChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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

// MARK: - Apps Filter Popover

private struct AppsFilterPopover: View {
    @ObservedObject var viewModel: SearchViewModel
    @Binding var isPresented: Bool
    @State private var searchText = ""

    private var filteredApps: [RewindDataSource.AppInfo] {
        if searchText.isEmpty {
            return viewModel.availableApps
        }
        return viewModel.availableApps.filter { app in
            app.bundleID.localizedCaseInsensitiveContains(searchText) ||
            app.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))

                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // App list
            ScrollView {
                LazyVStack(spacing: 0) {
                    // "All Apps" option
                    AppFilterRow(
                        icon: nil,
                        name: "All Apps",
                        bundleID: nil,
                        isSelected: viewModel.selectedAppFilter == nil
                    ) {
                        viewModel.setAppFilter(nil)
                        isPresented = false
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // Individual apps
                    ForEach(filteredApps) { app in
                        AppFilterRow(
                            icon: NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)?.path ?? ""),
                            name: app.name,
                            bundleID: app.bundleID,
                            isSelected: viewModel.selectedAppFilter == app.bundleID
                        ) {
                            viewModel.setAppFilter(app.bundleID)
                            isPresented = false
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - App Filter Row

private struct AppFilterRow: View {
    let icon: NSImage?
    let name: String
    let bundleID: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // App icon
                if let icon = icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }

                // App name
                Text(name)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                // Checkmark for selected
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
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

// MARK: - Date Filter Popover

private struct DateFilterPopover: View {
    @ObservedObject var viewModel: SearchViewModel
    @Binding var isPresented: Bool

    @State private var customStartDate = Date()
    @State private var customEndDate = Date()
    @State private var showCustomCalendar = false

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            // Header with current selection
            dateRangeHeader
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()
                .background(Color.white.opacity(0.1))

            // Quick presets as horizontal chips
            quickPresetsSection
                .padding(12)

            Divider()
                .background(Color.white.opacity(0.1))

            // Custom range with visual calendar
            customRangeSection
                .padding(12)
        }
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Initialize custom dates from current filter or today
            customStartDate = viewModel.startDate ?? calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            customEndDate = viewModel.endDate ?? Date()
        }
    }

    // MARK: - Header showing current selection

    private var dateRangeHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.accentColor)

                Text("Date Range")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                if viewModel.startDate != nil || viewModel.endDate != nil {
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.setDateRange(start: nil, end: nil)
                        }
                    }) {
                        Text("Clear")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Visual representation of selected range
            if let start = viewModel.startDate, let end = viewModel.endDate {
                HStack(spacing: 8) {
                    dateChip(date: start, label: "From")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    dateChip(date: end, label: "To")
                }
            } else {
                Text("All time")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func dateChip(date: Date, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            Text(formatDate(date))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.1))
        )
    }

    // MARK: - Quick Presets

    private var quickPresetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Select")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            // First row: Anytime, Today, Yesterday
            HStack(spacing: 8) {
                ForEach([DatePreset.anytime, .today, .yesterday], id: \.self) { preset in
                    presetChip(preset: preset)
                }
            }

            // Second row: Last 7 Days, Last 30 Days
            HStack(spacing: 8) {
                ForEach([DatePreset.lastWeek, .lastMonth], id: \.self) { preset in
                    presetChip(preset: preset)
                }
                Spacer()
            }
        }
    }

    private func presetChip(preset: DatePreset) -> some View {
        let isSelected = isPresetSelected(preset)

        return Button(action: {
            withAnimation(.easeOut(duration: 0.15)) {
                applyPreset(preset)
            }
        }) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(preset.shortLabel)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Custom Range Section

    private var customRangeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom Range")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showCustomCalendar.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: showCustomCalendar ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(showCustomCalendar ? "Hide" : "Show")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }

            if showCustomCalendar {
                VStack(spacing: 16) {
                    // Date pickers in a cleaner layout
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)

                            DatePicker("", selection: $customStartDate, in: ...Date(), displayedComponents: .date)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("End")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)

                            DatePicker("", selection: $customEndDate, in: ...Date(), displayedComponents: .date)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Visual timeline showing the range
                    dateRangeTimeline

                    // Apply button
                    Button(action: {
                        let start = calendar.startOfDay(for: customStartDate)
                        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: customEndDate)
                        viewModel.setDateRange(start: start, end: end)
                        isPresented = false
                    }) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                            Text("Apply Range")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Visual Timeline

    private var dateRangeTimeline: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        .frame(height: 8)

                    // Selected range indicator
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.6), Color.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width, height: 8)
                }
            }
            .frame(height: 8)

            // Range label
            HStack {
                Text(formatDateShort(customStartDate))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()

                let daysDiff = calendar.dateComponents([.day], from: customStartDate, to: customEndDate).day ?? 0
                Text("\(daysDiff) day\(daysDiff == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentColor)

                Spacer()

                Text(formatDateShort(customEndDate))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private func formatDateShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func isPresetSelected(_ preset: DatePreset) -> Bool {
        guard let start = viewModel.startDate else {
            return preset == .anytime
        }

        let now = Date()

        switch preset {
        case .anytime:
            return viewModel.startDate == nil && viewModel.endDate == nil
        case .today:
            return calendar.isDateInToday(start)
        case .yesterday:
            return calendar.isDateInYesterday(start)
        case .lastWeek:
            if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) {
                return calendar.isDate(start, inSameDayAs: weekAgo)
            }
            return false
        case .lastMonth:
            if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) {
                return calendar.isDate(start, inSameDayAs: monthAgo)
            }
            return false
        }
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

private enum DatePreset: String, CaseIterable {
    case anytime = "Anytime"
    case today = "Today"
    case yesterday = "Yesterday"
    case lastWeek = "Last 7 Days"
    case lastMonth = "Last 30 Days"

    /// Shorter labels for chip display
    var shortLabel: String {
        switch self {
        case .anytime: return "All Time"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .lastWeek: return "7 Days"
        case .lastMonth: return "30 Days"
        }
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
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
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
