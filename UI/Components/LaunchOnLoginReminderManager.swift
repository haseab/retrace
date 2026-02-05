import SwiftUI
import Combine
import App
import Shared
import ServiceManagement

/// Manages the "Launch on Login" reminder that appears after user has 5+ hours of captured screentime
/// This is a one-time reminder that can be dismissed permanently
///
/// Screen time is tracked persistently in UserDefaults so the reminder survives database moves/resets.
/// Uses timestamp-based tracking to only count segments created after the last checkpoint.
@MainActor
public class LaunchOnLoginReminderManager: ObservableObject {

    // MARK: - Published State

    /// Whether the reminder banner should be shown
    @Published public var shouldShowReminder = false

    // MARK: - Configuration

    /// Threshold of captured hours before showing the reminder (5 hours)
    public static let capturedHoursThreshold: TimeInterval = 5 * 60 * 60 // 5 hours in seconds

    /// UserDefaults key for tracking if reminder was dismissed
    private static let reminderDismissedKey = "launchOnLoginReminderDismissed"

    /// UserDefaults key for tracking if launch at login is enabled
    private static let launchAtLoginKey = "launchAtLogin"

    /// Key for storing cumulative screen time (survives database resets)
    private static let cumulativeScreenTimeKey = "retraceCumulativeScreenTimeSeconds"

    /// Key for storing the timestamp of the last counted segment
    private static let lastCountedTimestampKey = "retraceLastCountedTimestamp"

    /// UserDefaults suite for app settings
    private static let settingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard

    // MARK: - Private State

    private let coordinator: AppCoordinator
    private var checkTimer: Timer?

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        startMonitoring()
    }

    // MARK: - Monitoring

    /// Start monitoring captured duration
    private func startMonitoring() {
        // Check immediately on init
        Task {
            await updateCumulativeTime()
            await checkCapturedDuration()
        }

        // Also check periodically (every 5 minutes) in case user accumulates more time
        checkTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateCumulativeTime()
                await self?.checkCapturedDuration()
            }
        }
    }

    /// Update the cumulative screen time counter
    /// Uses timestamp-based tracking: only counts segments created after the last checkpoint
    private func updateCumulativeTime() async {
        do {
            let lastCountedTimestamp = getLastCountedTimestamp()
            let cumulativeTime = Self.settingsStore.double(forKey: Self.cumulativeScreenTimeKey)

            // Get duration of segments created after the last checkpoint
            let newDuration: TimeInterval
            if let lastTimestamp = lastCountedTimestamp {
                newDuration = try await coordinator.getCapturedDurationAfter(date: lastTimestamp)
            } else {
                // First time - count all existing segments
                newDuration = try await coordinator.getTotalCapturedDuration()
            }

            // Update cumulative time if there's new time
            if newDuration > 0 {
                let updatedCumulative = cumulativeTime + newDuration
                Self.settingsStore.set(updatedCumulative, forKey: Self.cumulativeScreenTimeKey)
            }

            // Update checkpoint to now
            Self.settingsStore.set(Date().timeIntervalSince1970, forKey: Self.lastCountedTimestampKey)

        } catch {
            Log.error("[LaunchOnLoginReminderManager] Failed to update cumulative time: \(error)", category: .ui)
        }
    }

    /// Get the timestamp of the last counted segment checkpoint
    private func getLastCountedTimestamp() -> Date? {
        guard let timestamp = Self.settingsStore.object(forKey: Self.lastCountedTimestampKey) as? TimeInterval,
              timestamp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    /// Get the total cumulative screen time (persisted across database resets)
    private func getCumulativeScreenTime() -> TimeInterval {
        Self.settingsStore.double(forKey: Self.cumulativeScreenTimeKey)
    }

    /// Check if user has enough captured duration to show the reminder
    private func checkCapturedDuration() async {
        // Don't show if already dismissed
        guard !hasBeenDismissed() else {
            return
        }

        // Don't show if launch at login is already enabled
        guard !isLaunchAtLoginEnabled() else {
            return
        }

        let totalDuration = getCumulativeScreenTime()

        if totalDuration >= Self.capturedHoursThreshold {
            shouldShowReminder = true
            Log.debug("[LaunchOnLoginReminderManager] Showing reminder - cumulative: \(totalDuration / 3600) hours", category: .ui)
        }
    }

    // MARK: - State Checks

    /// Check if the reminder has been permanently dismissed
    private func hasBeenDismissed() -> Bool {
        Self.settingsStore.bool(forKey: Self.reminderDismissedKey)
    }

    /// Check if launch at login is already enabled (via UserDefaults or system status)
    private func isLaunchAtLoginEnabled() -> Bool {
        // Check UserDefaults first
        if Self.settingsStore.bool(forKey: Self.launchAtLoginKey) {
            return true
        }
        // Also check actual system status in case user enabled via System Settings
        return SMAppService.mainApp.status == .enabled
    }

    // MARK: - User Actions

    /// Enable launch at login and dismiss the reminder
    public func enableLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            Self.settingsStore.set(true, forKey: Self.launchAtLoginKey)
            shouldShowReminder = false
            markAsDismissed()
            Log.info("[LaunchOnLoginReminderManager] User enabled launch at login", category: .ui)
        } catch {
            Log.error("[LaunchOnLoginReminderManager] Failed to enable launch at login: \(error)", category: .ui)
        }
    }

    /// Dismiss the reminder permanently
    public func dismissReminder() {
        shouldShowReminder = false
        markAsDismissed()
        Log.debug("[LaunchOnLoginReminderManager] User dismissed reminder permanently", category: .ui)
    }

    /// Mark the reminder as dismissed in UserDefaults
    private func markAsDismissed() {
        Self.settingsStore.set(true, forKey: Self.reminderDismissedKey)
    }

    // MARK: - Cleanup

    deinit {
        checkTimer?.invalidate()
    }
}
