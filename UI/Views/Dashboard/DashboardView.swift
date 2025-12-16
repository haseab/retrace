import SwiftUI
import Charts
import Shared
import App

/// Main dashboard view - analytics and statistics
/// Default landing screen
public struct DashboardView: View {

    // MARK: - Properties

    @StateObject private var viewModel: DashboardViewModel

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

                // Analytics cards
                analyticsCards

                // Activity chart
                if !viewModel.activityData.isEmpty {
                    activityChart
                }

                // Top apps
                if !viewModel.topApps.isEmpty {
                    topAppsSection
                }

                // Migration panel
                migrationSection

                // Footer with attribution
                footer
            }
            .padding(.spacingL)
        }
        .background(Color.retraceBackground)
        .task {
            await viewModel.loadStatistics()
            await viewModel.scanForMigrationSources()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Retrace Dashboard")
                    .font(.retraceTitle)
                    .foregroundColor(.retracePrimary)

                Text("Your screen history at a glance")
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            Button(action: { Task { await viewModel.loadStatistics() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18))
            }
            .buttonStyle(RetraceSecondaryButtonStyle())
        }
    }

    // MARK: - Analytics Cards

    private var analyticsCards: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ],
            spacing: .spacingM
        ) {
            // Capture stats
            AnalyticsCard(
                title: "Frames Captured",
                value: formatFrameCount(viewModel.databaseStats?.frameCount ?? 0),
                subtitle: viewModel.captureStats.map { "+\($0.totalFramesCaptured) today" },
                icon: "photo.on.rectangle.angled",
                accentColor: .retraceAccent
            )

            // Storage stats
            AnalyticsCard(
                title: "Total Storage Used",
                value: formatBytes(viewModel.storageStats?.totalStorageBytes ?? 0),
                subtitle: viewModel.storageStats?.estimatedDaysUntilFull.map { "\($0) days until full" },
                icon: "internaldrive",
                accentColor: .retraceWarning
            )

            // Time tracked
            AnalyticsCard(
                title: "Days Recording",
                value: formatDateRange(viewModel.databaseStats),
                subtitle: formatCaptureUptime(viewModel.captureStats),
                icon: "calendar",
                accentColor: .retraceSuccess
            )

            // Search stats
            AnalyticsCard(
                title: "Searchable Documents",
                value: formatNumber(viewModel.databaseStats?.documentCount ?? 0),
                subtitle: "Full-text searchable",
                icon: "doc.text.magnifyingglass",
                accentColor: .retraceAccent
            )

            // Processing stats
            AnalyticsCard(
                title: "OCR Processing",
                value: String(format: "%.0fms", viewModel.processingStats?.averageOCRTimeMs ?? 0),
                subtitle: "avg processing time",
                icon: "wand.and.stars",
                accentColor: .retraceForeground
            )

            // Deduplication rate
            AnalyticsCard(
                title: "Deduplication Rate",
                value: String(format: "%.0f%%", (viewModel.captureStats?.deduplicationRate ?? 0) * 100),
                subtitle: "\(viewModel.captureStats?.framesDeduped ?? 0) frames saved",
                icon: "square.on.square",
                accentColor: .retraceSuccess
            )
        }
    }

    // MARK: - Activity Chart

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: .spacingM) {
            Text("Recent Activity")
                .font(.retraceTitle3)
                .foregroundColor(.retracePrimary)

            Chart(viewModel.activityData) { dataPoint in
                LineMark(
                    x: .value("Date", dataPoint.date),
                    y: .value("Frames", dataPoint.framesCount)
                )
                .foregroundStyle(Color.retraceAccent)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Date", dataPoint.date),
                    y: .value("Frames", dataPoint.framesCount)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.retraceAccent.opacity(0.3),
                            Color.retraceAccent.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisValueLabel(format: .dateTime.month().day())
                        .foregroundStyle(Color.retraceSecondary)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel()
                        .foregroundStyle(Color.retraceSecondary)
                }
            }
            .frame(height: 200)
            .padding(.spacingM)
            .background(Color.retraceCard)
            .cornerRadius(.cornerRadiusL)
            .retraceShadowLight()
        }
    }

    // MARK: - Top Apps

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: .spacingM) {
            Text("Top Apps")
                .font(.retraceTitle3)
                .foregroundColor(.retracePrimary)

            VStack(spacing: .spacingS) {
                ForEach(Array(viewModel.topApps.enumerated()), id: \.offset) { index, app in
                    topAppRow(index: index + 1, app: app)
                }
            }
            .padding(.spacingM)
            .background(Color.retraceCard)
            .cornerRadius(.cornerRadiusL)
            .retraceShadowLight()
        }
    }

    private func topAppRow(index: Int, app: (appBundleID: String, appName: String, duration: TimeInterval, percentage: Double)) -> some View {
        HStack(spacing: .spacingM) {
            // Rank
            Text("\(index).")
                .font(.retraceHeadline)
                .foregroundColor(.retraceSecondary)
                .frame(width: 30, alignment: .leading)

            // App icon and name
            HStack(spacing: .spacingS) {
                Circle()
                    .fill(Color.sessionColor(for: app.appBundleID))
                    .frame(width: 8, height: 8)

                Text(app.appName)
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)
            }

            Spacer()

            // Duration
            Text(formatDuration(app.duration))
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)

            // Percentage
            Text(String(format: "%.0f%%", app.percentage * 100))
                .font(.retraceBody)
                .fontWeight(.semibold)
                .foregroundColor(.retraceAccent)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, .spacingS)
    }

    // MARK: - Migration

    private var migrationSection: some View {
        MigrationPanel(
            sources: viewModel.availableSources,
            importProgress: viewModel.importProgress,
            isImporting: viewModel.isImporting,
            onStartImport: { source in
                Task { await viewModel.startImport(from: source) }
            },
            onPauseImport: {
                viewModel.pauseImport()
            },
            onCancelImport: {
                viewModel.cancelImport()
            },
            onScanSources: {
                Task { await viewModel.scanForMigrationSources() }
            }
        )
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

            Spacer()
        }
        .padding(.spacingL)
    }

    // MARK: - Formatting Helpers

    private func formatFrameCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDateRange(_ stats: DatabaseStatistics?) -> String {
        guard let stats = stats,
              let oldest = stats.oldestFrameDate,
              let newest = stats.newestFrameDate else {
            return "0"
        }

        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: oldest, to: newest).day ?? 0
        return "\(days)"
    }

    private func formatCaptureUptime(_ stats: CaptureStatistics?) -> String {
        guard let stats = stats,
              let startTime = stats.captureStartTime else {
            return "No data"
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let hours = Int(elapsed / 3600)
        return "\(hours)h uptime"
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = duration / 3600

        return String(format: "%.1f hours", hours)
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
