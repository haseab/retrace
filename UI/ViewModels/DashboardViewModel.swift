import SwiftUI
import Combine
import Shared
import App
import ApplicationServices

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

    // Overall statistics
    @Published public var totalStorageBytes: Int64 = 0
    @Published public var daysRecorded: Int = 0

    // Loading state
    @Published public var isLoading = false
    @Published public var error: String?

    // Permission warnings
    @Published public var showAccessibilityWarning = false
    @Published public var showScreenRecordingWarning = false

    // Track user dismissals — re-nag after 30 minutes
    private var accessibilityDismissedUntil: Date?
    private var screenRecordingDismissedUntil: Date?

    /// How long to suppress a permission warning after the user dismisses it
    private static let dismissSnoozeInterval: TimeInterval = 30 * 60 // 30 minutes

    // MARK: - Dependencies

    private let coordinator: AppCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        setupAutoRefresh()
        // Check permissions immediately on init
        checkPermissions()
    }

    // MARK: - Setup

    private func setupAutoRefresh() {
        // Refresh recording status and permissions every 2 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateRecordingStatus()
                self?.checkPermissions()
            }
        }
    }

    private func updateRecordingStatus() async {
        isRecording = await coordinator.isCapturing()
    }

    /// Polls accessibility and screen recording permissions and updates warning states.
    /// Shows warnings when a permission is missing and the user is recording OR trying to record
    /// (i.e. the pipeline can't start because of a missing permission).
    /// Only hides warnings when the user is voluntarily not recording AND all permissions are granted.
    /// If the user dismisses a warning, it's snoozed for 30 minutes then re-shown.
    private func checkPermissions() {
        let hasAccessibility = AXIsProcessTrusted()
        let hasScreenRecording = CGPreflightScreenCaptureAccess()
        let permissionsMissing = !hasAccessibility || !hasScreenRecording
        let now = Date()

        // Don't nag if the user voluntarily stopped recording and all permissions are fine.
        // But if a permission is missing, always warn — the user may be unable to start recording.
        if !isRecording && !permissionsMissing {
            showAccessibilityWarning = false
            showScreenRecordingWarning = false
            return
        }

        // Accessibility
        if hasAccessibility {
            showAccessibilityWarning = false
            accessibilityDismissedUntil = nil
        } else if let snoozeEnd = accessibilityDismissedUntil {
            if now >= snoozeEnd {
                accessibilityDismissedUntil = nil
                showAccessibilityWarning = true
            }
        } else {
            showAccessibilityWarning = true
        }

        // Screen recording
        if hasScreenRecording {
            showScreenRecordingWarning = false
            screenRecordingDismissedUntil = nil
        } else if let snoozeEnd = screenRecordingDismissedUntil {
            if now >= snoozeEnd {
                screenRecordingDismissedUntil = nil
                showScreenRecordingWarning = true
            }
        } else {
            showScreenRecordingWarning = true
        }
    }

    public func toggleRecording(to newValue: Bool) async {
        do {
            if newValue {
                try await coordinator.startPipeline()
            } else {
                try await coordinator.stopPipeline()
            }
            // Update recording status immediately
            await updateRecordingStatus()
        } catch {
            Log.error("[DashboardViewModel] Failed to toggle recording: \(error)", category: .ui)
            // Revert to actual state on error
            await updateRecordingStatus()
        }
    }

    public func dismissAccessibilityWarning() {
        showAccessibilityWarning = false
        accessibilityDismissedUntil = Date().addingTimeInterval(Self.dismissSnoozeInterval)
    }

    public func dismissScreenRecordingWarning() {
        showScreenRecordingWarning = false
        screenRecordingDismissedUntil = Date().addingTimeInterval(Self.dismissSnoozeInterval)
    }

    // MARK: - Data Loading

    public func loadStatistics() async {
        isLoading = true
        error = nil

        // Update recording status
        await updateRecordingStatus()

        do {
            // Load overall statistics
            totalStorageBytes = try await coordinator.getTotalStorageUsed()
            let allDates = try await coordinator.getDistinctDates()
            daysRecorded = allDates.count

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

                // Resolve app name using the smart resolver (handles random IDs, system lookups, etc.)
                let appName = AppNameResolver.shared.displayName(for: session.bundleID)

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

    // MARK: - App Session Details

    /// Fetch detailed sessions for a specific app with pagination
    /// - Parameters:
    ///   - bundleID: The app's bundle identifier
    ///   - offset: Number of sessions to skip (for pagination)
    ///   - limit: Maximum number of sessions to return
    /// - Returns: Array of sessions sorted by most recent first
    public func getSessionsForApp(bundleID: String, offset: Int, limit: Int) async -> [AppSessionDetail] {
        do {
            let calendar = Calendar.current
            let now = Date()
            let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!

            // Use efficient SQL query with bundleID filter, time range, and pagination
            let segments = try await coordinator.getSegments(
                bundleID: bundleID,
                from: weekStart,
                to: now,
                limit: limit,
                offset: offset
            )

            return segments.map { segment in
                AppSessionDetail(
                    id: segment.id.value,
                    appBundleID: segment.bundleID,
                    appName: AppNameResolver.shared.displayName(for: segment.bundleID),
                    startDate: segment.startDate,
                    endDate: segment.endDate,
                    windowName: segment.windowName
                )
            }
        } catch {
            Log.error("[DashboardViewModel] Failed to fetch sessions for app: \(error)", category: .ui)
            return []
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

/// Represents a single session (continuous usage period) for an app
public struct AppSessionDetail: Identifiable {
    public let id: Int64
    public let appBundleID: String
    public let appName: String
    public let startDate: Date
    public let endDate: Date
    public let windowName: String?

    public var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }
}
