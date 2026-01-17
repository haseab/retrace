import SwiftUI
import Combine
import Shared
import App

/// ViewModel for the Dashboard view
/// Manages weekly app usage statistics from the database
@MainActor
public class DashboardViewModel: ObservableObject {

    // MARK: - Published State

    // Recording status
    @Published public var isRecording = false

    // Weekly app usage
    @Published public var weeklyAppUsage: [AppUsageData] = []
    @Published public var totalWeeklyTime: TimeInterval = 0
    @Published public var weekDateRange: String = ""

    // Loading state
    @Published public var isLoading = false
    @Published public var error: String?

    // Permission warnings
    @Published public var showAccessibilityWarning = false

    // MARK: - Dependencies

    private let coordinator: AppCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        setupAutoRefresh()
        setupAccessibilityWarningCallback()
    }

    // MARK: - Setup

    private func setupAutoRefresh() {
        // Refresh stats every 30 seconds, recording status every 2 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateRecordingStatus()
            }
        }
    }

    private func updateRecordingStatus() async {
        isRecording = await coordinator.isCapturing()
    }

    private func setupAccessibilityWarningCallback() {
        Task {
            await coordinator.setupAccessibilityWarningCallback { [weak self] in
                Task { @MainActor in
                    self?.showAccessibilityWarning = true
                }
            }
        }
    }

    public func dismissAccessibilityWarning() {
        showAccessibilityWarning = false
    }

    // MARK: - Data Loading

    public func loadStatistics() async {
        isLoading = true
        error = nil

        // Update recording status
        await updateRecordingStatus()

        do {
            // Calculate week date range
            let calendar = Calendar.current
            let now = Date()
            let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let weekEnd = now

            // Format the date range string
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            weekDateRange = "\(formatter.string(from: weekStart)) - \(formatter.string(from: weekEnd))"

            // Load app sessions from database for this week
            let sessions = try await coordinator.getSegments(from: weekStart, to: weekEnd)

            // Aggregate by app
            var appDurations: [String: (appName: String, duration: TimeInterval, sessionCount: Int)] = [:]

            for session in sessions {
                // Calculate session duration
                let duration = session.endDate.timeIntervalSince(session.startDate)

                // Derive app name from bundle ID (e.g., "com.google.Chrome" -> "Chrome")
                let appName = session.bundleID.components(separatedBy: ".").last ?? session.bundleID

                if var existing = appDurations[session.bundleID] {
                    existing.duration += duration
                    existing.sessionCount += 1
                    appDurations[session.bundleID] = existing
                } else {
                    appDurations[session.bundleID] = (appName: appName, duration: duration, sessionCount: 1)
                }
            }

            // Calculate total time
            totalWeeklyTime = appDurations.values.reduce(0) { $0 + $1.duration }

            // Convert to AppUsageData and sort by duration
            weeklyAppUsage = appDurations.map { bundleID, data in
                AppUsageData(
                    appBundleID: bundleID,
                    appName: data.appName,
                    duration: data.duration,
                    sessionCount: data.sessionCount,
                    percentage: totalWeeklyTime > 0 ? data.duration / totalWeeklyTime : 0
                )
            }
            .sorted { $0.duration > $1.duration }
            .prefix(10)  // Show top 10 apps
            .map { $0 }

            isLoading = false
        } catch {
            self.error = "Failed to load statistics: \(error.localizedDescription)"
            isLoading = false
        }
    }

    // MARK: - Cleanup

    deinit {
        refreshTimer?.invalidate()
        cancellables.removeAll()
    }
}

// MARK: - Supporting Types

public struct AppUsageData: Identifiable {
    public let id = UUID()
    public let appBundleID: String
    public let appName: String
    public let duration: TimeInterval
    public let sessionCount: Int
    public let percentage: Double
}
