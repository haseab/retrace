import SwiftUI
import Shared
import App

/// Main dashboard view - analytics and statistics
/// Default landing screen
public struct DashboardView: View {

    // MARK: - Properties

    @StateObject private var viewModel: DashboardViewModel
    @State private var isPulsing = false
    @State private var showFeedbackSheet = false
    @State private var usageViewMode: AppUsageViewMode = .hardDrive
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

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        _viewModel = StateObject(wrappedValue: DashboardViewModel(coordinator: coordinator))
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
                Color.retraceBackground

                // Subtle gradient orbs for depth
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.retraceAccent.opacity(0.08), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 300
                        )
                    )
                    .frame(width: 600, height: 600)
                    .offset(x: -200, y: -100)
                    .blur(radius: 60)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 139/255, green: 92/255, blue: 246/255).opacity(0.06), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 250
                        )
                    )
                    .frame(width: 500, height: 500)
                    .offset(x: 300, y: 200)
                    .blur(radius: 50)
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
                Text("Dashboard")
                    .font(.retraceDisplay3)
                    .foregroundColor(.retracePrimary)

                Text(viewModel.weekDateRange)
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retraceSecondary)
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

    private var recordingIndicator: some View {
        HStack(spacing: 10) {
            // Pulsating dot
            ZStack {
                Circle()
                    .fill(viewModel.isRecording ? Color.retraceSuccess : Color.retraceDanger)
                    .frame(width: 10, height: 10)
                    .scaleEffect(isPulsing ? 2.0 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.6)

                Circle()
                    .fill(viewModel.isRecording ? Color.retraceSuccess : Color.retraceDanger)
                    .frame(width: 10, height: 10)
            }
            .onAppear {
                withAnimation(
                    Animation.easeOut(duration: 1.5)
                        .repeatForever(autoreverses: false)
                ) {
                    isPulsing = true
                }
            }

            Text(viewModel.isRecording ? "Recording" : "Paused")
                .font(.retraceCaptionMedium)
                .foregroundColor(viewModel.isRecording ? .retraceSuccess : .retraceSecondary)

            Toggle("", isOn: Binding(
                get: { viewModel.isRecording },
                set: { newValue in
                    Task {
                        await viewModel.toggleRecording(to: newValue)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: .retraceAccent))
            .scaleEffect(0.85)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(viewModel.isRecording ? Color.retraceSuccess.opacity(0.1) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(viewModel.isRecording ? Color.retraceSuccess.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Stats Cards Row

    private var statsCardsRow: some View {
        HStack(spacing: 16) {
            // Screen Time Card
            statCard(
                icon: "clock.fill",
                title: "Screen Time",
                value: formatTotalTime(viewModel.totalWeeklyTime),
                subtitle: "This week",
                gradient: LinearGradient.retraceAccentGradient
            )

            // Storage Used Card
            statCard(
                icon: "externaldrive.fill",
                title: "Storage Used",
                value: formatStorageSize(viewModel.totalStorageBytes),
                subtitle: "Total",
                gradient: LinearGradient(
                    colors: [Color(red: 139/255, green: 92/255, blue: 246/255), Color(red: 168/255, green: 85/255, blue: 247/255)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            // Days Recorded Card
            statCard(
                icon: "calendar",
                title: "Days Recorded",
                value: formatDaysRecorded(viewModel.daysRecorded),
                subtitle: "\(viewModel.daysRecorded) day\(viewModel.daysRecorded == 1 ? "" : "s") total",
                gradient: LinearGradient(
                    colors: [Color(red: 34/255, green: 197/255, blue: 94/255), Color(red: 22/255, green: 163/255, blue: 74/255)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private func statCard(icon: String, title: String, value: String, subtitle: String, gradient: LinearGradient) -> some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(gradient.opacity(0.2))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.retraceHeadline)
                    .foregroundStyle(gradient)
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
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
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
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
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
                }) {
                    Image(systemName: mode.icon)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(usageViewMode == mode ? .retracePrimary : .retraceSecondary)
                        .frame(width: 28, height: 28)
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
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
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

                Link(destination: URL(string: "https://buymeacoffee.com/haseab")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "cup.and.saucer.fill")
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

#if DEBUG
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()

        DashboardView(coordinator: coordinator)
            .frame(width: 1200, height: 900)
            .preferredColorScheme(.dark)
    }
}
#endif
