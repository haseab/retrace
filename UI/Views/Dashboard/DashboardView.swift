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

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        _viewModel = StateObject(wrappedValue: DashboardViewModel(coordinator: coordinator))
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .spacingL) {
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
                    .padding(.horizontal, .spacingL)
                    .padding(.top, .spacingM)
                }

                // Header
                header

                // Your Week section
                yourWeekSection

                // Footer with attribution
                footer
            }
            .padding(.spacingL)
        }
        .background(Color.retraceBackground)
        .task {
            await viewModel.loadStatistics()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: .spacingM) {
                // Retrace logo
                retraceLogo
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Dashboard")
                        .font(.retraceTitle)
                        .foregroundColor(.retracePrimary)

                    Text("Your screen history at a glance")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)
                }
            }

            Spacer()

            // Recording status indicator
            recordingIndicator

            // Feedback button
            Button(action: { showFeedbackSheet = true }) {
                HStack(spacing: .spacingS) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 14))
                    Text("Feedback")
                        .font(.retraceCaption)
                }
            }
            .buttonStyle(RetraceSecondaryButtonStyle())

            Button(action: { Task { await viewModel.loadStatistics() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18))
            }
            .buttonStyle(RetraceSecondaryButtonStyle())

            Button(action: {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }) {
                Image(systemName: "gear")
                    .font(.system(size: 18))
            }
            .buttonStyle(RetraceSecondaryButtonStyle())
        }
        .sheet(isPresented: $showFeedbackSheet) {
            FeedbackFormView()
        }
    }

    // MARK: - Recording Indicator

    private var recordingIndicator: some View {
        HStack(spacing: .spacingM) {
            // Pulsating dot (red when not recording, green when recording)
            ZStack {
                // Pulse layer (animated ring)
                Circle()
                    .fill(viewModel.isRecording ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                    .scaleEffect(isPulsing ? 2.5 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.9)

                // Main dot
                Circle()
                    .fill(viewModel.isRecording ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
            }
            .onAppear {
                withAnimation(
                    Animation.easeOut(duration: 1.5)
                        .repeatForever(autoreverses: false)
                ) {
                    isPulsing = true
                }
            }

            Text(viewModel.isRecording ? "Recording" : "Not Recording")
                .font(.retraceCaption)
                .foregroundColor(viewModel.isRecording ? .white : .white.opacity(0.9))

            // Toggle switch
            Toggle("", isOn: Binding(
                get: { viewModel.isRecording },
                set: { newValue in
                    Task {
                        await viewModel.toggleRecording(to: newValue)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: .green))
        }
        .padding(.horizontal, .spacingM)
        .padding(.vertical, .spacingS)
        .background(
            RoundedRectangle(cornerRadius: .cornerRadiusM)
                .fill(Color.clear)
        )
        .padding(.trailing, .spacingM)
    }

    // MARK: - Logo

    private var retraceLogo: some View {
        ZStack {
            // Background circle with gradient
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.retraceAccent.opacity(0.3), Color.retraceDeepBlue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Left triangle pointing left
            Path { path in
                path.move(to: CGPoint(x: 5, y: 20))
                path.addLine(to: CGPoint(x: 18, y: 11))
                path.addLine(to: CGPoint(x: 18, y: 29))
                path.closeSubpath()
            }
            .fill(Color.retracePrimary.opacity(0.9))

            // Right triangle pointing right
            Path { path in
                path.move(to: CGPoint(x: 35, y: 20))
                path.addLine(to: CGPoint(x: 22, y: 11))
                path.addLine(to: CGPoint(x: 22, y: 29))
                path.closeSubpath()
            }
            .fill(Color.retracePrimary.opacity(0.9))
        }
    }

    // MARK: - Your Week Section

    private var yourWeekSection: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            // Section header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Week")
                        .font(.retraceTitle2)
                        .foregroundColor(.retracePrimary)

                    Text(viewModel.weekDateRange)
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer()

                // Total time this week
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatTotalTime(viewModel.totalWeeklyTime))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.retraceAccent)

                    Text("total screen time")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                }
            }

            // App usage list
            if viewModel.weeklyAppUsage.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.weeklyAppUsage.enumerated()), id: \.offset) { index, app in
                        appUsageRow(index: index, app: app)

                        if index < viewModel.weeklyAppUsage.count - 1 {
                            Divider()
                                .background(Color.retraceBorder)
                        }
                    }
                }
                .padding(.spacingM)
                .background(Color.retraceCard)
                .cornerRadius(.cornerRadiusL)
                .retraceShadowLight()
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: .spacingM) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.retraceSecondary)

            Text("No activity recorded yet")
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            Text("Start using your Mac and Retrace will track your app usage.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.spacingXL)
        .background(Color.retraceCard)
        .cornerRadius(.cornerRadiusL)
    }

    private func appUsageRow(index: Int, app: AppUsageData) -> some View {
        HStack(spacing: .spacingM) {
            // App color indicator
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.segmentColor(for: app.appBundleID))
                .frame(width: 4, height: 40)

            // App name
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                Text("\(app.sessionCount) sessions")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            // Duration bar
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.segmentColor(for: app.appBundleID).opacity(0.3))
                        .frame(width: max(geometry.size.width * app.percentage, 20))
                }
            }
            .frame(width: 100, height: 8)

            // Duration and percentage
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatDuration(app.duration))
                    .font(.retraceBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.retracePrimary)

                Text(String(format: "%.0f%%", app.percentage * 100))
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, .spacingS)
    }

    private func formatTotalTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            Link(destination: URL(string: "https://x.com/haseab_")!) {
                HStack(spacing: 4) {
                    Text("Made with")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)

                    Text("♥")
                        .foregroundColor(.retraceDanger)

                    Text("by haseab")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceAccent)
                }
            }
            .buttonStyle(.plain)

            Text("·")
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)
                .padding(.horizontal, .spacingS)

            Link(destination: URL(string: "https://buymeacoffee.com/haseab")!) {
                HStack(spacing: 4) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 12))
                    Text("Buy me a coffee")
                        .font(.retraceCaption)
                }
                .foregroundColor(.retraceAccent)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.spacingL)
    }

    // MARK: - Formatting Helpers

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
