import SwiftUI
import Shared
import App

// MARK: - Layout Size

/// Responsive layout sizes for dashboard stat cards
/// Scales up progressively as screen width increases
private enum LayoutSize {
    case normal      // < 1100px
    case large       // 1100-1400px
    case extraLarge  // 1400-1700px
    case massive     // > 1700px

    static func from(width: CGFloat) -> LayoutSize {
        if width > 1700 {
            return .massive
        } else if width > 1400 {
            return .extraLarge
        } else if width > 1100 {
            return .large
        } else {
            return .normal
        }
    }

    // MARK: - Card Dimensions

    var cardWidth: CGFloat {
        switch self {
        case .normal: return 280
        case .large: return 340
        case .extraLarge: return 400
        case .massive: return 460
        }
    }

    var graphHeight: CGFloat {
        switch self {
        case .normal: return 77
        case .large: return 100
        case .extraLarge: return 120
        case .massive: return 140
        }
    }

    // MARK: - Icon Sizes

    var iconCircleSize: CGFloat {
        switch self {
        case .normal: return 44
        case .large: return 52
        case .extraLarge: return 60
        case .massive: return 68
        }
    }

    var iconFont: Font {
        switch self {
        case .normal: return .retraceHeadline
        case .large: return .system(size: 20, weight: .semibold)
        case .extraLarge: return .system(size: 24, weight: .semibold)
        case .massive: return .system(size: 28, weight: .semibold)
        }
    }

    // MARK: - Text Fonts

    var titleFont: Font {
        switch self {
        case .normal: return .retraceCaption2Medium
        case .large: return .retraceCaptionMedium
        case .extraLarge: return .retraceCalloutMedium
        case .massive: return .retraceBodyMedium
        }
    }

    var valueFont: Font {
        switch self {
        case .normal: return .retraceMediumNumber
        case .large: return .system(size: 28, weight: .bold, design: .rounded)
        case .extraLarge: return .system(size: 34, weight: .bold, design: .rounded)
        case .massive: return .system(size: 40, weight: .bold, design: .rounded)
        }
    }

    var subtitleFont: Font {
        switch self {
        case .normal: return .retraceCaption2Medium
        case .large: return .retraceCaptionMedium
        case .extraLarge: return .retraceCalloutMedium
        case .massive: return .retraceBodyMedium
        }
    }

    // MARK: - Spacing & Padding

    var iconSpacing: CGFloat {
        switch self {
        case .normal: return 14
        case .large: return 16
        case .extraLarge: return 18
        case .massive: return 20
        }
    }

    var textSpacing: CGFloat {
        switch self {
        case .normal: return 2
        case .large: return 3
        case .extraLarge: return 4
        case .massive: return 5
        }
    }

    var cardPadding: CGFloat {
        switch self {
        case .normal: return 16
        case .large: return 20
        case .extraLarge: return 24
        case .massive: return 28
        }
    }

    var graphHorizontalPadding: CGFloat {
        switch self {
        case .normal: return 12
        case .large: return 16
        case .extraLarge: return 20
        case .massive: return 24
        }
    }

    var graphBottomPadding: CGFloat {
        switch self {
        case .normal: return 8
        case .large: return 12
        case .extraLarge: return 16
        case .massive: return 20
        }
    }
}

/// Main dashboard view - analytics and statistics
/// Default landing screen
public struct DashboardView: View {

    // MARK: - Properties

    @StateObject private var viewModel: DashboardViewModel
    @ObservedObject var launchOnLoginReminderManager: LaunchOnLoginReminderManager
    @ObservedObject var milestoneCelebrationManager: MilestoneCelebrationManager
    @State private var isPulsing = false
    @State private var showFeedbackSheet = false
    @State private var usageViewMode: AppUsageViewMode = Self.loadSavedViewMode()
    @State private var selectedApp: AppUsageData? = nil
    @State private var selectedWindow: WindowUsageData? = nil
    @State private var showSessionsSheet = false

    enum AppUsageViewMode: String, CaseIterable {
        case list = "list"
        case hardDrive = "squares"

        var icon: String {
            switch self {
            case .list: return "list.bullet"
            case .hardDrive: return "square.grid.2x2"
            }
        }
    }

    private static let viewModeDefaultsKey = "dashboardAppUsageViewMode"

    private static func loadSavedViewMode() -> AppUsageViewMode {
        guard let raw = UserDefaults.standard.string(forKey: viewModeDefaultsKey),
              let mode = AppUsageViewMode(rawValue: raw) else {
            return .list
        }
        return mode
    }

    private func saveViewMode(_ mode: AppUsageViewMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.viewModeDefaultsKey)
    }

    // MARK: - Initialization

    public init(
        coordinator: AppCoordinator,
        launchOnLoginReminderManager: LaunchOnLoginReminderManager,
        milestoneCelebrationManager: MilestoneCelebrationManager
    ) {
        _viewModel = StateObject(wrappedValue: DashboardViewModel(coordinator: coordinator))
        self.launchOnLoginReminderManager = launchOnLoginReminderManager
        self.milestoneCelebrationManager = milestoneCelebrationManager
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Accessibility permission warning banner
            if viewModel.showAccessibilityWarning {
                PermissionBanner(
                    message: "Retrace needs Accessibility permission to detect display changes and exclude private/incognito windows and excluded apps.",
                    actionTitle: "Open Settings",
                    action: {
                        SystemSettingsOpener.openAccessibilitySettings()
                    },
                    onDismiss: {
                        viewModel.dismissAccessibilityWarning()
                    }
                )
                .padding(.horizontal, 32)
                .padding(.top, 20)
            }

            // Screen recording permission warning banner
            if viewModel.showScreenRecordingWarning {
                PermissionBanner(
                    message: "Retrace needs Screen Recording permission to capture your screen.",
                    actionTitle: "Open Settings",
                    action: {
                        SystemSettingsOpener.openScreenRecordingSettings()
                    },
                    onDismiss: {
                        viewModel.dismissScreenRecordingWarning()
                    }
                )
                .padding(.horizontal, 32)
                .padding(.top, viewModel.showAccessibilityWarning ? 12 : 20)
            }

            // Launch on login reminder banner
            if launchOnLoginReminderManager.shouldShowReminder {
                PermissionBanner(
                    message: "Retrace works best when it launches automatically on login so you never miss a moment.",
                    actionTitle: "Launch on Login",
                    action: {
                        launchOnLoginReminderManager.enableLaunchAtLogin()
                    },
                    onDismiss: {
                        launchOnLoginReminderManager.dismissReminder()
                    }
                )
                .padding(.horizontal, 32)
                .padding(.top, (viewModel.showAccessibilityWarning || viewModel.showScreenRecordingWarning) ? 12 : 20)
            }

            // Header
            header
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 32)

            // Two-column layout: metrics on left, app usage on right
            // This section expands to fill remaining height
            GeometryReader { geometry in
                let layoutSize = LayoutSize.from(width: geometry.size.width)

                HStack(alignment: .top, spacing: 24) {
                    // Left column: Stats cards (single column, scales with screen size)
                    ZStack {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 16) {
                                ForEach(statsCards) { card in
                                    statCard(
                                        icon: card.icon,
                                        title: card.title,
                                        value: card.value,
                                        subtitle: card.subtitle,
                                        graphData: card.graphData,
                                        graphColor: card.graphColor,
                                        theme: MilestoneCelebrationManager.getCurrentTheme(),
                                        valueFormatter: card.valueFormatter,
                                        layoutSize: layoutSize
                                    )
                                }
                            }
                            .padding(.bottom, 20) // Extra padding for scroll affordance
                        }

                        ScrollAffordance(height: 32, color: themeBaseBackground)
                    }
                    .frame(width: layoutSize.cardWidth)

                    // Right column: App usage (scrolls internally)
                    appUsageSection(layoutSize: layoutSize)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            // Footer
            footer
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .background(
            ZStack {
                // Theme-aware base background color
                themeBaseBackground

                // Theme-aware ambient glow background
                themeAmbientBackground
            }
        )
        .task {
            await viewModel.loadStatistics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDidBecomeKey)) { _ in
            Task { await viewModel.loadStatistics() }
        }
        .sheet(isPresented: $showSessionsSheet) {
            if let app = selectedApp {
                if let window = selectedWindow {
                    // Window-filtered sessions
                    AppSessionsDetailView(
                        app: app,
                        onOpenInTimeline: { date in
                            openTimelineAt(date: date)
                        },
                        loadSessions: { offset, limit in
                            await viewModel.getSessionsForAppWindow(
                                bundleID: app.appBundleID,
                                windowNameOrDomain: window.displayName,
                                offset: offset,
                                limit: limit
                            )
                        },
                        subtitle: window.displayName
                    )
                } else {
                    // All sessions for app
                    AppSessionsDetailView(
                        app: app,
                        onOpenInTimeline: { date in
                            openTimelineAt(date: date)
                        },
                        loadSessions: { offset, limit in
                            await viewModel.getSessionsForApp(
                                bundleID: app.appBundleID,
                                offset: offset,
                                limit: limit
                            )
                        }
                    )
                }
            }
        }
        .overlay {
            // Milestone celebration dialog
            if let milestone = milestoneCelebrationManager.currentMilestone {
                ZStack {
                    // Dimmed background
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .onTapGesture {
                            // Dismiss on background tap
                            milestoneCelebrationManager.dismissCurrentMilestone()
                        }

                    // Celebration dialog
                    MilestoneCelebrationView(
                        milestone: milestone,
                        onDismiss: {
                            milestoneCelebrationManager.dismissCurrentMilestone()
                        },
                        onSupport: {
                            milestoneCelebrationManager.openSupportLink()
                        }
                    )
                    .transition(.scale.combined(with: .opacity))
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: milestone)
            }
        }
    }

    // MARK: - App Session Actions

    private func handleAppTapped(_ app: AppUsageData) {
        selectedApp = app
        selectedWindow = nil
        showSessionsSheet = true
    }

    private func handleWindowTapped(_ app: AppUsageData, _ window: WindowUsageData) {
        selectedApp = app
        selectedWindow = window
        showSessionsSheet = true
    }

    private func openTimelineAt(date: Date) {
        // Show the timeline and navigate to the specific date
        TimelineWindowController.shared.showAndNavigate(to: date)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                // Retrace logo + Dashboard text
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        LogoTriangle()
                            .fill(Color.white)
                            .frame(width: 14, height: 18)
                            .rotationEffect(.degrees(180))
                        LogoTriangle()
                            .fill(Color.white)
                            .frame(width: 14, height: 18)
                    }

                    Text("Dashboard")
                        .font(.retraceTitle3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                // Recording status indicator
                recordingIndicator

                // Action buttons
                refreshButton
                settingsButton
            }
        }
        .sheet(isPresented: $showFeedbackSheet) {
            FeedbackFormView()
        }
    }

    private func actionButton(icon: String, label: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.retraceCalloutMedium)
                if let label = label {
                    Text(label)
                        .font(.retraceCaptionMedium)
                }
            }
            .foregroundColor(.retraceSecondary)
            .padding(.horizontal, label != nil ? 14 : 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Action Button States

    @State private var isHoveringRefresh = false
    @State private var refreshRotation: Double = 0
    @State private var isHoveringSettings = false
    @State private var settingsRotation: Double = 0

    // MARK: - Footer Hover States

    @State private var isHoveringHaseab = false
    @State private var isHoveringSupportMe = false
    @State private var isHoveringFeedback = false

    // MARK: - Refresh Button

    private var refreshButton: some View {
        Button(action: {
            // Spin animation on click
            withAnimation(.easeInOut(duration: 0.5)) {
                refreshRotation += 360
            }
            Task { await viewModel.loadStatistics() }
        }) {
            Image(systemName: "arrow.clockwise")
                .font(.retraceCalloutMedium)
                .foregroundColor(.retraceSecondary)
                .rotationEffect(.degrees(refreshRotation + (isHoveringRefresh ? 45 : 0)))
                .animation(.easeInOut(duration: 0.2), value: isHoveringRefresh)
                .padding(10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringRefresh = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Settings Button

    private var settingsButton: some View {
        Button(action: {
            // Quick spin on click
            withAnimation(.easeInOut(duration: 0.3)) {
                settingsRotation += 90
            }
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }) {
            Image(systemName: "gearshape")
                .font(.retraceCalloutMedium)
                .foregroundColor(.retraceSecondary)
                .rotationEffect(.degrees(settingsRotation + (isHoveringSettings ? 30 : 0)))
                .animation(.easeInOut(duration: 0.2), value: isHoveringSettings)
                .padding(10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringSettings = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Recording Indicator

    @State private var isHoveringRecordingIndicator = false

    private var recordingIndicator: some View {
        Button(action: {
            Task {
                await viewModel.toggleRecording(to: !viewModel.isRecording)
            }
        }) {
            HStack(spacing: 6) {
                if viewModel.isRecording && isHoveringRecordingIndicator {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 6)
                        .transition(.opacity)
                } else {
                    Circle()
                        .fill(viewModel.isRecording ? Color.retraceDanger : Color.retraceSecondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .transition(.opacity)
                }

                Text(recordingIndicatorLabel)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)
                    .contentTransition(.interpolate)
                    .frame(width: 65, alignment: .center)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isHoveringRecordingIndicator)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isRecording)
        .onHover { hovering in
            isHoveringRecordingIndicator = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var recordingIndicatorLabel: String {
        if viewModel.isRecording {
            return isHoveringRecordingIndicator ? "Pause" : "Recording"
        } else {
            return isHoveringRecordingIndicator ? "Start Recording" : "Off"
        }
    }

    // MARK: - Stats Cards Row

    private struct StatCardData: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let value: String
        let subtitle: String
        let graphData: [DailyDataPoint]?
        let graphColor: Color
        let valueFormatter: ((Int64) -> String)?

        init(icon: String, title: String, value: String, subtitle: String, graphData: [DailyDataPoint]? = nil, graphColor: Color = .retraceAccent, valueFormatter: ((Int64) -> String)? = nil) {
            self.icon = icon
            self.title = title
            self.value = value
            self.subtitle = subtitle
            self.graphData = graphData
            self.graphColor = graphColor
            self.valueFormatter = valueFormatter
        }
    }

    private var statsCards: [StatCardData] {
        [
            StatCardData(
                icon: "calendar",
                title: "Total Days Recorded",
                value: formatDaysRecorded(viewModel.daysRecorded),
                subtitle: "\(viewModel.daysRecorded) day\(viewModel.daysRecorded == 1 ? "" : "s") total"
            ),
            StatCardData(
                icon: "clock.fill",
                title: "Screen Time",
                value: formatScreenTimeFromDaily(viewModel.dailyScreenTimeData),
                subtitle: "Last 7 days",
                graphData: viewModel.dailyScreenTimeData.isEmpty ? nil : viewModel.dailyScreenTimeData,
                graphColor: .blue,
                valueFormatter: { milliseconds in
                    let hours = Double(milliseconds) / 1000.0 / 3600.0
                    return String(format: "%.1fh", hours)
                }
            ),
            StatCardData(
                icon: "externaldrive.fill",
                title: "Total Storage Used",
                value: formatStorageSize(viewModel.totalStorageBytes),
                subtitle: formatStoragePerMonth(),
                graphData: viewModel.dailyStorageData.isEmpty ? nil : viewModel.dailyStorageData,
                graphColor: .cyan
            ),
            StatCardData(
                icon: "timelapse",
                title: "Timeline Opens",
                value: "\(viewModel.timelineOpensThisWeek)",
                subtitle: "Last 7 days",
                graphData: viewModel.dailyTimelineOpensData.isEmpty ? nil : viewModel.dailyTimelineOpensData,
                graphColor: .purple
            ),
            StatCardData(
                icon: "magnifyingglass",
                title: "Searches",
                value: "\(viewModel.searchesThisWeek)",
                subtitle: "Last 7 days",
                graphData: viewModel.dailySearchesData.isEmpty ? nil : viewModel.dailySearchesData,
                graphColor: .orange
            ),
            StatCardData(
                icon: "doc.on.doc",
                title: "Text Copies",
                value: "\(viewModel.textCopiesThisWeek)",
                subtitle: "Last 7 days",
                graphData: viewModel.dailyTextCopiesData.isEmpty ? nil : viewModel.dailyTextCopiesData,
                graphColor: .green
            ),
        ]
    }

    private func statCard(
        icon: String,
        title: String,
        value: String,
        subtitle: String,
        graphData: [DailyDataPoint]?,
        graphColor: Color,
        theme: MilestoneCelebrationManager.ColorTheme,
        valueFormatter: ((Int64) -> String)?,
        layoutSize: LayoutSize = .normal
    ) -> some View {
        // Use a consistent muted color for all icons
        let iconColor = Color.retraceSecondary

        return VStack(spacing: 0) {
            HStack(spacing: layoutSize.iconSpacing) {
                // Icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.10))
                        .frame(width: layoutSize.iconCircleSize, height: layoutSize.iconCircleSize)

                    Image(systemName: icon)
                        .font(layoutSize.iconFont)
                        .foregroundColor(iconColor)
                }

                VStack(alignment: .leading, spacing: layoutSize.textSpacing) {
                    Text(title)
                        .font(layoutSize.titleFont)
                        .foregroundColor(.retraceSecondary)

                    Text(value)
                        .font(layoutSize.valueFont)
                        .foregroundColor(.retracePrimary)

                    Text(subtitle)
                        .font(layoutSize.subtitleFont)
                        .foregroundColor(.retraceSecondary.opacity(0.7))
                }

                Spacer()
            }
            .padding(layoutSize.cardPadding)

            // Mini line graph (if data is available)
            if let data = graphData, !data.isEmpty {
                MiniLineGraphView(
                    dataPoints: data,
                    lineColor: graphColor,
                    showGradientFill: true,
                    valueFormatter: valueFormatter
                )
                .frame(height: layoutSize.graphHeight)
                .padding(.horizontal, layoutSize.graphHorizontalPadding)
                .padding(.bottom, layoutSize.graphBottomPadding)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.02))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.controlBorderColor.opacity(0.6), lineWidth: 1)
        )
    }

    private func formatStorageSize(_ bytes: Int64) -> String {
        // Use decimal (SI) units to match Finder
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else {
            let mb = Double(bytes) / 1_000_000
            return String(format: "%.0f MB", mb)
        }
    }

    private func formatStoragePerMonth() -> String {
        let dailyData = viewModel.dailyStorageData
        guard !dailyData.isEmpty else { return "est. 0 GB/month" }

        // Sum all daily values and extrapolate to 30 days
        let totalBytes = dailyData.reduce(0) { $0 + $1.value }
        let daysWithData = dailyData.count
        let bytesPerDay = Double(totalBytes) / Double(daysWithData)
        let bytesPerMonth = bytesPerDay * 30.0
        let gbPerMonth = bytesPerMonth / 1_000_000_000
        return String(format: "est. %.1f GB/month", gbPerMonth)
    }

    private func formatDaysRecorded(_ days: Int) -> String {
        if days == 0 {
            return "0"
        } else if days < 7 {
            return "\(days) day\(days == 1 ? "" : "s")"
        } else if days < 30 {
            let weeks = days / 7
            return "\(weeks) week\(weeks == 1 ? "" : "s")"
        } else if days < 365 {
            let months = days / 30
            return "\(months) month\(months == 1 ? "" : "s")"
        } else {
            let years = days / 365
            return "\(years) year\(years == 1 ? "" : "s")"
        }
    }

    // MARK: - App Usage Section

    private func appUsageSection(layoutSize: LayoutSize) -> some View {
        // Convert LayoutSize to AppUsageLayoutSize
        let appUsageLayout: AppUsageLayoutSize = {
            switch layoutSize {
            case .normal: return .normal
            case .large: return .large
            case .extraLarge: return .extraLarge
            case .massive: return .massive
            }
        }()

        return VStack(alignment: .leading, spacing: 0) {
            if viewModel.isLoading && viewModel.weeklyAppUsage.isEmpty {
                loadingStateView
            } else if viewModel.weeklyAppUsage.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    // Header row with view mode toggle
                    HStack {
                        Text("App Usage")
                            .font(.retraceHeadline)
                            .foregroundColor(.retracePrimary)

                        Spacer()

                        Text("\(formatTotalTime(viewModel.weeklyAppUsage.reduce(0) { $0 + $1.duration }))  ·  Last 7 days")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retraceSecondary)

                        // View mode toggle
                        viewModeToggle
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                    Divider()
                        .background(Color.white.opacity(0.06))

                    // Content based on view mode
                    switch usageViewMode {
                    case .list:
                        AppUsageListView(
                            apps: viewModel.weeklyAppUsage,
                            totalTime: viewModel.totalWeeklyTime,
                            layoutSize: appUsageLayout,
                            loadWindowUsage: { bundleID in
                                await viewModel.getWindowUsageForApp(bundleID: bundleID)
                            },
                            onWindowTapped: { app, window in
                                handleWindowTapped(app, window)
                            }
                        )
                    case .hardDrive:
                        AppUsageHardDriveView(
                            apps: viewModel.weeklyAppUsage,
                            totalTime: viewModel.totalWeeklyTime,
                            onAppTapped: { app in
                                handleAppTapped(app)
                            }
                        )
                    }
                }
                .background(Color.white.opacity(0.03))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(themeBorderColor.opacity(1.2), lineWidth: 1.2)
                )
            }
        }
    }

    private var themeBorderColor: Color {
        let theme = MilestoneCelebrationManager.getCurrentTheme()
        return theme.controlBorderColor
    }

    /// Theme-aware base background color
    /// Gold theme uses a warmer, darker tone that complements gold better than blue
    private var themeBaseBackground: Color {
        let theme = MilestoneCelebrationManager.getCurrentTheme()

        switch theme {
        case .gold:
            // Warm dark brown/slate that complements gold
            // HSL roughly: 30°, 20%, 5% - a very dark warm gray with slight brown undertone
            return Color(red: 15/255, green: 12/255, blue: 8/255)
        default:
            // Default deep blue for all other themes
            return Color.retraceBackground
        }
    }

    /// Theme-aware ambient background with subtle glow effects
    private var themeAmbientBackground: some View {
        let theme = MilestoneCelebrationManager.getCurrentTheme()

        // Use custom colors for better contrast against backgrounds
        let ambientGlowColor: Color = {
            switch theme {
            case .blue:
                // Deeper blue orb: #0e2a68
                return Color(red: 14/255, green: 42/255, blue: 104/255)
            case .gold:
                // Warm amber instead of pure gold
                return Color(red: 255/255, green: 160/255, blue: 60/255)
            case .purple:
                return theme.glowColor
            }
        }()

        // Adjust opacity per theme for best visual balance
        // Blue gets moderate opacity - enough presence without being theatrical
        let glowOpacity: Double = {
            switch theme {
            case .blue: return 0.3
            case .gold: return 0.05
            case .purple: return 0.08
            }
        }()
        let edgeGlowOpacity: Double = {
            switch theme {
            case .blue: return 0.6
            case .gold: return 0.04
            case .purple: return 0.06
            }
        }()
        let cornerGlowOpacity: Double = {
            switch theme {
            case .blue: return 0.5
            case .gold: return 0.03
            case .purple: return 0.05
            }
        }()

        return GeometryReader { geometry in
            ZStack {
                // Primary accent orb (top-left) - uses theme color
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.retraceAccent.opacity(0.10), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 300
                        )
                    )
                    .frame(width: 600, height: 600)
                    .offset(x: -200, y: -100)
                    .blur(radius: 60)

                // Secondary orb (top-left) - theme glow color
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [ambientGlowColor.opacity(glowOpacity), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 250
                        )
                    )
                    .frame(width: 500, height: 500)
                    .offset(x: -150, y: -50)
                    .blur(radius: 50)

                // Top edge glow - all themes get this now
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [ambientGlowColor.opacity(edgeGlowOpacity), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .position(x: geometry.size.width / 2, y: 0)
                    .blur(radius: 30)

                // Bottom-right corner glow - all themes get this now
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [ambientGlowColor.opacity(cornerGlowOpacity), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 400
                        )
                    )
                    .frame(width: 800, height: 800)
                    .position(x: geometry.size.width, y: geometry.size.height)
                    .blur(radius: 80)
            }
        }
    }

    private var viewModeToggle: some View {
        HStack(spacing: 4) {
            ForEach(AppUsageViewMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        usageViewMode = mode
                    }
                    saveViewMode(mode)
                }) {
                    Image(systemName: mode.icon)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(usageViewMode == mode ? .retracePrimary : .retraceSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(usageViewMode == mode ? Color.white.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var loadingStateView: some View {
        VStack(spacing: 16) {
            SpinnerView(size: 32, lineWidth: 3)

            Text("Loading activity...")
                .font(.retraceHeadline)
                .foregroundColor(.retraceSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeBorderColor, lineWidth: 1)
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient.retraceAccentGradient.opacity(0.2))
                    .frame(width: 80, height: 80)

                Image(systemName: "clock.badge.questionmark")
                    .font(.retraceDisplay3)
                    .foregroundStyle(LinearGradient.retraceAccentGradient)
            }

            VStack(spacing: 8) {
                Text("No activity recorded yet")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                Text("Start using your Mac and Retrace will track your app usage automatically.")
                    .font(.retraceCallout)
                    .foregroundColor(.retraceSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(Color.white.opacity(0.02))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeBorderColor, lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://dub.sh/haseab-twitter")!) {
                    HStack(spacing: 4) {
                        Text("Made with")
                            .foregroundColor(.retraceSecondary)
                        Text("❤️")
                        Text("by")
                            .foregroundColor(.retraceSecondary)
                        Text("@haseab")
                            .foregroundColor(Color(red: 74/255, green: 144/255, blue: 226/255))  // Bright blue for link
                            .scaleEffect(isHoveringHaseab ? 1.05 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: isHoveringHaseab)
                    }
                    .font(.retraceCaption2Medium)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringHaseab = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                Circle()
                    .fill(Color.retraceSecondary.opacity(0.5))
                    .frame(width: 3, height: 3)

                Link(destination: URL(string: "https://dub.sh/support-haseab")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.retraceCaption2)
                        Text("Support Me")
                    }
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)
                    .scaleEffect(isHoveringSupportMe ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHoveringSupportMe)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringSupportMe = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                Circle()
                    .fill(Color.retraceSecondary.opacity(0.5))
                    .frame(width: 3, height: 3)

                Button(action: { showFeedbackSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.retraceCaption2)
                        Text("Feedback")
                    }
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)
                    .scaleEffect(isHoveringFeedback ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHoveringFeedback)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringFeedback = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                #if DEBUG
                Circle()
                    .fill(Color.retraceSecondary.opacity(0.5))
                    .frame(width: 3, height: 3)

                Menu {
                    Button("Show 10h Milestone") {
                        milestoneCelebrationManager.currentMilestone = .tenHours
                    }
                    Button("Show 100h Milestone") {
                        milestoneCelebrationManager.currentMilestone = .hundredHours
                    }
                    Button("Show 1000h Milestone") {
                        milestoneCelebrationManager.currentMilestone = .thousandHours
                    }
                    Button("Show 10000h Milestone 🐐") {
                        milestoneCelebrationManager.currentMilestone = .tenThousandHours
                    }
                    Divider()
                    Button("Show Launch on Login Banner") {
                        launchOnLoginReminderManager.shouldShowReminder = true
                    }
                    Divider()
                    Menu("Set Color Theme") {
                        Button("Blue") {
                            MilestoneCelebrationManager.setDebugThemeOverride(.blue)
                        }
                        Button("Gold") {
                            MilestoneCelebrationManager.setDebugThemeOverride(.gold)
                        }
                        Button("Purple") {
                            MilestoneCelebrationManager.setDebugThemeOverride(.purple)
                        }
                        Divider()
                        Button("Reset to Saved Theme") {
                            MilestoneCelebrationManager.setDebugThemeOverride(nil)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ant.fill")
                            .font(.retraceCaption2)
                        Text("Debug")
                    }
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.orange)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                #endif
            }

            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: - Formatting Helpers

    private func formatTotalTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func formatScreenTimeFromDaily(_ data: [DailyDataPoint]) -> String {
        // Data is in milliseconds, sum and convert to hours/minutes
        let totalMs = data.reduce(0) { $0 + $1.value }
        let totalMinutes = Int(totalMs / 1000 / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

}

// MARK: - Preview

// MARK: - Scroll Affordance

/// A subtle inner shadow at the bottom of a container that suggests scrollable content continues
/// This is the Apple-favorite pattern for indicating scrollability
private struct ScrollAffordance: View {
    var height: CGFloat = 24
    var color: Color = .black

    var body: some View {
        VStack {
            Spacer()
            LinearGradient(
                colors: [
                    color.opacity(0),
                    color.opacity(0.4),
                    color.opacity(0.6)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Logo Triangle Shape

/// Triangle shape pointing right (like a play button) for the Retrace logo
private struct LogoTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Points: left-top, left-bottom, right-center
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

#if DEBUG
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        let launchOnLoginManager = LaunchOnLoginReminderManager(coordinator: coordinator)
        let milestoneManager = MilestoneCelebrationManager(coordinator: coordinator)

        DashboardView(
            coordinator: coordinator,
            launchOnLoginReminderManager: launchOnLoginManager,
            milestoneCelebrationManager: milestoneManager
        )
        .frame(width: 1200, height: 900)
        .preferredColorScheme(.dark)
    }
}
#endif
