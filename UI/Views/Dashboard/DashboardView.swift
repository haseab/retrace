import SwiftUI
import Shared
import App

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
        ScrollView(showsIndicators: false) {
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

                // Stats Cards Row
                statsCardsRow
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)

                // App Usage Section
                appUsageSection
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)

                // Footer
                footer
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
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
        .sheet(isPresented: $showSessionsSheet) {
            if let app = selectedApp {
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
                actionButton(icon: "arrow.clockwise", label: nil) {
                    Task { await viewModel.loadStatistics() }
                }

                actionButton(icon: "gearshape", label: nil) {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
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

    // MARK: - Recording Indicator

    @State private var isHoveringRecordingIndicator = false

    private var recordingIndicator: some View {
        Button(action: {
            Task {
                await viewModel.toggleRecording(to: !viewModel.isRecording)
            }
        }) {
            HStack(spacing: 6) {
                if !(viewModel.isRecording && isHoveringRecordingIndicator) {
                    Circle()
                        .fill(viewModel.isRecording ? Color.retraceDanger : Color.retraceSecondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .transition(.opacity)
                }

                Text(recordingIndicatorLabel)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)
                    .contentTransition(.interpolate)
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

    private var statsCardsRow: some View {
        let theme = MilestoneCelebrationManager.getCurrentTheme()

        return HStack(spacing: 16) {
            // Screen Time Card
            statCard(
                icon: "clock.fill",
                title: "Screen Time",
                value: formatTotalTime(viewModel.totalWeeklyTime),
                subtitle: "This week",
                theme: theme
            )

            // Storage Used Card
            statCard(
                icon: "externaldrive.fill",
                title: "Storage Used",
                value: formatStorageSize(viewModel.totalStorageBytes),
                subtitle: "Total",
                theme: theme
            )

            // Days Recorded Card
            statCard(
                icon: "calendar",
                title: "Days Recorded",
                value: formatDaysRecorded(viewModel.daysRecorded),
                subtitle: "\(viewModel.daysRecorded) day\(viewModel.daysRecorded == 1 ? "" : "s") total",
                theme: theme
            )
        }
    }

    private func statCard(icon: String, title: String, value: String, subtitle: String, theme: MilestoneCelebrationManager.ColorTheme) -> some View {
        // Use a consistent muted color for all icons
        let iconColor = Color.retraceSecondary

        return HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.retraceHeadline)
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)

                Text(value)
                    .font(.retraceMediumNumber)
                    .foregroundColor(.retracePrimary)

                Text(subtitle)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary.opacity(0.7))
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.03))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.controlBorderColor, lineWidth: 1)
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

    private var appUsageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.weeklyAppUsage.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    // Header row with view mode toggle
                    HStack {
                        Text("App Usage")
                            .font(.retraceHeadline)
                            .foregroundColor(.retracePrimary)

                        Spacer()

                        Text("\(viewModel.weeklyAppUsage.count) apps this week")
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
                            onAppTapped: { app in
                                handleAppTapped(app)
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
                        .stroke(themeBorderColor, lineWidth: 1)
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
                Link(destination: URL(string: "https://x.com/haseab_")!) {
                    HStack(spacing: 4) {
                        Text("Made with")
                            .foregroundColor(.retraceSecondary)
                        Text("❤️")
                        Text("by")
                            .foregroundColor(.retraceSecondary)
                        Text("@haseab")
                            .foregroundColor(Color(red: 74/255, green: 144/255, blue: 226/255))  // Bright blue for link
                    }
                    .font(.retraceCaption2Medium)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
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
                        Image(systemName: "coffee.fill")
                            .font(.retraceCaption2)
                        Text("Support")
                    }
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
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
                }
                .buttonStyle(.plain)
                .onHover { hovering in
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

}

// MARK: - Preview

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
