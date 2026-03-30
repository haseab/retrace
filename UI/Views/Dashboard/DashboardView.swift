import SwiftUI
import Darwin
import Shared
import App

// MARK: - Layout Size

/// Fixed layout size for dashboard stat cards
/// Content stays at a consistent size and centers in the window
private enum LayoutSize {
    case normal

    static func from(width: CGFloat) -> LayoutSize {
        return .normal
    }

    // MARK: - Card Dimensions

    var cardWidth: CGFloat { 280 }
    var graphHeight: CGFloat { 70 }

    // MARK: - Icon Sizes

    var iconCircleSize: CGFloat { 44 }
    var iconFont: Font { .retraceHeadline }

    // MARK: - Text Fonts

    var titleFont: Font { .retraceCaption2Medium }
    var valueFont: Font { .retraceMediumNumber }
    var subtitleFont: Font { .retraceCaption2Medium }

    // MARK: - Spacing & Padding

    var iconSpacing: CGFloat { 14 }
    var textSpacing: CGFloat { 2 }
    var cardPadding: CGFloat { 16 }
    var graphHorizontalPadding: CGFloat { 12 }
    var graphBottomPadding: CGFloat { 8 }
}

/// Maximum width for the dashboard content area before it centers
private let dashboardMaxWidth: CGFloat = 1100
/// Shared breakpoint for compact dashboard-style layouts.
let dashboardCompactLayoutThreshold: CGFloat = 850
private let dashboardSettingsStore: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

private struct RecordingIndicatorAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Main dashboard view - analytics and statistics
/// Default landing screen
public struct DashboardView: View {

    // MARK: - Properties

    @ObservedObject var viewModel: DashboardViewModel
    @StateObject private var coordinatorWrapper: AppCoordinatorWrapper
    @StateObject private var crashRecoveryBannerModel: CrashRecoveryBannerModel
    @ObservedObject var launchOnLoginReminderManager: LaunchOnLoginReminderManager
    @ObservedObject var milestoneCelebrationManager: MilestoneCelebrationManager
    @ObservedObject private var updaterManager = UpdaterManager.shared
    @State private var isPulsing = false
    @State private var showFeedbackSheet = false
    @State private var feedbackLaunchContext: FeedbackLaunchContext?
    @State private var feedbackPresentationID = UUID()
    @AppStorage("dashboardAppUsageViewMode", store: dashboardSettingsStore)
    private var usageViewModeRawValue: String = AppUsageViewMode.list.rawValue
    @State private var selectedApp: AppUsageData? = nil
    @State private var selectedWindow: WindowUsageData? = nil
    @State private var showSessionsSheet = false
    @State private var showSystemMonitor = false
    @State private var showAppUsageDatePopover = false
    @State private var showDiscordFollowup = false
    @State private var currentTheme: MilestoneCelebrationManager.ColorTheme = MilestoneCelebrationManager.getCurrentTheme()
    @Binding var hasLoadedInitialData: Bool

    enum AppUsageViewMode: String {
        case list = "list"
        case hardDrive = "squares"
    }

    enum AppUsageSectionBodyState: Equatable {
        case loading
        case empty
        case content
    }

    struct AppUsageEmptyStateCopy: Equatable {
        let title: String
        let message: String
        let symbolName: String
    }

    private static let pauseMenuWidth: CGFloat = 100

    static func appUsageSectionBodyState(
        isLoading: Bool,
        hasAppUsageData: Bool
    ) -> AppUsageSectionBodyState {
        if isLoading && !hasAppUsageData {
            return .loading
        }

        return hasAppUsageData ? .content : .empty
    }

    static func appUsageEmptyStateCopy(
        rangeLabel: String,
        hasRecordedActivity: Bool
    ) -> AppUsageEmptyStateCopy {
        if hasRecordedActivity {
            return AppUsageEmptyStateCopy(
                title: "No app usage found",
                message: "Nothing was recorded for \(rangeLabel). Use the arrows or date picker above to try another range.",
                symbolName: "tray"
            )
        }

        return AppUsageEmptyStateCopy(
            title: "No activity recorded yet",
            message: "Start using your Mac and Retrace will track your app usage automatically.",
            symbolName: "clock.badge.questionmark"
        )
    }

    private var usageViewMode: AppUsageViewMode {
        AppUsageViewMode(rawValue: usageViewModeRawValue) ?? .list
    }

    private var hasPreStorageBanner: Bool {
        viewModel.showAccessibilityWarning
            || viewModel.showScreenRecordingWarning
            || launchOnLoginReminderManager.shouldShowReminder
            || crashRecoveryBannerModel.state != nil
    }

    private var hasPreWALFailureBanner: Bool {
        hasPreStorageBanner || viewModel.storageHealthBanner != nil
    }

    private var hasPreCrashBanner: Bool {
        hasPreWALFailureBanner || viewModel.recentWALFailureCrash != nil
    }

    // MARK: - Initialization

    public init(
        viewModel: DashboardViewModel,
        coordinator: AppCoordinator,
        launchOnLoginReminderManager: LaunchOnLoginReminderManager,
        milestoneCelebrationManager: MilestoneCelebrationManager,
        hasLoadedInitialData: Binding<Bool> = .constant(false)
    ) {
        self.viewModel = viewModel
        _coordinatorWrapper = StateObject(wrappedValue: AppCoordinatorWrapper(coordinator: coordinator))
        _crashRecoveryBannerModel = StateObject(
            wrappedValue: CrashRecoveryBannerModel(coordinator: coordinator)
        )
        self.launchOnLoginReminderManager = launchOnLoginReminderManager
        self.milestoneCelebrationManager = milestoneCelebrationManager
        self._hasLoadedInitialData = hasLoadedInitialData
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
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
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
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
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
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, (viewModel.showAccessibilityWarning || viewModel.showScreenRecordingWarning) ? 12 : 20)
            }

            if let statusBanner = crashRecoveryBannerModel.state {
                CrashRecoveryStatusBanner(
                    state: statusBanner,
                    onOpenSettings: statusBanner.showsOpenSettingsAction ? {
                        crashRecoveryBannerModel.openSettings()
                    } : nil,
                    onRetry: {
                        crashRecoveryBannerModel.retry()
                    },
                    onDismiss: {
                        crashRecoveryBannerModel.dismiss()
                    }
                )
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(
                    .top,
                    (viewModel.showAccessibilityWarning
                        || viewModel.showScreenRecordingWarning
                        || launchOnLoginReminderManager.shouldShowReminder) ? 12 : 20
                )
            }

            if let storageHealthBanner = viewModel.storageHealthBanner {
                StorageHealthBanner(
                    state: storageHealthBanner,
                    onDismiss: {
                        viewModel.dismissStorageHealthBanner()
                    }
                )
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, hasPreStorageBanner ? 12 : 20)
            }

            if let recentWALFailureCrash = viewModel.recentWALFailureCrash {
                WALFailureCrashBanner(
                    report: recentWALFailureCrash,
                    onSubmitBugReport: {
                        presentFeedbackSheet(
                            launchContext: DashboardViewModel.makeWALFailureFeedbackLaunchContext(
                                for: recentWALFailureCrash
                            )
                        )
                    },
                    onDetails: {
                        viewModel.recordRecentWALFailureCrashDetailsOpened()
                        NSWorkspace.shared.selectFile(
                            recentWALFailureCrash.fileURL.path,
                            inFileViewerRootedAtPath: recentWALFailureCrash.fileURL.deletingLastPathComponent().path
                        )
                    },
                    onDismiss: {
                        viewModel.dismissRecentWALFailureCrash()
                    }
                )
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, hasPreWALFailureBanner ? 12 : 20)
            }

            if let recentCrashReport = viewModel.recentCrashReport {
                CrashReportBanner(
                    report: recentCrashReport,
                    onSubmitBugReport: {
                        presentFeedbackSheet(
                            launchContext: DashboardViewModel.makeCrashFeedbackLaunchContext(
                                for: recentCrashReport
                            )
                        )
                    },
                    onDetails: {
                        viewModel.recordRecentCrashReportDetailsOpened()
                        NSWorkspace.shared.selectFile(
                            recentCrashReport.fileURL.path,
                            inFileViewerRootedAtPath: recentCrashReport.fileURL.deletingLastPathComponent().path
                        )
                    },
                    onDismiss: {
                        viewModel.dismissRecentCrashReport()
                    }
                )
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, hasPreCrashBanner ? 12 : 20)
            }

            // Header
            header
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 32)

            // Two-column layout: metrics on left, app usage on right
            // This section expands to fill remaining height
            GeometryReader { geometry in
                let layoutSize = LayoutSize.from(width: geometry.size.width)
                let isCompactLayout = geometry.size.width < dashboardCompactLayoutThreshold

                HStack(alignment: .top, spacing: isCompactLayout ? 0 : 24) {
                    if !isCompactLayout {
                        // Left column: Stats cards (single column, fixed width)
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
                                            theme: currentTheme,
                                            valueFormatter: card.valueFormatter,
                                            layoutSize: layoutSize
                                        )
                                    }
                                }
                                .padding(.top, 2)
                                .padding(.bottom, 20) // Extra padding for scroll affordance
                            }

                            ScrollAffordance(height: 32, color: themeBaseBackground)
                        }
                        .frame(width: layoutSize.cardWidth)
                    }

                    // Right column: App usage (scrolls internally)
                    appUsageSection(layoutSize: layoutSize)
                }
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            // Footer
            footer
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .sheet(
            isPresented: $showFeedbackSheet,
            onDismiss: {
                feedbackLaunchContext = nil
            }
        ) {
            FeedbackFormView(launchContext: feedbackLaunchContext)
                .id(feedbackPresentationID)
            .environmentObject(coordinatorWrapper)
        }
        .background(
            ZStack {
                // Theme-aware base background color
                themeBaseBackground

                // Theme-aware ambient glow background
                themeAmbientBackground
            }
            .ignoresSafeArea()
        )
        .background(
            Button("") {
                Task { await viewModel.loadStatistics() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
        )
        .task {
            viewModel.isWindowVisible = true
            crashRecoveryBannerModel.refresh()
            if !hasLoadedInitialData {
                hasLoadedInitialData = true
                Log.debug("[Dashboard] Initial load - first appearance", category: .ui)
                await viewModel.loadStatistics()
            } else {
                Log.debug("[Dashboard] Tab switch - skipping reload", category: .ui)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDidBecomeKey)) { _ in
            Log.debug("[Dashboard] Window became key - refreshing", category: .ui)
            Task { await viewModel.loadStatistics() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDidOpen)) { _ in
            viewModel.isWindowVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDidClose)) { _ in
            viewModel.isWindowVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .colorThemeDidChange)) { notification in
            if let newTheme = notification.object as? MilestoneCelebrationManager.ColorTheme {
                currentTheme = newTheme
            }
        }
        .overlayPreferenceValue(RecordingIndicatorAnchorPreferenceKey.self) { anchor in
            GeometryReader { proxy in
                if showPauseOptionsPopover, let anchor {
                    let anchorRect = proxy[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    showPauseOptionsPopover = false
                                }
                            }

                        pauseRecordingMenu
                            .frame(width: Self.pauseMenuWidth)
                            .offset(
                                x: pauseMenuOriginX(
                                    anchorRect: anchorRect,
                                    containerWidth: proxy.size.width,
                                    menuWidth: Self.pauseMenuWidth
                                ),
                                y: anchorRect.maxY + 6
                            )
                            .transition(
                                .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .zIndex(showPauseOptionsPopover ? 20 : 0)
        }
        .overlay {
            // Sessions detail overlay (replaces .sheet for faster presentation)
            if showSessionsSheet, let app = selectedApp {
                ZStack {
                    // Dimmed background
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showSessionsSheet = false
                            }
                        }

                    // Sessions detail dialog
                    Group {
                        if let window = selectedWindow {
                            // Window-filtered sessions
                            AppSessionsDetailView(
                                app: app,
                                onOpenInTimeline: { date in
                                    showSessionsSheet = false
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
                                subtitle: window.displayName,
                                onDismiss: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        showSessionsSheet = false
                                    }
                                }
                            )
                        } else {
                            // All sessions for app
                            AppSessionsDetailView(
                                app: app,
                                onOpenInTimeline: { date in
                                    showSessionsSheet = false
                                    openTimelineAt(date: date)
                                },
                                loadSessions: { offset, limit in
                                    await viewModel.getSessionsForApp(
                                        bundleID: app.appBundleID,
                                        offset: offset,
                                        limit: limit
                                    )
                                },
                                onDismiss: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        showSessionsSheet = false
                                    }
                                }
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 10)
                    .transition(.scale.combined(with: .opacity))
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSessionsSheet)
            }
        }
        .overlay {
            ZStack {
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
                            onMaybeLater: {
                                milestoneCelebrationManager.dismissCurrentMilestone()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showDiscordFollowup = true
                                }
                            },
                            onSupport: {
                                milestoneCelebrationManager.openSupportLink()
                            }
                        )
                        .transition(.scale.combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: milestone)
                }

                if showDiscordFollowup {
                    ZStack {
                        Color.black.opacity(0.65)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showDiscordFollowup = false
                                }
                            }

                        DiscordFollowupView(
                            onJoin: {
                                milestoneCelebrationManager.openDiscordLink()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showDiscordFollowup = false
                                }
                            },
                            onMaybeLater: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showDiscordFollowup = false
                                }
                            }
                        )
                        .transition(.scale.combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showDiscordFollowup)
                }
            }
        }
    }

    // MARK: - App Session Actions

    private func handleAppTapped(_ app: AppUsageData) {
        selectedApp = app
        selectedWindow = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showSessionsSheet = true
        }
    }

    private func handleWindowTapped(_ app: AppUsageData, _ window: WindowUsageData) {
        let clickStartTime = CFAbsoluteTimeGetCurrent()
        let selectedRange = viewModel.appUsageQueryRange

        // Launch filtered timeline instantly instead of showing sessions dialog
        TimelineWindowController.shared.showWithFilter(
            bundleID: app.appBundleID,
            windowName: window.windowName,
            browserUrl: window.browserUrl,
            startDate: selectedRange.start,
            endDate: selectedRange.end,
            clickStartTime: clickStartTime
        )
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
                openTimelineButton
                monitorButton
                if updaterManager.shouldShowWhatsNew {
                    changelogButton
                }
                settingsButton
            }
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
            .padding(.vertical, label != nil ? 8 : 10)
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

    @State private var isHoveringTimeline = false
    @State private var isHoveringSettings = false
    @State private var settingsRotation: Double = 0

    // MARK: - Footer Hover States

    @State private var isHoveringHaseab = false
    @State private var isHoveringSupportMe = false
    @State private var isHoveringFeedback = false

    // MARK: - Timeline Button

    private var openTimelineButton: some View {
        Button(action: {
            TimelineWindowController.shared.show()
        }) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.retraceCalloutMedium)
                .foregroundColor(.retraceSecondary)
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
        .scaleEffect(isHoveringTimeline ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHoveringTimeline)
        .compactTopTooltip("Open Timeline", isVisible: $isHoveringTimeline)
        .onHover { hovering in
            isHoveringTimeline = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Monitor Button

    private var monitorButton: some View {
        MonitorButton(isProcessing: viewModel.ocrQueueDepth > 0)
    }

    // MARK: - Changelog Button

    private var changelogButton: some View {
        actionButton(icon: "sparkles", label: "What's New") {
            NotificationCenter.default.post(
                name: .openDashboard,
                object: nil,
                userInfo: ["target": "changelog"]
            )
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
        .scaleEffect(isHoveringSettings ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHoveringSettings)
        .compactTopTooltip("Open Settings", isVisible: $isHoveringSettings)
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
    @State private var showPauseOptionsPopover = false

    private var recordingIndicator: some View {
        Button(action: {
            if viewModel.isRecording {
                withAnimation(.easeOut(duration: 0.12)) {
                    showPauseOptionsPopover.toggle()
                }
            } else {
                Task {
                    await viewModel.toggleRecording(to: true)
                }
            }
        }) {
            HStack(spacing: 6) {
                if viewModel.isRecording && isHoveringRecordingIndicator {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 6)
                        .transition(.opacity)
                } else if viewModel.recordingPauseRemainingSeconds != nil {
                    Image(systemName: "timer")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 8)
                        .transition(.opacity)
                } else if viewModel.isRecordingPaused {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 8)
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
                    .frame(width: 74, alignment: .center)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
        .anchorPreference(key: RecordingIndicatorAnchorPreferenceKey.self, value: .bounds) { $0 }
        // .instantTooltip("Toggle Recording  ⌘⇧R", isVisible: $isHoveringRecordingIndicator)
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
        } else if let seconds = viewModel.recordingPauseRemainingSeconds {
            return isHoveringRecordingIndicator ? "Start Rec." : formatPauseCountdown(seconds)
        } else if viewModel.isRecordingPaused {
            return isHoveringRecordingIndicator ? "Start Rec." : "Paused"
        } else {
            return isHoveringRecordingIndicator ? "Start Rec." : "Off"
        }
    }

    private func formatPauseCountdown(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let remainingSeconds = clamped % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private var pauseRecordingMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            PauseMenuOptionRow(title: "5 min") {
                handlePauseSelection(duration: 5 * 60)
            }
            PauseMenuOptionRow(title: "30 min") {
                handlePauseSelection(duration: 30 * 60)
            }
            PauseMenuOptionRow(title: "60 min") {
                handlePauseSelection(duration: 60 * 60)
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 1)

            PauseMenuOptionRow(title: "Turn Off") {
                handlePauseSelection(duration: nil)
            }
        }
        .padding(4)
        .retraceMenuContainer(addPadding: false)
    }

    private func handlePauseSelection(duration: TimeInterval?) {
        withAnimation(.easeOut(duration: 0.12)) {
            showPauseOptionsPopover = false
        }
        Task {
            await viewModel.pauseRecording(for: duration)
        }
    }

    private func pauseMenuOriginX(anchorRect: CGRect, containerWidth: CGFloat, menuWidth: CGFloat) -> CGFloat {
        let horizontalPadding: CGFloat = 16
        let desiredX = anchorRect.minX
        return min(
            max(horizontalPadding, desiredX),
            max(horizontalPadding, containerWidth - menuWidth - horizontalPadding)
        )
    }

    private struct PauseMenuOptionRow: View {
        let title: String
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(isHovering ? .white : .white.opacity(0.78))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovering ? Color.white.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    isHovering = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
    }

    // MARK: - Stats Cards Row

    private struct StatCardData: Identifiable {
        let id: String
        let icon: String
        let title: String
        let value: String
        let subtitle: String
        let graphData: [DailyDataPoint]?
        let graphColor: Color
        let valueFormatter: ((Int64) -> String)?

        init(icon: String, title: String, value: String, subtitle: String, graphData: [DailyDataPoint]? = nil, graphColor: Color = .retraceAccent, valueFormatter: ((Int64) -> String)? = nil) {
            self.id = title
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
        let selectedRangeLabel = viewModel.appUsageRangeLabel
        let isDefaultLastSevenDays = viewModel.isDefaultAppUsageRangeSelected
        let activitySubtitle = isDefaultLastSevenDays ? "Last 7 days" : selectedRangeLabel
        let daysRecordedTitle = isDefaultLastSevenDays ? "Total Days Recorded" : "Days Recorded"
        let daysRecordedSubtitle = formatRecordedHoursSubtitle(
            isDefaultLastSevenDays ? viewModel.totalCapturedDuration : viewModel.totalWeeklyTime
        )
        let storageTitle = isDefaultLastSevenDays ? "Total Storage Used" : "Storage Used"
        let storageValue = formatStorageSize(isDefaultLastSevenDays ? viewModel.totalStorageBytes : viewModel.weeklyStorageBytes)
        let storageSubtitle = isDefaultLastSevenDays ? formatStoragePerMonth() : selectedRangeLabel
        let totalDaysValue = isDefaultLastSevenDays ? viewModel.daysRecorded : viewModel.appUsageRangeDaySpan

        return [
            StatCardData(
                icon: "calendar",
                title: daysRecordedTitle,
                value: "\(totalDaysValue) days",
                subtitle: daysRecordedSubtitle
            ),
            StatCardData(
                icon: "clock.fill",
                title: "Screen Time",
                value: formatScreenTimeFromDaily(viewModel.dailyScreenTimeData),
                subtitle: activitySubtitle,
                graphData: viewModel.dailyScreenTimeData.isEmpty ? nil : viewModel.dailyScreenTimeData,
                graphColor: .blue,
                valueFormatter: { milliseconds in
                    let hours = Double(milliseconds) / 1000.0 / 3600.0
                    return String(format: "%.1fh", hours)
                }
            ),
            StatCardData(
                icon: "externaldrive.fill",
                title: storageTitle,
                value: storageValue,
                subtitle: storageSubtitle,
                graphData: viewModel.dailyStorageData.isEmpty ? nil : viewModel.dailyStorageData,
                graphColor: .cyan
            ),
            StatCardData(
                icon: "timelapse",
                title: "Timeline Opens",
                value: "\(viewModel.timelineOpensThisWeek)",
                subtitle: activitySubtitle,
                graphData: viewModel.dailyTimelineOpensData.isEmpty ? nil : viewModel.dailyTimelineOpensData,
                graphColor: .purple
            ),
            StatCardData(
                icon: "magnifyingglass",
                title: "Searches",
                value: "\(viewModel.searchesThisWeek)",
                subtitle: activitySubtitle,
                graphData: viewModel.dailySearchesData.isEmpty ? nil : viewModel.dailySearchesData,
                graphColor: .orange
            ),
            StatCardData(
                icon: "doc.on.doc",
                title: "Text Copies",
                value: "\(viewModel.textCopiesThisWeek)",
                subtitle: activitySubtitle,
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

        // Estimate based on current loaded daily storage series.
        let totalBytes = dailyData.reduce(0) { $0 + $1.value }
        let daysWithData = dailyData.count
        let bytesPerDay = Double(totalBytes) / Double(daysWithData)
        let bytesPerMonth = bytesPerDay * 30.0
        let gbPerMonth = bytesPerMonth / 1_000_000_000
        return String(format: "est. %.1f GB/month", gbPerMonth)
    }

    // MARK: - App Usage Section

    private func appUsageSection(layoutSize: LayoutSize) -> some View {
        let appUsageLayout: AppUsageLayoutSize = .normal

        return VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text("App Usage")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                Spacer()

                appUsageRangeControls
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .zIndex(showAppUsageDatePopover ? 10 : 1)

            Divider()
                .background(Color.white.opacity(0.06))
                .zIndex(showAppUsageDatePopover ? 9 : 0)

            appUsageSectionBody(layoutSize: appUsageLayout)
        }
        .background(Color.white.opacity(0.03))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeBorderColor.opacity(1.2), lineWidth: 1.2)
        )
    }

    @ViewBuilder
    private func appUsageSectionBody(layoutSize: AppUsageLayoutSize) -> some View {
        switch Self.appUsageSectionBodyState(
            isLoading: viewModel.isLoading,
            hasAppUsageData: !viewModel.weeklyAppUsage.isEmpty
        ) {
        case .loading:
            appUsageLoadingBody
        case .empty:
            appUsageEmptyBody
        case .content:
            switch usageViewMode {
            case .list:
                AppUsageListView(
                    apps: viewModel.weeklyAppUsage,
                    totalTime: viewModel.totalWeeklyTime,
                    layoutSize: layoutSize,
                    loadWindowUsage: { bundleID in
                        await viewModel.getWindowUsageForApp(bundleID: bundleID)
                    },
                    loadTabsForDomain: { bundleID, domain in
                        await viewModel.getBrowserTabsForDomain(bundleID: bundleID, domain: domain)
                    },
                    onWindowTapped: { app, window in
                        handleWindowTapped(app, window)
                    }
                )
                .id(
                    "app-usage-list-\(Int(viewModel.appUsageRangeStart.timeIntervalSince1970))-\(Int(viewModel.appUsageRangeEnd.timeIntervalSince1970))"
                )
                .zIndex(0)
            case .hardDrive:
                AppUsageHardDriveView(
                    apps: viewModel.weeklyAppUsage,
                    totalTime: viewModel.totalWeeklyTime,
                    onAppTapped: { app in
                        handleAppTapped(app)
                    }
                )
                .id(
                    "app-usage-hard-drive-\(Int(viewModel.appUsageRangeStart.timeIntervalSince1970))-\(Int(viewModel.appUsageRangeEnd.timeIntervalSince1970))"
                )
                .zIndex(0)
            }
        }
    }

    private var themeBorderColor: Color {
        currentTheme.controlBorderColor
    }

    /// Theme-aware base background color
    /// Gold theme uses a warmer, darker tone that complements gold better than blue
    private var themeBaseBackground: Color {
        switch currentTheme {
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
        let theme = currentTheme

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

    private var appUsageRangeControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                rangeShiftButton(
                    icon: "chevron.left",
                    position: .leading,
                    isEnabled: viewModel.canShiftAppUsageRangeBackward
                ) {
                    Task {
                        await viewModel.shiftAppUsageDateRange(
                            by: -1,
                            source: "dashboard_app_usage_previous_range"
                        )
                    }
                }

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 30)

                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showAppUsageDatePopover.toggle()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.retraceCaption2Medium)
                        Text(viewModel.appUsageRangeLabel)
                            .font(.retraceCaptionMedium)
                    }
                    .foregroundColor(.retraceSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(showAppUsageDatePopover ? Color.white.opacity(0.06) : Color.clear)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .dropdownOverlay(
                    isPresented: $showAppUsageDatePopover,
                    yOffset: 38,
                    horizontalAnchor: .trailing
                ) {
                    DateRangeFilterPopover(
                        dateRanges: [viewModel.appUsageDateRange],
                        onApply: { ranges in
                            withAnimation(.easeOut(duration: 0.15)) {
                                showAppUsageDatePopover = false
                            }
                            guard let selectedRange = ranges.first else { return }
                            Task {
                                await viewModel.setAppUsageDateRange(
                                    from: selectedRange,
                                    source: "dashboard_app_usage_calendar_apply"
                                )
                            }
                        },
                        onClear: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showAppUsageDatePopover = false
                            }
                            Task {
                                await viewModel.resetAppUsageDateRangeToDefault(
                                    source: "dashboard_app_usage_calendar_clear"
                                )
                            }
                        },
                        width: 300,
                        enableKeyboardNavigation: true,
                        allowMultipleRanges: false,
                        maxRangeDays: DashboardViewModel.maxAppUsageRangeDays,
                        onQuickPresetShortcut: { preset in
                            viewModel.recordKeyboardShortcut("dashboard.app_usage_date_range.\(preset.rawValue)")
                        },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showAppUsageDatePopover = false
                            }
                        }
                    )
                }

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 30)

                rangeShiftButton(
                    icon: "chevron.right",
                    position: .trailing,
                    isEnabled: viewModel.canShiftAppUsageRangeForward
                ) {
                    Task {
                        await viewModel.shiftAppUsageDateRange(
                            by: 1,
                            source: "dashboard_app_usage_next_range"
                        )
                    }
                }
            }
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 8,
                    bottomLeadingRadius: 8,
                    bottomTrailingRadius: 8,
                    topTrailingRadius: 8
                )
                .fill(Color.white.opacity(0.06))
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 8,
                    bottomLeadingRadius: 8,
                    bottomTrailingRadius: 8,
                    topTrailingRadius: 8
                )
                .stroke(Color.white.opacity(showAppUsageDatePopover ? 0.22 : 0.1), lineWidth: 1)
            )
        }
    }

    private enum RangeShiftButtonPosition {
        case leading
        case trailing
    }

    private func rangeShiftButton(
        icon: String,
        position: RangeShiftButtonPosition,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.retraceSecondary.opacity(isEnabled ? 0.9 : 0.35))
                .frame(width: 30, height: 30)
                .background(
                    Group {
                        if position == .leading {
                            UnevenRoundedRectangle(
                                topLeadingRadius: 8,
                                bottomLeadingRadius: 8,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 0
                            )
                            .fill(Color.white.opacity(isEnabled ? 0.03 : 0.01))
                        } else {
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: 8,
                                topTrailingRadius: 8
                            )
                            .fill(Color.white.opacity(isEnabled ? 0.03 : 0.01))
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            guard isEnabled else { return }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var appUsageLoadingBody: some View {
        return VStack(spacing: 16) {
            SpinnerView(size: 32, lineWidth: 3)

            Text("Loading activity...")
                .font(.retraceHeadline)
                .foregroundColor(.retraceSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }

    private var appUsageEmptyBody: some View {
        let copy = Self.appUsageEmptyStateCopy(
            rangeLabel: viewModel.appUsageRangeLabel,
            hasRecordedActivity: viewModel.daysRecorded > 0
        )

        return VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient.retraceAccentGradient.opacity(0.2))
                    .frame(width: 80, height: 80)

                Image(systemName: copy.symbolName)
                    .font(.retraceDisplay3)
                    .foregroundStyle(LinearGradient.retraceAccentGradient)
            }

            VStack(spacing: 8) {
                Text(copy.title)
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                Text(copy.message)
                    .font(.retraceCallout)
                    .foregroundColor(.retraceSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
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

                Button(action: {
                    presentFeedbackSheet()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                            .font(.retraceCalloutMedium)
                        Text("Help")
                            .font(.retraceCaptionMedium)
                    }
                    .foregroundColor(.retraceSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .scaleEffect(isHoveringFeedback ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHoveringFeedback)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .onHover { hovering in
                    isHoveringFeedback = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                Circle()
                    .fill(Color.retraceSecondary.opacity(0.5))
                    .frame(width: 3, height: 3)

                Group {
                    if let url = BuildInfo.commitURL {
                        Text(BuildInfo.displayVersion)
                            .onTapGesture { NSWorkspace.shared.open(url) }
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                    } else {
                        Text(BuildInfo.displayVersion)
                    }
                }
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary.opacity(0.5))

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
                    Button("Show Low Storage Banner") {
                        viewModel.showDebugStorageHealthBanner(
                            severity: .warning,
                            availableGB: 4.25,
                            shouldStop: false
                        )
                    }
                    Button("Show Critical Storage Banner") {
                        viewModel.showDebugStorageHealthBanner(
                            severity: .critical,
                            availableGB: 1.10,
                            shouldStop: false
                        )
                    }
                    Button("Show Storage Stop Banner") {
                        viewModel.showDebugStorageHealthBanner(
                            severity: .critical,
                            availableGB: 0.28,
                            shouldStop: true
                        )
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
                    Divider()
                    Button("Trigger Crash (SIGABRT)") {
                        triggerDebugCrash()
                    }
                    Button("Trigger Forced Termination (SIGKILL)") {
                        triggerDebugForcedTermination()
                    }
                    Button("Trigger Watchdog Hang (15s)") {
                        triggerDebugWatchdogHang()
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

    private func formatRecordedHoursSubtitle(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0 hours on Retrace" }

        let roundedHours = Int((seconds / 3600).rounded())
        let hours = max(0, roundedHours)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0

        let hoursText = formatter.string(from: NSNumber(value: hours))
            ?? String(hours)

        return "\(hoursText) \(hours == 1 ? "hour" : "hours") on Retrace"
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

    private func triggerDebugWatchdogHang() {
        DashboardViewModel.recordDebugWatchdogHangTriggered(coordinator: coordinatorWrapper.coordinator)
        Log.warning("[DEBUG] Scheduling intentional main-thread hang to exercise watchdog auto-quit", category: .ui)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // DEBUG-only: intentionally block the main thread long enough to trigger
            // the watchdog auto-quit/relaunch path and generate a watchdog report.
            Thread.sleep(forTimeInterval: 15)
        }
    }

    private func triggerDebugCrash() {
        DashboardViewModel.recordDebugCrashTriggered(coordinator: coordinatorWrapper.coordinator)
        Log.warning("[DEBUG] Scheduling intentional SIGABRT to exercise crash-report generation and crash recovery", category: .ui)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            Darwin.abort()
        }
    }

    private func triggerDebugForcedTermination() {
        DashboardViewModel.recordDebugForcedTerminationTriggered(coordinator: coordinatorWrapper.coordinator)
        Log.warning("[DEBUG] Scheduling intentional SIGKILL to exercise forced-termination recovery without crash diagnostics", category: .ui)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            Darwin.kill(getpid(), SIGKILL)
        }
    }

    private func presentFeedbackSheet(launchContext: FeedbackLaunchContext? = nil) {
        Log.info(
            "[FeedbackSheet] dashboard presentFeedbackSheet source=\(launchContext?.source.rawValue ?? FeedbackLaunchContext.Source.manual.rawValue) " +
            "showFeedbackSheet(before)=\(showFeedbackSheet)",
            category: .ui
        )
        feedbackLaunchContext = launchContext
        feedbackPresentationID = UUID()
        if launchContext?.source == .crashBanner {
            viewModel.recordRecentCrashReportFeedbackOpened()
        } else if launchContext?.source == .walFailureCrashBanner {
            viewModel.recordRecentWALFailureCrashFeedbackOpened()
        } else {
            DashboardViewModel.recordHelpOpened(
                coordinator: coordinatorWrapper.coordinator,
                source: "dashboard_footer"
            )
        }
        showFeedbackSheet = true
        Log.info(
            "[FeedbackSheet] dashboard presentFeedbackSheet showFeedbackSheet(after)=\(showFeedbackSheet) " +
            "feedbackPresentationID=\(feedbackPresentationID)",
            category: .ui
        )
    }

}

// MARK: - Preview

private struct CrashReportBanner: View {
    let report: DashboardCrashReportSummary
    let onSubmitBugReport: () -> Void
    let onDetails: () -> Void
    let onDismiss: () -> Void

    private var messageText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let timestamp = formatter.string(from: report.capturedAt)
        switch report.source {
        case .watchdogAutoQuit:
            return "Retrace auto-quit after a recent freeze at \(timestamp). Please submit a bug report."
        case .macOSDiagnosticReport:
            return "macOS saved a recent Retrace crash report at \(timestamp). Please submit a bug report."
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundColor(.orange)
                .font(.retraceTitle3)

            Text(messageText)
                .font(.retraceCaption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button("Details", action: onDetails)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .buttonStyle(.plain)

                Button("Submit Bug Report", action: onSubmitBugReport)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.9))
                    .cornerRadius(6)
                    .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.retraceHeadline)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            Color(red: 0.42, green: 0.18, blue: 0.11).opacity(0.22)
        )
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct CrashRecoveryStatusBanner: View {
    let state: CrashRecoveryStatusBannerState
    let onOpenSettings: (() -> Void)?
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                .foregroundColor(.orange)
                .font(.retraceTitle3)

            Text(state.messageText)
                .font(.retraceCaption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                if let onOpenSettings {
                    Button("Open Settings", action: onOpenSettings)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .buttonStyle(.plain)
                }

                Button("Retry", action: onRetry)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.9))
                    .cornerRadius(6)
                    .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.retraceHeadline)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct WALFailureCrashBanner: View {
    let report: WALFailureCrashReportSummary
    let onSubmitBugReport: () -> Void
    let onDetails: () -> Void
    let onDismiss: () -> Void

    private var messageText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Retrace couldn't complete recovery at \(formatter.string(from: report.capturedAt)). New recordings may fail until storage is repaired."
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundColor(.orange)
                .font(.retraceTitle3)

            Text(messageText)
                .font(.retraceCaption)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button("Details", action: onDetails)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .buttonStyle(.plain)

                Button("Submit Bug Report", action: onSubmitBugReport)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.9))
                    .cornerRadius(6)
                    .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.retraceHeadline)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            Color(red: 0.42, green: 0.18, blue: 0.11).opacity(0.22)
        )
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct StorageHealthBanner: View {
    let state: StorageHealthBannerState
    let onDismiss: () -> Void

    private var accentColor: Color {
        state.shouldStop ? .red : .orange
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.shouldStop ? "externaldrive.fill.badge.xmark" : "externaldrive.badge.exclamationmark")
                .foregroundColor(accentColor)
                .font(.retraceTitle3)

            Text(state.messageText)
                .font(.retraceCaption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.retraceHeadline)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            (state.shouldStop ? Color.red : Color.orange).opacity(0.16)
        )
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentColor.opacity(0.28), lineWidth: 1)
        )
    }
}

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

// MARK: - Monitor Button (isolated to prevent parent re-renders)

/// Extracted to its own view so animation state changes don't cause DashboardView to re-render
private struct MonitorButton: View {
    let isProcessing: Bool

    @State private var heartbeatScale: CGFloat = 1.0
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
        }) {
            ZStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(isProcessing ? .green : .retraceSecondary)
                    .scaleEffect(isProcessing ? heartbeatScale : 1.0)
            }
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
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .compactTopTooltip("Open System Monitor", isVisible: $isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .task(id: isProcessing) {
            // Heartbeat animation - quick expand then contract like a health monitor
            while !Task.isCancelled {
                if isProcessing {
                    // Beat 1: quick expand
                    withAnimation(.easeOut(duration: 0.1)) {
                        heartbeatScale = 1.25
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(100_000_000)), clock: .continuous)

                    // Contract back
                    withAnimation(.easeIn(duration: 0.15)) {
                        heartbeatScale = 1.05
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(150_000_000)), clock: .continuous)

                    // Beat 2: smaller secondary beat
                    withAnimation(.easeOut(duration: 0.08)) {
                        heartbeatScale = 1.15
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(80_000_000)), clock: .continuous)

                    // Contract and rest
                    withAnimation(.easeIn(duration: 0.2)) {
                        heartbeatScale = 1.05
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(600_000_000)), clock: .continuous)
                } else {
                    heartbeatScale = 1.0
                    try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous)
                }
            }
        }
    }
}

// MARK: - Compact Tooltip

private struct CompactTopTooltip: ViewModifier {
    let text: String
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isVisible {
                    Text(text)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.82))
                        )
                        .offset(y: -26)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}

private extension View {
    func compactTopTooltip(_ text: String, isVisible: Binding<Bool>) -> some View {
        modifier(CompactTopTooltip(text: text, isVisible: isVisible))
    }
}

#if DEBUG
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        let launchOnLoginManager = LaunchOnLoginReminderManager(coordinator: coordinator)
        let milestoneManager = MilestoneCelebrationManager(coordinator: coordinator)

        DashboardView(
            viewModel: DashboardViewModel(coordinator: coordinator),
            coordinator: coordinator,
            launchOnLoginReminderManager: launchOnLoginManager,
            milestoneCelebrationManager: milestoneManager
        )
        .frame(width: 1200, height: 900)
        .preferredColorScheme(.dark)
    }
}
#endif
