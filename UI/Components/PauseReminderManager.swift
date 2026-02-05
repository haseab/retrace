import SwiftUI
import Combine
import App
import Shared
import Dispatch

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

    /// Duration after which to show the reminder again when user clicks "Remind Me Later" (30 minutes)
    public static let remindLaterDelay: TimeInterval = 30 * 60  // 30 minutes

    // MARK: - Private State

    private let coordinator: AppCoordinator
    private var pauseStartTime: Date?
    private var reminderTimer: Timer?
    private var remindLaterTimer: Timer?
    private var statusCheckTimer: DispatchSourceTimer?
    private var wasCapturing = false
    private var hasCheckedInitialState = false

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
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

    /// Check the current capture state and manage the reminder timer
    private func checkCaptureState() async {
        let isCapturing = await coordinator.isCapturing()

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

        // Cancel any existing timers
        reminderTimer?.invalidate()
        remindLaterTimer?.invalidate()

        // Start a new timer for 5 minutes
        reminderTimer = Timer.scheduledTimer(withTimeInterval: Self.reminderDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.showReminderIfNotDismissed()
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
        shouldShowReminder = false
        isDismissedForSession = false

        Log.debug("[PauseReminderManager] Capture resumed, reminder cancelled", category: .ui)
    }

    /// Show the reminder if the user hasn't dismissed it
    private func showReminderIfNotDismissed() {
        guard !isDismissedForSession else {
            Log.debug("[PauseReminderManager] Reminder suppressed (user dismissed)", category: .ui)
            return
        }

        shouldShowReminder = true
        Log.debug("[PauseReminderManager] Showing pause reminder", category: .ui)
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

    /// Dismiss the reminder and schedule it to appear again after 30 minutes
    /// Called when user clicks "Remind Me Later"
    public func remindLater() {
        shouldShowReminder = false
        isDismissedForSession = true

        // Cancel any existing remind later timer
        remindLaterTimer?.invalidate()

        // Schedule reminder to appear again after 30 minutes
        remindLaterTimer = Timer.scheduledTimer(withTimeInterval: Self.remindLaterDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isDismissedForSession = false
                self?.shouldShowReminder = true
                Log.debug("[PauseReminderManager] Remind later timer fired, showing reminder again", category: .ui)
            }
        }

        Log.debug("[PauseReminderManager] User clicked 'Remind Me Later', will remind again in \(Self.remindLaterDelay) seconds", category: .ui)
    }

    /// Dismiss the reminder permanently for this pause session (called when user clicks X)
    public func dismissReminder() {
        shouldShowReminder = false
        isDismissedForSession = true
        Log.debug("[PauseReminderManager] User dismissed reminder permanently", category: .ui)
    }

    // MARK: - Cleanup

    deinit {
        reminderTimer?.invalidate()
        remindLaterTimer?.invalidate()
        statusCheckTimer?.cancel()
    }
}
