import SwiftUI
import Combine
import App
import Shared
import Dispatch

enum PauseReminderSettingsNotification {
    static let didChange = Notification.Name("PauseReminderSettingsDidChange")
}

struct PauseReminderSettingsSnapshot: Sendable {
    let delayMinutes: Double

    init(delayMinutes: Double) {
        self.delayMinutes = delayMinutes
    }

    var delaySeconds: TimeInterval {
        delayMinutes * 60
    }
}

/// Manages the pause reminder notification that appears after capture has been paused for 5 minutes
/// Similar to Rewind AI's "Rewind is paused" notification
@MainActor
public class PauseReminderManager: ObservableObject {

    // MARK: - Published State

    /// Whether the reminder prompt should be shown
    @Published public var shouldShowReminder = false

    /// Whether the user has dismissed the reminder for this pause session
    @Published public var isDismissedForSession = false

    // MARK: - Configuration

    /// Duration after which to show the reminder (5 minutes)
    /// NOTE: Set to 10 seconds for testing - change back to 5 * 60 for production
    public static let reminderDelay: TimeInterval = 1 * 60 // 5 minutes for production

    /// Read the user's "Remind Me Later" delay from settings (in seconds). 0 = never remind again.
    nonisolated static func remindLaterDelay(for store: UserDefaults = settingsStore) -> TimeInterval {
        let minutes = store.double(forKey: "pauseReminderDelayMinutes")
        // If the key has never been set, default to 30 minutes
        if minutes == 0 && !store.dictionaryRepresentation().keys.contains("pauseReminderDelayMinutes") {
            return 30 * 60
        }
        return minutes * 60  // 0 means never
    }

    nonisolated static func remainingRemindLaterDelay(
        since remindLaterRequestedAt: Date,
        configuredDelay: TimeInterval,
        now: Date = Date()
    ) -> TimeInterval {
        max(0, configuredDelay - now.timeIntervalSince(remindLaterRequestedAt))
    }

    private var remindLaterDelay: TimeInterval {
        Self.remindLaterDelay()
    }

    // MARK: - Private State

    private let coordinator: AppCoordinator
    private var pauseStartTime: Date?
    private var reminderTimer: Timer?
    private var remindLaterTimer: Timer?
    private var statusCheckTimer: DispatchSourceTimer?
    private var remindLaterRequestedAt: Date?
    private var wasCapturing = false
    private var hasCheckedInitialState = false
    private var wasSuppressedForPausedState = false
    private var wasSuppressedForOnboarding = false
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        observeSettingsChanges()
        startMonitoring()
    }

    // MARK: - Monitoring

    /// Start monitoring capture state changes
    private func startMonitoring() {
        // Check capture status every 2 seconds with leeway for power efficiency
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.checkCaptureState()
            }
        }
        timer.resume()
        statusCheckTimer = timer
    }

    private func observeSettingsChanges() {
        NotificationCenter.default.publisher(for: PauseReminderSettingsNotification.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleSettingsChange(notification: notification)
            }
            .store(in: &cancellables)
    }

    private func handleSettingsChange(notification: Notification) {
        let updatedDelay =
            (notification.object as? PauseReminderSettingsSnapshot)?.delaySeconds
            ?? remindLaterDelay

        guard let remindLaterRequestedAt else { return }

        rescheduleRemindLaterTimer(
            since: remindLaterRequestedAt,
            reason: "Pause reminder interval changed",
            configuredDelay: updatedDelay
        )
    }

    /// Check the current capture state and manage the reminder timer
    private func checkCaptureState() async {
        let isCapturing = await coordinator.isCapturing()
        let hasCompletedOnboarding = await coordinator.onboardingManager.hasCompletedOnboarding
        let isPausedState = MenuBarManager.shared?.isPausedState == true

        if !hasCompletedOnboarding {
            if pauseStartTime != nil || reminderTimer != nil || remindLaterTimer != nil || shouldShowReminder {
                onCaptureResumed()
                Log.debug("[PauseReminderManager] Suppressing reminder during onboarding", category: .ui)
            }
            // Reset initial-state logic so reminder behavior is recalculated
            // once onboarding has actually completed.
            hasCheckedInitialState = false
            wasCapturing = isCapturing
            wasSuppressedForPausedState = false
            wasSuppressedForOnboarding = true
            return
        }

        if wasSuppressedForOnboarding {
            hasCheckedInitialState = false
            wasSuppressedForOnboarding = false
        }

        // "Paused" (timed pause) should not show the off reminder.
        if isPausedState {
            if pauseStartTime != nil || reminderTimer != nil || remindLaterTimer != nil || shouldShowReminder {
                onCaptureResumed()
                Log.debug("[PauseReminderManager] Suppressing off reminder while recording is paused", category: .ui)
            }
            hasCheckedInitialState = true
            wasCapturing = isCapturing
            wasSuppressedForPausedState = true
            return
        }

        // Handle initial state: if app starts while not capturing, treat it as paused
        if !hasCheckedInitialState {
            hasCheckedInitialState = true
            if !isCapturing {
                // App started while not capturing - start the reminder timer
                onCapturePaused()
            }
            wasCapturing = isCapturing
            return
        }

        // Transitioned from paused state -> off (still not capturing): start off reminder timer now.
        if wasSuppressedForPausedState && !isCapturing {
            onCapturePaused()
        }
        wasSuppressedForPausedState = false

        if wasCapturing && !isCapturing {
            // Capture just stopped - start the reminder timer
            onCapturePaused()
        } else if !wasCapturing && isCapturing {
            // Capture just resumed - cancel the reminder
            onCaptureResumed()
        }

        wasCapturing = isCapturing
    }

    /// Called when capture is paused
    private func onCapturePaused() {
        pauseStartTime = Date()
        isDismissedForSession = false
        remindLaterRequestedAt = nil

        // Cancel any existing timers
        reminderTimer?.invalidate()
        remindLaterTimer?.invalidate()
        remindLaterTimer = nil

        // Start a new timer for 5 minutes
        reminderTimer = Timer.scheduledTimer(withTimeInterval: Self.reminderDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.showReminderIfNotDismissed()
            }
        }

        Log.debug("[PauseReminderManager] Capture paused, reminder scheduled for \(Self.reminderDelay) seconds", category: .ui)
    }

    /// Called when capture is resumed
    private func onCaptureResumed() {
        pauseStartTime = nil
        reminderTimer?.invalidate()
        reminderTimer = nil
        remindLaterTimer?.invalidate()
        remindLaterTimer = nil
        remindLaterRequestedAt = nil
        shouldShowReminder = false
        isDismissedForSession = false

        Log.debug("[PauseReminderManager] Capture resumed, reminder cancelled", category: .ui)
    }

    /// Show the reminder if the user hasn't dismissed it
    private func showReminderIfNotDismissed() async {
        guard !isDismissedForSession else {
            Log.debug("[PauseReminderManager] Reminder suppressed (user dismissed)", category: .ui)
            return
        }

        let hasCompletedOnboarding = await coordinator.onboardingManager.hasCompletedOnboarding
        guard hasCompletedOnboarding else {
            Log.debug("[PauseReminderManager] Reminder suppressed during onboarding", category: .ui)
            return
        }

        remindLaterRequestedAt = nil
        shouldShowReminder = true
        Log.debug("[PauseReminderManager] Showing pause reminder", category: .ui)
    }

    private func rescheduleRemindLaterTimer(
        since remindLaterRequestedAt: Date,
        reason: String,
        configuredDelay: TimeInterval? = nil,
        now: Date = Date()
    ) {
        remindLaterTimer?.invalidate()
        remindLaterTimer = nil

        let delay = configuredDelay ?? remindLaterDelay
        guard delay > 0 else {
            Log.debug("[PauseReminderManager] \(reason), reminder disabled for current pause session", category: .ui)
            return
        }

        let remainingDelay = Self.remainingRemindLaterDelay(
            since: remindLaterRequestedAt,
            configuredDelay: delay,
            now: now
        )

        guard remainingDelay > 0 else {
            isDismissedForSession = false
            self.remindLaterRequestedAt = nil

            Task { @MainActor [weak self] in
                await self?.showReminderIfNotDismissed()
            }

            Log.debug("[PauseReminderManager] \(reason), updated interval elapsed so showing reminder now", category: .ui)
            return
        }

        remindLaterTimer = Timer.scheduledTimer(withTimeInterval: remainingDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isDismissedForSession = false
                self?.remindLaterRequestedAt = nil
                await self?.showReminderIfNotDismissed()
                Log.debug("[PauseReminderManager] Remind later timer fired, attempting reminder display", category: .ui)
            }
        }

        Log.debug("[PauseReminderManager] \(reason), reminder rescheduled in \(remainingDelay) seconds", category: .ui)
    }

    // MARK: - User Actions

    /// Resume capturing (called when user clicks "Resume Capturing")
    public func resumeCapturing() async {
        do {
            try await coordinator.startPipeline()
            shouldShowReminder = false
            Log.info("[PauseReminderManager] User resumed capturing", category: .ui)
        } catch {
            Log.error("[PauseReminderManager] Failed to resume capturing: \(error)", category: .ui)
        }
    }

    /// Dismiss the reminder and schedule it to appear again based on user setting
    /// Called when user clicks "Remind Me Later"
    public func remindLater() {
        shouldShowReminder = false
        isDismissedForSession = true

        let remindLaterRequestedAt = Date()
        self.remindLaterRequestedAt = remindLaterRequestedAt
        rescheduleRemindLaterTimer(
            since: remindLaterRequestedAt,
            reason: "User clicked 'Remind Me Later'"
        )
    }

    /// Dismiss the reminder permanently for this pause session (called when user clicks X)
    public func dismissReminder() {
        shouldShowReminder = false
        isDismissedForSession = true
        remindLaterRequestedAt = nil
        remindLaterTimer?.invalidate()
        remindLaterTimer = nil
        Log.debug("[PauseReminderManager] User dismissed reminder permanently", category: .ui)
    }

    // MARK: - Cleanup

    deinit {
        reminderTimer?.invalidate()
        remindLaterTimer?.invalidate()
        statusCheckTimer?.cancel()
    }
}
