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
    @State private var hoveredAppIndex: Int? = nil
    @State private var animateStats = false

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
                statsCardsSection
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)

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
            withAnimation(.easeOut(duration: 0.6).delay(0.2)) {
                animateStats = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dashboard")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.retracePrimary)

                Text(viewModel.weekDateRange)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            HStack(spacing: 12) {
                // Recording status indicator
                recordingIndicator

                // Action buttons
                actionButton(icon: "bubble.left.and.bubble.right", label: "Feedback") {
                    showFeedbackSheet = true
                }

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
                    .font(.system(size: 14, weight: .medium))
                if let label = label {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
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
                .font(.system(size: 13, weight: .medium))
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
            .toggleStyle(SwitchToggleStyle(tint: .retraceSuccess))
            .scaleEffect(0.85)
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

    // MARK: - Stats Cards Section

    private var statsCardsSection: some View {
        HStack(spacing: 16) {
            // Total Screen Time Card
            StatCard(
                title: "Screen Time",
                value: formatTotalTime(viewModel.totalWeeklyTime),
                subtitle: "This week",
                icon: "clock.fill",
                gradient: LinearGradient.retraceAccentGradient,
                animate: animateStats
            )

            // Apps Used Card
            StatCard(
                title: "Apps Used",
                value: "\(viewModel.weeklyAppUsage.count)",
                subtitle: "Unique apps",
                icon: "square.grid.2x2.fill",
                gradient: LinearGradient.retracePurpleGradient,
                animate: animateStats
            )

            // Total Sessions Card
            StatCard(
                title: "Sessions",
                value: "\(totalSessions)",
                subtitle: "App switches",
                icon: "arrow.triangle.swap",
                gradient: LinearGradient.retraceGreenGradient,
                animate: animateStats
            )

            // Most Used App Card
            StatCard(
                title: "Top App",
                value: topAppName,
                subtitle: topAppTime,
                icon: "star.fill",
                gradient: LinearGradient.retraceOrangeGradient,
                animate: animateStats
            )
        }
    }

    private var totalSessions: Int {
        viewModel.weeklyAppUsage.reduce(0) { $0 + $1.sessionCount }
    }

    private var topAppName: String {
        viewModel.weeklyAppUsage.first?.appName ?? "—"
    }

    private var topAppTime: String {
        guard let topApp = viewModel.weeklyAppUsage.first else { return "No data" }
        return formatDuration(topApp.duration)
    }

    // MARK: - App Usage Section

    private var appUsageSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section header
            HStack {
                Text("App Usage")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.retracePrimary)

                Spacer()

                if !viewModel.weeklyAppUsage.isEmpty {
                    Text("\(viewModel.weeklyAppUsage.count) apps")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }
            }

            if viewModel.weeklyAppUsage.isEmpty {
                emptyStateView
            } else {
                // App usage list with modern cards
                VStack(spacing: 8) {
                    ForEach(Array(viewModel.weeklyAppUsage.prefix(10).enumerated()), id: \.offset) { index, app in
                        appUsageRow(index: index, app: app)
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.03))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient.retraceAccentGradient.opacity(0.2))
                    .frame(width: 80, height: 80)

                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.retraceAccent)
            }

            VStack(spacing: 8) {
                Text("No activity recorded yet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.retracePrimary)

                Text("Start using your Mac and Retrace will track your app usage automatically.")
                    .font(.system(size: 14))
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

    private func appUsageRow(index: Int, app: AppUsageData) -> some View {
        let isHovered = hoveredAppIndex == index
        let appColor = Color.segmentColor(for: app.appBundleID)

        return HStack(spacing: 14) {
            // Rank number
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(index < 3 ? appColor : .retraceSecondary)
                .frame(width: 24)

            // Color indicator
            RoundedRectangle(cornerRadius: 3)
                .fill(appColor)
                .frame(width: 4, height: 36)

            // App info
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.retracePrimary)
                    .lineLimit(1)

                Text("\(app.sessionCount) session\(app.sessionCount == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.05))

                    // Progress
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [appColor.opacity(0.8), appColor.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * app.percentage, 8))
                }
            }
            .frame(width: 120, height: 6)

            // Duration and percentage
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatDuration(app.duration))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.retracePrimary)

                Text(String(format: "%.1f%%", app.percentage * 100))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.retraceSecondary)
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredAppIndex = hovering ? index : nil
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://x.com/haseab_")!) {
                    HStack(spacing: 6) {
                        Text("Made by")
                            .foregroundColor(.retraceSecondary)
                        Text("@haseab")
                            .foregroundColor(.retraceAccent)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)

                Circle()
                    .fill(Color.retraceSecondary.opacity(0.5))
                    .frame(width: 3, height: 3)

                Link(destination: URL(string: "https://buymeacoffee.com/haseab")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 11))
                        Text("Support")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - Stat Card Component

private struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let gradient: LinearGradient
    let animate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Icon with gradient background
            ZStack {
                Circle()
                    .fill(gradient.opacity(0.2))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(gradient)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.retracePrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.retraceSecondary)
            }

            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.retraceSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            ZStack {
                Color.white.opacity(0.03)

                // Subtle gradient overlay
                LinearGradient(
                    colors: [Color.white.opacity(0.02), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .opacity(animate ? 1 : 0)
        .offset(y: animate ? 0 : 10)
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
