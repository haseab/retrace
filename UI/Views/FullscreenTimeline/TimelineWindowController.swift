import AppKit
import SwiftUI
import App
import Shared
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers

/// Manages the full-screen timeline overlay window
/// This is a singleton that can be triggered from anywhere via keyboard shortcut
@MainActor
public class TimelineWindowController: NSObject {

    private static let accessibilityPermissionRevokedNotification = Notification.Name("AccessibilityPermissionRevoked")

    // MARK: - Singleton

    public static let shared = TimelineWindowController()

    // MARK: - Session Duration Tracking

    /// Tracks when the timeline was opened for duration tracking
    private var sessionStartTime: Date?
    private var sessionScrubDistance: Double = 0

    // MARK: - Properties

    private var window: NSWindow?
    private var coordinator: AppCoordinator?
    private var coordinatorWrapper: AppCoordinatorWrapper?
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private var mouseEventMonitor: Any?  // Debug monitor for shift-drag investigation
    private var timelineViewModel: SimpleTimelineViewModel?
    private var pendingTimelineViewModelWaiters: [CheckedContinuation<SimpleTimelineViewModel, Never>] = []
    private var hostingView: NSView?
    private var deferredHostingViewDetachTask: Task<Void, Never>?
    private var tapeShowAnimationTask: Task<Void, Never>?
    private var liveModeCaptureTask: Task<Void, Never>?
    private var windowFadeInTask: Task<Void, Never>?
    private var windowFadeInGeneration: UInt64 = 0
    private var workspaceActivationObserver: Any?
    private let hideCompletionCoordinator = HideCompletionCoordinator()
    private var isHiding = false
    /// Ignore scroll-wheel input for a short grace period after opening in live mode.
    /// This prevents residual trackpad momentum from immediately exiting live mode.
    private var suppressLiveScrollUntil: CFAbsoluteTime = 0

    // MARK: - Emergency Escape (CGEvent tap for when main thread is blocked)

    /// CGEvent tap for emergency escape - runs on a dedicated background thread
    /// This allows closing the timeline even when the main thread is frozen
    private struct EmergencyTapState {
        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var runLoop: CFRunLoop?
        var tapThread: Thread?
        var isInstallingTap = false
        var setupToken: UInt64 = 0
        var isTimelineVisible = false
    }

    private nonisolated(unsafe) static var emergencyTapState = EmergencyTapState()
    private nonisolated(unsafe) static var emergencyTapStateLock = NSLock()

    /// Whether a prepared headless timeline state exists and is ready to mount on demand.
    private var isPrepared = false

    /// When the timeline was last hidden (for cache expiry check)
    private var lastHiddenAt: Date?

    /// Whether the timeline overlay is currently visible
    public private(set) var isVisible = false

    /// Shared hidden-state cache expiry used by timeline and search-state invalidation.
    static let hiddenStateCacheExpirationSeconds: TimeInterval = 60
    /// Reopen policy: when playhead is within this many latest loaded frames, open in live mode immediately.
    /// This only applies when the newest loaded frame is still recent.
    private static let instantLiveReopenFrameThreshold: Int = 3
    /// Reopen policy: hidden duration required before instant near-edge positions auto-advance to newest.
    private static let instantLiveReopenExpirationSeconds: TimeInterval = 2
    /// Reopen policy: if playhead is this close (< threshold) to latest frame, allow auto-advance after expiry.
    /// This only applies when the newest loaded frame is still recent.
    private static let nearLiveReopenFrameThreshold: Int = 50
    /// Reopen policy: hidden duration required before near-live positions auto-advance to newest.
    private static let nearLiveReopenExpirationSeconds: TimeInterval = 10
    /// Delay before detaching hosting view after hide to keep rapid reopen seamless.
    private static let hostingViewDetachDelay: Duration = .milliseconds(350)

    /// Monotonic counter for deeplink search invocations (debug tracing).
    private var deeplinkSearchInvocationCounter = 0

    /// Whether the dashboard was the key window when timeline opened
    private var dashboardWasKeyWindow = false

    /// Whether the timeline is hiding to show dashboard/settings (don't auto-hide dashboard in this case)
    private var isHidingToShowDashboard = false

    struct FocusRestoreTarget: Equatable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
    }

    @MainActor
    final class HideCompletionCoordinator {
        private var continuations: [CheckedContinuation<Bool, Never>] = []

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func append(_ continuation: CheckedContinuation<Bool, Never>) {
            continuations.append(continuation)
        }

        func resumeAll(hidden: Bool) {
            let pendingContinuations = continuations
            continuations.removeAll()
            for continuation in pendingContinuations {
                continuation.resume(returning: hidden)
            }
        }
    }

    /// The app that was frontmost before the timeline was shown.
    private var focusRestoreTarget: FocusRestoreTarget?

    /// Callback when timeline closes
    public var onClose: (() -> Void)?

    /// Callback for scroll events (delta value)
    public var onScroll: ((Double) -> Void)?

    // MARK: - Tape Click-Drag State

    /// Whether the user is currently click-dragging the timeline tape
    private var isTapeDragging = false

    /// The last mouse X position during a tape drag (in window coordinates)
    private var tapeDragLastX: CGFloat = 0

    /// The mouse X position where the tape drag started (for minimum distance threshold)
    private var tapeDragStartX: CGFloat = 0

    /// The full mouse position where the tape drag started (for click diagnostics)
    private var tapeDragStartPoint: CGPoint = .zero

    /// Whether drag has passed the minimum distance threshold to be considered a drag (vs a click)
    private var tapeDragDidExceedThreshold = false

    /// Whether the current drag candidate started near the playback controls area
    private var tapeDragStartedNearPlaybackControls = false

    /// Minimum pixel distance before a mouseDown+mouseDragged is treated as a drag (not a tap)
    private static let tapeDragMinDistance: CGFloat = 3.0

    /// Recent drag samples for velocity calculation (timestamp, deltaX)
    private var tapeDragVelocitySamples: [(time: CFAbsoluteTime, delta: CGFloat)] = []

    /// Maximum age of velocity samples to consider (seconds)
    private static let velocitySampleWindow: CFAbsoluteTime = 0.08
    /// Live-mode scroll suppression window (seconds) applied on open.
    private static let liveScrollSuppressDuration: CFAbsoluteTime = 0.30
    private static let timelineSettingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard

    /// Accumulated wrong-axis and right-axis scroll magnitudes for orientation mismatch detection
    private var wrongAxisScrollAccum: CGFloat = 0
    private var rightAxisScrollAccum: CGFloat = 0
    /// Timestamp when accumulation started
    private var scrollAccumStartTime: CFAbsoluteTime = 0
    /// Whether the orientation hint has already been shown this session (don't repeat)
    private var hasShownScrollOrientationHint: Bool = false

    private enum TimelineScrollOrientation: String {
        case horizontal
        case vertical
    }

    nonisolated static func shouldCaptureFocusRestoreTarget(frontmostProcessID: pid_t?, currentProcessID: pid_t) -> Bool {
        guard let frontmostProcessID else { return false }
        return frontmostProcessID != currentProcessID
    }

    nonisolated static func shouldRestoreFocus(
        requestedRestore: Bool,
        isHidingToShowDashboard: Bool,
        targetProcessID: pid_t?,
        currentProcessID: pid_t
    ) -> Bool {
        guard requestedRestore, !isHidingToShowDashboard, let targetProcessID else { return false }
        return targetProcessID != currentProcessID
    }

    nonisolated static func shouldHandleTimelineKeyboardShortcuts(
        isTimelineVisible: Bool,
        frontmostProcessID: pid_t?,
        currentProcessID: pid_t
    ) -> Bool {
        guard isTimelineVisible, let frontmostProcessID else { return false }
        return frontmostProcessID == currentProcessID
    }

    nonisolated static func shouldDismissTimelineForActivatedApplication(
        isTimelineVisible: Bool,
        activatedProcessID: pid_t?,
        currentProcessID: pid_t
    ) -> Bool {
        guard isTimelineVisible, let activatedProcessID else { return false }
        return activatedProcessID != currentProcessID
    }

    nonisolated static func shouldToggleSearchOverlayFromShortcut(isActivelyScrolling: Bool) -> Bool {
        !isActivelyScrolling
    }

    nonisolated private static func withEmergencyTapState<T>(
        _ body: (inout EmergencyTapState) -> T
    ) -> T {
        emergencyTapStateLock.lock()
        defer { emergencyTapStateLock.unlock() }
        return body(&emergencyTapState)
    }

    nonisolated private static func readEmergencyTapState<T>(
        _ body: (EmergencyTapState) -> T
    ) -> T {
        emergencyTapStateLock.lock()
        defer { emergencyTapStateLock.unlock() }
        return body(emergencyTapState)
    }

    nonisolated private static func emergencyEventTapIfValid() -> CFMachPort? {
        readEmergencyTapState { state in
            guard let eventTap = state.eventTap, CFMachPortIsValid(eventTap) else {
                return nil
            }
            return eventTap
        }
    }

    nonisolated private static func setEmergencyTimelineVisible(_ visible: Bool) {
        withEmergencyTapState { state in
            state.isTimelineVisible = visible
        }
    }

    nonisolated private static func isEmergencyTimelineVisible() -> Bool {
        readEmergencyTapState(\.isTimelineVisible)
    }

    nonisolated static func shouldDismissTimelineWithCommandW(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let normalizedModifiers = modifiers.intersection([.command, .shift, .option, .control])
        guard normalizedModifiers == [.command] else {
            return false
        }

        let key = charactersIgnoringModifiers?.lowercased()
        return keyCode == 13 || key == "w"
    }

    nonisolated static func shouldNavigateTimelineBackward(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let normalizedModifiers = modifiers.intersection([.command, .shift, .option, .control])
        guard normalizedModifiers.isEmpty || normalizedModifiers == [.option] else {
            return false
        }

        let key = charactersIgnoringModifiers?.lowercased()
        return keyCode == 123 || key == "j" || key == "l"
    }

    nonisolated static func shouldNavigateTimelineForward(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let normalizedModifiers = modifiers.intersection([.command, .shift, .option, .control])
        guard normalizedModifiers.isEmpty || normalizedModifiers == [.option] else {
            return false
        }

        let key = charactersIgnoringModifiers?.lowercased()
        return keyCode == 124 || key == "k" || key == ";"
    }

    private func shouldHandleTimelineKeyboardShortcuts() -> Bool {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return Self.shouldHandleTimelineKeyboardShortcuts(
            isTimelineVisible: isVisible,
            frontmostProcessID: frontmostProcessID,
            currentProcessID: currentProcessID
        )
    }

    private func startObservingApplicationActivation() {
        guard workspaceActivationObserver == nil else { return }
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Self.shouldDismissTimelineForActivatedApplication(
                    isTimelineVisible: self.isVisible,
                    activatedProcessID: activatedApp?.processIdentifier,
                    currentProcessID: currentProcessID
                ) else {
                    return
                }
                self.dismissForActivatedApplication(activatedApp)
            }
        }
    }

    private func stopObservingApplicationActivation() {
        guard let workspaceActivationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        self.workspaceActivationObserver = nil
    }

    private func dismissForActivatedApplication(_ activatedApplication: NSRunningApplication?) {
        guard isVisible, !isHiding else { return }
        stopObservingApplicationActivation()
        if let coordinator {
            DashboardViewModel.recordTimelineAutoDismissed(
                coordinator: coordinator,
                activatedBundleID: activatedApplication?.bundleIdentifier
            )
        }
        Log.info(
            "[TIMELINE-AUTO-DISMISS] Dismissing timeline trigger=app_activation activatedPID=\(activatedApplication?.processIdentifier ?? -1) activatedBundleID=\(activatedApplication?.bundleIdentifier ?? "nil")",
            category: .ui
        )
        hide(restorePreviousFocus: false)
    }

    func hideAndWait(restorePreviousFocus: Bool = true) async -> Bool {
        if isHiding {
            return await hideCompletionCoordinator.wait()
        }

        guard isVisible else { return true }
        guard window != nil else {
            Log.warning(
                "[TimelineToggle] Cannot await hide completion because the timeline window is missing while marked visible",
                category: .ui
            )
            return false
        }

        return await withCheckedContinuation { continuation in
            hideCompletionCoordinator.append(continuation)
            hide(restorePreviousFocus: restorePreviousFocus)
        }
    }

    private func captureFocusRestoreTarget() {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              Self.shouldCaptureFocusRestoreTarget(
                  frontmostProcessID: frontmost.processIdentifier,
                  currentProcessID: currentProcessID
              ) else {
            focusRestoreTarget = nil
            return
        }

        focusRestoreTarget = FocusRestoreTarget(
            processIdentifier: frontmost.processIdentifier,
            bundleIdentifier: frontmost.bundleIdentifier
        )
        Log.debug(
            "[TIMELINE-FOCUS] Captured restore target pid=\(frontmost.processIdentifier) bundleID=\(frontmost.bundleIdentifier ?? "nil")",
            category: .ui
        )
    }

    private func restoreFocusIfNeeded(
        requestedRestore: Bool,
        wasHidingToShowDashboard: Bool,
        hideRequestedAt: CFAbsoluteTime? = nil
    ) {
        defer {
            focusRestoreTarget = nil
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        guard Self.shouldRestoreFocus(
            requestedRestore: requestedRestore,
            isHidingToShowDashboard: wasHidingToShowDashboard,
            targetProcessID: focusRestoreTarget?.processIdentifier,
            currentProcessID: currentProcessID
        ), let target = focusRestoreTarget else {
            return
        }

        let hideElapsedMs = hideRequestedAt.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 }
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier),
              !app.isTerminated else {
            if let hideElapsedMs {
                Log.debug(
                    "[TIMELINE-FOCUS] Skip restore: prior app no longer running pid=\(target.processIdentifier) afterHide=\(String(format: "%.1f", hideElapsedMs))ms",
                    category: .ui
                )
            } else {
                Log.debug("[TIMELINE-FOCUS] Skip restore: prior app no longer running pid=\(target.processIdentifier)", category: .ui)
            }
            return
        }

        if let hideElapsedMs {
            Log.recordLatency(
                "timeline.focus.restore_after_hide_ms",
                valueMs: hideElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 350,
                criticalThresholdMs: 700
            )
            Log.info(
                "[TIMELINE-FOCUS] Restoring app focus pid=\(target.processIdentifier) bundleID=\(target.bundleIdentifier ?? "nil") afterHide=\(String(format: "%.1f", hideElapsedMs))ms",
                category: .ui
            )
        } else {
            Log.info(
                "[TIMELINE-FOCUS] Restoring app focus pid=\(target.processIdentifier) bundleID=\(target.bundleIdentifier ?? "nil")",
                category: .ui
            )
        }

        if !app.activate(options: [.activateIgnoringOtherApps]) {
            if let hideElapsedMs {
                Log.warning(
                    "[TIMELINE-FOCUS] Failed to restore app focus pid=\(target.processIdentifier) bundleID=\(target.bundleIdentifier ?? "nil") afterHide=\(String(format: "%.1f", hideElapsedMs))ms",
                    category: .ui
                )
            } else {
                Log.warning(
                    "[TIMELINE-FOCUS] Failed to restore app focus pid=\(target.processIdentifier) bundleID=\(target.bundleIdentifier ?? "nil")",
                    category: .ui
                )
            }
        }
    }

    // MARK: - Initialization

    private override init() {
        super.init()
        setupEmergencyTapPermissionObservers()
        setupEmergencyEscapeTap()
    }

    // MARK: - Emergency Escape CGEvent Tap

    private func setupEmergencyTapPermissionObservers() {
        NotificationCenter.default.addObserver(
            forName: Self.accessibilityPermissionRevokedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.suspendEmergencyEscapeTapForPermissionLoss()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeEmergencyEscapeTapIfNeeded()
            }
        }
    }

    private nonisolated static func hasEmergencyTapPermission() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Sets up a CGEvent tap on a dedicated thread to handle Escape key
    /// This works even when the main thread is completely frozen
    private func setupEmergencyEscapeTap() {
        guard Self.hasEmergencyTapPermission() else {
            Log.warning("[TIMELINE] Skipping emergency escape event tap setup because listen-event access is unavailable", category: .ui)
            return
        }

        if let eventTap = Self.emergencyEventTapIfValid() {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }

        let setupToken: UInt64? = Self.withEmergencyTapState { state in
            guard !state.isInstallingTap else { return nil }
            state.isInstallingTap = true
            state.setupToken &+= 1
            return state.setupToken
        }
        guard let setupToken else { return }

        let thread = Thread {
            Self.installEmergencyEscapeTap(expectedSetupToken: setupToken)
        }
        thread.name = "RetraceTimelineEmergencyTap"
        thread.qualityOfService = .userInteractive
        Self.withEmergencyTapState { state in
            state.tapThread = thread
        }
        thread.start()
    }

    private func suspendEmergencyEscapeTapForPermissionLoss() {
        if let eventTap = Self.emergencyEventTapIfValid() {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            Log.warning("[TIMELINE] Suspended emergency escape event tap after permission revoke", category: .ui)
        }
    }

    private func resumeEmergencyEscapeTapIfNeeded() {
        guard Self.hasEmergencyTapPermission() else { return }

        if let eventTap = Self.emergencyEventTapIfValid() {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }

        setupEmergencyEscapeTap()
    }

    private nonisolated static func installEmergencyEscapeTap(expectedSetupToken: UInt64) {
        guard shouldContinueInstallingEmergencyTap(expectedSetupToken: expectedSetupToken) else {
            clearEmergencyTapInstallStateIfCurrent(expectedSetupToken: expectedSetupToken)
            return
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    guard TimelineWindowController.hasEmergencyTapPermission() else {
                        Log.warning("[TIMELINE] Emergency escape tap disabled while permission is unavailable; leaving tap suspended", category: .ui)
                        return Unmanaged.passUnretained(event)
                    }

                    if let tap = TimelineWindowController.emergencyEventTapIfValid() {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                // Only process if timeline is visible
                guard TimelineWindowController.isEmergencyTimelineVisible() else {
                    return Unmanaged.passUnretained(event)
                }

                // Check for Escape key (keycode 53) or Cmd+Option+Escape
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                let isCmdOptEscape = keyCode == 53 &&
                    flags.contains(.maskCommand) &&
                    flags.contains(.maskAlternate)

                // Cmd+Option+Escape: EMERGENCY - capture diagnostics then terminate
                if isCmdOptEscape {
                    EmergencyDiagnostics.capture(trigger: "cmd_opt_escape")
                    TimelineWindowController.setEmergencyTimelineVisible(false)
                    exit(0)
                }

                // Triple-escape emergency termination is disabled for now.
                // The watchdog auto-quit path remains the fallback for frozen UI recovery.

                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            Self.withEmergencyTapState { state in
                guard state.setupToken == expectedSetupToken else { return }
                state.isInstallingTap = false
                state.tapThread = nil
            }
            Log.error("[TIMELINE] Failed to create emergency escape event tap - check accessibility permissions", category: .ui)
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        let runLoop = CFRunLoopGetCurrent()
        let thread = Thread.current

        guard shouldContinueInstallingEmergencyTap(expectedSetupToken: expectedSetupToken) else {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            clearEmergencyTapInstallStateIfCurrent(expectedSetupToken: expectedSetupToken)
            return
        }

        Self.withEmergencyTapState { state in
            state.eventTap = eventTap
            state.runLoopSource = runLoopSource
            state.runLoop = runLoop
            state.tapThread = thread
        }

        if let runLoopSource {
            CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        Self.withEmergencyTapState { state in
            state.isInstallingTap = false
        }

        Log.info("[TIMELINE] Emergency escape event tap installed on dedicated thread", category: .ui)

        CFRunLoopRun()

        Self.withEmergencyTapState { state in
            if state.tapThread === thread {
                state.tapThread = nil
            }
            state.isInstallingTap = false
        }
    }

    private nonisolated static func shouldContinueInstallingEmergencyTap(expectedSetupToken: UInt64) -> Bool {
        readEmergencyTapState { state in
            state.setupToken == expectedSetupToken
        }
    }

    private nonisolated static func clearEmergencyTapInstallStateIfCurrent(expectedSetupToken: UInt64) {
        withEmergencyTapState { state in
            guard state.setupToken == expectedSetupToken else { return }
            state.isInstallingTap = false
            if state.tapThread === Thread.current {
                state.tapThread = nil
            }
        }
    }

    // MARK: - Shortcut Loading

    private static let timelineShortcutKey = "timelineShortcutConfig"

    /// Load the current timeline shortcut from UserDefaults
    private func loadTimelineShortcut() -> ShortcutConfig {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard let data = defaults.data(forKey: Self.timelineShortcutKey),
              let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) else {
            return .defaultTimeline
        }
        return config
    }

    // MARK: - Configuration

    /// Configure with the app coordinator (call once during app launch)
    public func configure(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.coordinatorWrapper = AppCoordinatorWrapper(coordinator: coordinator)
        // Pre-render the window in the background for instant show()
        Task { @MainActor in
            // Small delay to let app finish launching
            try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous) // 0.5 seconds
            prepareWindow()
        }

        // Listen for display changes to reposition the hidden window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDisplayChange(_:)),
            name: .activeDisplayDidChange,
            object: nil
        )

        // Listen for dashboard/settings shortcuts to properly hide timeline first
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleDashboard(_:)),
            name: .toggleDashboard,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings(_:)),
            name: .openSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings(_:)),
            name: .openSettingsTags,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings(_:)),
            name: .openSettingsPauseReminderInterval,
            object: nil
        )
    }

    /// Handle toggle dashboard notification - if timeline is visible, hide it first
    @objc private func handleToggleDashboard(_ notification: Notification) {
        guard isVisible else { return }
        // Timeline is visible, so hide it properly before showing dashboard
        hideToShowDashboard()
    }

    /// Handle open settings notification - if timeline is visible, hide it first
    @objc private func handleOpenSettings(_ notification: Notification) {
        guard isVisible else { return }
        // Timeline is visible, so hide it properly before showing settings
        hideToShowDashboard()
    }

    /// Handle active display change - move hidden window to new screen
    @objc private func handleDisplayChange(_ notification: Notification) {
        moveWindowToMouseScreen()
    }

    // MARK: - Pre-rendering

    /// Prepare a metadata-only timeline state at startup.
    /// The hidden window/view hierarchy is no longer kept alive; we only warm the view model.
    public func prepareWindow() {
        let prepareStartTime = CFAbsoluteTimeGetCurrent()
        Log.info("[TIMELINE-PRERENDER] 🚀 prepareWindow() started", category: .ui)

        guard let coordinator = coordinator else {
            Log.info("[TIMELINE-PRERENDER] ⚠️ prepareWindow() skipped - no coordinator", category: .ui)
            return
        }

        if isPrepared, timelineViewModel != nil {
            Log.info("[TIMELINE-PRERENDER] ⚠️ prepareWindow() skipped - metadata already prepared", category: .ui)
            return
        }

        let viewModel = ensurePreparedViewModel(coordinator: coordinator)
        viewModel.isTapeHidden = true
        Log.info(
            "[TIMELINE-PRERENDER] 📊 Headless view model prepared, elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms",
            category: .ui
        )

        // Load the most recent frame data in the background
        Task { @MainActor in
            await viewModel.loadMostRecentFrame(refreshPresentation: false)
            Log.info("[TIMELINE-PRERENDER] 📊 Frame data loaded, total elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)
        }

        isPrepared = true
        Log.info("[TIMELINE-PRERENDER] ✅ prepareWindow() completed, total=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)
    }

    // MARK: - Show/Hide

	    /// Show the timeline overlay on the current screen
    public func show() {
        cancelDeferredHostingViewDetach()
        cancelWindowFadeIn(reason: "show")

        // If we're in the middle of hiding, cancel the animation and snap back to visible
        if isHiding, let window = window {
            isHiding = false
            // Cancel any running animation by setting duration to 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0
                window.animator().alphaValue = 1
            })
            isVisible = true
            Self.setEmergencyTimelineVisible(true)
            hideCompletionCoordinator.resumeAll(hidden: false)
            startObservingApplicationActivation()
            return
        }

        guard !isVisible, let coordinator = coordinator else {
            return
        }
        Log.info(
            "[TimelineToggle] show requested isVisible=\(isVisible) searchOverlayVisible=\(timelineViewModel?.isSearchOverlayVisible ?? false)",
            category: .ui
        )
        let showStartTime = CFAbsoluteTimeGetCurrent()
        liveModeCaptureTask?.cancel()
        liveModeCaptureTask = nil
        captureFocusRestoreTarget()
        // Only capture/use live screenshot if playhead is at or near the latest frame (last 3 frames)
        // Otherwise, user was viewing a historical frame and should see that instead
        var shouldUseLiveMode = true
        var shouldRefreshPreparedMetadataOnShow = false
        var navigateToNewestOnShowRefresh = true
        var allowNearLiveAutoAdvanceOnShowRefresh = true

        if let viewModel = timelineViewModel {
            let framesFromNewestBefore = max(0, viewModel.frames.count - 1 - viewModel.currentIndex)
            let hiddenElapsedSeconds = lastHiddenAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let loadedTapeIsRecent = viewModel.isNewestLoadedFrameRecent()
            let instantEligible = loadedTapeIsRecent &&
                framesFromNewestBefore < Self.instantLiveReopenFrameThreshold
            let nearEligible = loadedTapeIsRecent &&
                framesFromNewestBefore < Self.nearLiveReopenFrameThreshold
            let instantLiveExpiryElapsed = hiddenElapsedSeconds >= Self.instantLiveReopenExpirationSeconds
            let nearLiveExpiryElapsed = hiddenElapsedSeconds >= Self.nearLiveReopenExpirationSeconds
            let cacheExpired = hiddenElapsedSeconds > Self.hiddenStateCacheExpirationSeconds
            var hasActiveFilters = viewModel.filterCriteria.hasActiveFilters

            // Hidden-state cache expiry invalidates filters so reopen uses fresh unfiltered metadata.
            if cacheExpired, hasActiveFilters {
                viewModel.clearFiltersWithoutReload()
                hasActiveFilters = false
            }

            let shouldAutoAdvanceNearLive = !hasActiveFilters &&
                ((instantEligible && instantLiveExpiryElapsed) || (nearEligible && nearLiveExpiryElapsed))
            let shouldSnapToNewestOnShow = cacheExpired || shouldAutoAdvanceNearLive
            let shouldClearSearchForReopenPolicy = shouldSnapToNewestOnShow
            let hiddenLabel = hiddenElapsedSeconds.isFinite ? String(format: "%.1f", hiddenElapsedSeconds) : "inf"

            let snapReason: String
            if cacheExpired {
                snapReason = "cache_expired"
            } else if instantEligible && instantLiveExpiryElapsed {
                snapReason = "instant_near_edge"
            } else if nearEligible && nearLiveExpiryElapsed {
                snapReason = "near_live_expired"
            } else {
                snapReason = "none"
            }

            if shouldClearSearchForReopenPolicy {
                let searchViewModel = viewModel.searchViewModel
                if searchViewModel.hasResults || !searchViewModel.searchQuery.isEmpty {
                    Log.info(
                        "[TIMELINE-REOPEN] Clearing search state before show (reason=\(snapReason))",
                        category: .ui
                    )
                    searchViewModel.clearSearchResults()
                }
            }

            if shouldSnapToNewestOnShow, !viewModel.frames.isEmpty {
                let newestIndex = max(0, viewModel.frames.count - 1)
                let oldIndex = viewModel.currentIndex
                if oldIndex != newestIndex {
                    viewModel.currentIndex = newestIndex
                    Log.info(
                        "[TIMELINE-REOPEN] snapOnShow oldIndex=\(oldIndex) newIndex=\(newestIndex) reason=\(snapReason)",
                        category: .ui
                    )
                }
            }

            shouldRefreshPreparedMetadataOnShow = true
            navigateToNewestOnShowRefresh = shouldSnapToNewestOnShow
            allowNearLiveAutoAdvanceOnShowRefresh = shouldAutoAdvanceNearLive || cacheExpired

            let framesFromNewestAfter = max(0, viewModel.frames.count - 1 - viewModel.currentIndex)
            shouldUseLiveMode = loadedTapeIsRecent &&
                viewModel.isNearLatestLoadedFrame(within: Self.instantLiveReopenFrameThreshold)

            Log.info(
                "[TIMELINE-REOPEN] hidden=\(hiddenLabel)s framesFromNewestBefore=\(framesFromNewestBefore) framesFromNewestAfter=\(framesFromNewestAfter) loadedTapeIsRecent=\(loadedTapeIsRecent) instantEligible=\(instantEligible) instantExpiryElapsed=\(instantLiveExpiryElapsed) nearEligible=\(nearEligible) nearExpiryElapsed=\(nearLiveExpiryElapsed) cacheExpired=\(cacheExpired) hasActiveFilters=\(hasActiveFilters) shouldSnapOnShow=\(shouldSnapToNewestOnShow) liveModeOnShow=\(shouldUseLiveMode)",
                category: .ui
            )
        }

        // Remember if dashboard was the key window before we take over
        dashboardWasKeyWindow = DashboardWindowController.shared.isVisible &&
            NSApp.keyWindow == DashboardWindowController.shared.window

        // Get the screen where the mouse cursor is located
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        // Reset scale factor cache so it recalculates for the current display
        TimelineScaleFactor.resetCache()

        // Check if we have a prepared metadata state ready
        if isPrepared, let viewModel = timelineViewModel {
            mountPresentationIfNeeded(
                on: targetScreen,
                coordinator: coordinator,
                viewModel: viewModel
            )
            prepareLiveModeState(shouldUseLiveMode: shouldUseLiveMode, viewModel: viewModel)
            viewModel.isTapeHidden = true
            tapeShowAnimationTask?.cancel()

            // Log cache state
            if let lastHidden = lastHiddenAt {
                let elapsed = Date().timeIntervalSince(lastHidden)
                Log.info("[TIMELINE-SHOW] Using headless prepared state (hidden \(Int(elapsed))s ago)", category: .ui)
            } else {
                Log.info("[TIMELINE-SHOW] First show after headless prerender", category: .ui)
            }

            showPreparedWindow(
                coordinator: coordinator,
                openPath: "prepared_headless",
                showStartTime: showStartTime
            )
            startLiveModeCaptureIfNeeded(shouldUseLiveMode: shouldUseLiveMode, viewModel: viewModel)
            if shouldRefreshPreparedMetadataOnShow {
                refreshTimelineMetadataOnShow(
                    viewModel: viewModel,
                    navigateToNewest: navigateToNewestOnShowRefresh,
                    allowNearLiveAutoAdvance: allowNearLiveAutoAdvanceOnShowRefresh
                )
            }
            return
        }

        // Fallback: Create presentation and view model from scratch (prerender disabled or unavailable).
        Log.info("[TIMELINE-SHOW] ⚠️ Using FALLBACK path - creating new window and viewModel from scratch", category: .ui)
        let viewModel = SimpleTimelineViewModel(coordinator: coordinator)
        setTimelineViewModel(viewModel)
        prepareLiveModeState(shouldUseLiveMode: shouldUseLiveMode, viewModel: viewModel)
        viewModel.isTapeHidden = true
        tapeShowAnimationTask?.cancel()
        mountPresentationIfNeeded(
            on: targetScreen,
            coordinator: coordinator,
            viewModel: viewModel
        )
        self.isPrepared = true

        // Show the window
        showPreparedWindow(
            coordinator: coordinator,
            openPath: "fallback",
            showStartTime: showStartTime
        )
        startLiveModeCaptureIfNeeded(shouldUseLiveMode: shouldUseLiveMode, viewModel: viewModel)
        refreshTimelineMetadataOnShow(
            viewModel: viewModel,
            navigateToNewest: true,
            allowNearLiveAutoAdvance: true
        )
    }

    /// Show the prepared window with animation and setup event monitors
    private func showPreparedWindow(
        coordinator: AppCoordinator,
        openPath: String,
        showStartTime: CFAbsoluteTime
    ) {
        guard let window = window else { return }

        timelineViewModel?.isTapeHidden = true
        tapeShowAnimationTask?.cancel()

        // Log current view model state before showing
        if let viewModel = timelineViewModel {
            let currentVideoInfo = viewModel.currentVideoInfo
            Log.info("[TIMELINE-SHOW] 🎬 About to show window - currentIndex=\(viewModel.currentIndex), frames.count=\(viewModel.frames.count), videoPath=\(currentVideoInfo?.videoPath.suffix(30) ?? "nil"), frameIndex=\(currentVideoInfo?.frameIndex ?? -1)", category: .ui)
        }

        // Force video reload BEFORE showing window to avoid flicker
        // This ensures AVPlayer loads fresh video data with any new frames
        // Skip this when in live mode since we're showing a live screenshot instead
        if let viewModel = timelineViewModel, !viewModel.isInLiveMode, viewModel.frames.count > 1 {
            viewModel.forceVideoReload = true
            let original = viewModel.currentIndex
            viewModel.currentIndex = max(0, original - 1)
            viewModel.currentIndex = original
        }
        timelineViewModel?.setPresentationWorkEnabled(true, reason: "showPreparedWindow")
        timelineViewModel?.refreshStaticPresentationIfNeeded()

        let isLive = timelineViewModel?.isInLiveMode ?? false
        if isLive {
            suppressLiveScrollUntil = CFAbsoluteTimeGetCurrent() + Self.liveScrollSuppressDuration
        } else {
            suppressLiveScrollUntil = 0
        }
        window.alphaValue = isLive ? 1 : 0

        // Re-enable mouse events before showing (was disabled while hidden to prevent blocking clicks)
        window.ignoresMouseEvents = false

        // Always start visible sessions with context menus closed.
        if let viewModel = timelineViewModel {
            viewModel.dismissContextMenu()
            viewModel.dismissTimelineContextMenu()
        }

        Log.info("[TIMELINE-SHOW] 🚀 WINDOW BECOMING VISIBLE NOW (makeKeyAndOrderFront)", category: .ui)
        // Re-assert Space behavior before each open so cached windows always
        // materialize on the currently active Desktop.
        window.collectionBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior.insert(.moveToActiveSpace)
        // Mark visible before activation to avoid activation-time dashboard reveal
        // races that can switch Spaces on some machines.
        isVisible = true
        Self.setEmergencyTimelineVisible(true)  // For emergency escape tap
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startObservingApplicationActivation()
        if let hostingView = hostingView {
            DispatchQueue.main.async { [weak hostingView] in
                hostingView?.layoutSubtreeIfNeeded()
            }
        }
        let openElapsedMs = (CFAbsoluteTimeGetCurrent() - showStartTime) * 1000
        Log.recordLatency(
            "timeline.open.window_visible_ms",
            valueMs: openElapsedMs,
            category: .ui,
            summaryEvery: 5,
            warningThresholdMs: 250,
            criticalThresholdMs: 600
        )
        Log.recordLatency(
            "timeline.open.\(openPath).window_visible_ms",
            valueMs: openElapsedMs,
            category: .ui,
            summaryEvery: 5,
            warningThresholdMs: 250,
            criticalThresholdMs: 600
        )

        // Fade in only for non-live opens (prevents the live screenshot "zoom" feel)
        if !isLive, let viewModel = timelineViewModel {
            scheduleHistoricalFadeIn(window: window, viewModel: viewModel)
        }

        // Trigger tape slide-up animation (Cmd+H style)
        tapeShowAnimationTask = Task { @MainActor in
            await Task.yield()
            guard let viewModel = self.timelineViewModel, !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                viewModel.isTapeHidden = false
            }
        }

        // Track timeline open event
        DashboardViewModel.recordTimelineOpen(coordinator: coordinator)

        // Setup keyboard monitoring
        setupEventMonitors()

        // Notify coordinator to pause frame processing while timeline is visible
        Task {
            await coordinator.setTimelineVisible(true)
        }

        // Track session start time for duration metrics
        sessionStartTime = Date()
        sessionScrubDistance = 0  // Reset scrub distance for new session
        timelineViewModel?.resetVisibleSessionScrubTracking()

        // Post notification so menu bar can hide recording indicator
        NotificationCenter.default.post(name: .timelineDidOpen, object: nil)

    }

    /// Hide the timeline overlay
    public func hide(restorePreviousFocus: Bool = true) {
        guard isVisible, let window = window, !isHiding else { return }
        Log.info(
            "[TimelineToggle] hide requested restorePreviousFocus=\(restorePreviousFocus) searchOverlayVisible=\(timelineViewModel?.isSearchOverlayVisible ?? false)",
            category: .ui
        )
        let hideRequestStartedAt = CFAbsoluteTimeGetCurrent()
        isHiding = true
        stopObservingApplicationActivation()
        cancelWindowFadeIn(reason: "hide")
        liveModeCaptureTask?.cancel()
        liveModeCaptureTask = nil

        // Record timeline session duration (only if > 3 seconds)
        if let startTime = sessionStartTime, let coordinator = coordinator {
            let durationMs = Int64(Date().timeIntervalSince(startTime) * 1000)
            DashboardViewModel.recordTimelineSession(coordinator: coordinator, durationMs: durationMs)

            // Record scrub distance metric
            if sessionScrubDistance > 0 {
                DashboardViewModel.recordScrubDistance(coordinator: coordinator, distancePixels: sessionScrubDistance)
            }

            sessionStartTime = nil
            sessionScrubDistance = 0  // Reset scrub distance for next session
        }

        // Don't save position on hide - window stays in memory
        // Position is only saved on app termination (see savePositionForTermination)

        // Cancel any running fade-in animation before starting fade-out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0
            window.animator().alphaValue = window.alphaValue  // Snap to current value
        })

        tapeShowAnimationTask?.cancel()
        if let viewModel = timelineViewModel {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                viewModel.isTapeHidden = true
            }
            // Abort in-flight search work now that the timeline is dismissing.
            viewModel.searchViewModel.cancelSearch()
            // Ensure right-click menus don't persist across timeline sessions.
            viewModel.dismissContextMenu()
            viewModel.dismissTimelineContextMenu()

            // Dismiss any open overlays (filter panel, date search, etc.)
            if viewModel.isFilterPanelVisible {
                viewModel.dismissFilterPanel()
            }
            if viewModel.isCalendarPickerVisible {
                viewModel.isCalendarPickerVisible = false
                viewModel.hoursWithFrames = []
                viewModel.selectedCalendarDate = nil
                viewModel.calendarKeyboardFocus = .dateGrid
                viewModel.selectedCalendarHour = nil
            }
            if viewModel.isDateSearchActive {
                viewModel.closeDateSearch()
            }
            if viewModel.isSearchOverlayVisible {
                // Keep the search overlay/search bar state across timeline toggle.
                // Simulate clicking the recent-entries header "x" on toggle-off, then
                // suppress recent entries on next overlay presentation.
                viewModel.searchViewModel.requestDismissRecentEntriesPopoverByUser()
                viewModel.searchViewModel.suppressRecentEntriesForNextOverlayOpen()
            }
            if viewModel.isInFrameSearchVisible ||
                !viewModel.inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                viewModel.closeInFrameSearch(clearQuery: true)
            }
        }

        // Remove event monitors
        removeEventMonitors()

        // Animate out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let wasHidingToShowDashboard = self.isHidingToShowDashboard
                self.isHiding = false
                // Only hide dashboard if it wasn't the active window before timeline opened
                // AND we're not hiding specifically to show the dashboard/settings
                // This prevents hiding the dashboard when user had it focused and just opened/closed timeline
                // Also don't hide if a modal sheet (feedback form, etc.) is attached
                if self.dashboardWasKeyWindow != true,
                   !wasHidingToShowDashboard,
                   DashboardWindowController.shared.window?.attachedSheet == nil {
                    DashboardWindowController.shared.hide()
                }
                // Reset the flag after use
                self.isHidingToShowDashboard = false

                // Hide window but keep it around for instant re-show
                // This is the key optimization - we don't destroy the window or view model
                // CRITICAL: Ignore mouse events while hidden to prevent blocking clicks on other windows
                window.ignoresMouseEvents = true
                window.orderOut(nil)
                self.isVisible = false
                Self.setEmergencyTimelineVisible(false)  // For emergency escape tap
                self.lastHiddenAt = Date()
                self.suppressLiveScrollUntil = 0
                let hideElapsedMs = (CFAbsoluteTimeGetCurrent() - hideRequestStartedAt) * 1000
                Log.recordLatency(
                    "timeline.hide.window_hidden_ms",
                    valueMs: hideElapsedMs,
                    category: .ui,
                    summaryEvery: 10,
                    warningThresholdMs: 300,
                    criticalThresholdMs: 600
                )
                Log.info(
                    "[TimelineToggle] window hidden after \(String(format: "%.1f", hideElapsedMs))ms",
                    category: .ui
                )
                self.restoreFocusIfNeeded(
                    requestedRestore: restorePreviousFocus,
                    wasHidingToShowDashboard: wasHidingToShowDashboard,
                    hideRequestedAt: hideRequestStartedAt
                )
                // Mark timeline hidden before post-hide refresh so frame reads can use relaxed timing.
                if let coordinator = self.coordinator {
                    await coordinator.setTimelineVisible(false)
                }

                self.hideCompletionCoordinator.resumeAll(hidden: true)

                await self.compactHiddenPresentationState()

                self.onClose?()

                // Reset the cached scale factor so it recalculates for next window
                TimelineScaleFactor.resetCache()

                // Post notification so menu bar can restore recording indicator
                NotificationCenter.default.post(name: .timelineDidClose, object: nil)
            }
        })
    }

    // MARK: - Timeline Metadata Refresh

    /// Move the hidden window to the screen where the mouse is (for instant show on any screen)
    private func moveWindowToMouseScreen() {
        guard let window = window, !isVisible else { return }

        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        if window.frame != targetScreen.frame {
            window.setFrame(targetScreen.frame, display: false)
            // Reset scale factor cache so it recalculates for the new display
            TimelineScaleFactor.resetCache()
        }
    }

    /// Capture a live screenshot off the main actor to avoid blocking timeline-open path.
    /// When the timeline window is visible, capture only content below it so we don't
    /// bake partially hidden timeline controls into the live screenshot.
    private func captureLiveScreenshotAsync() async -> NSImage? {
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else {
            return nil
        }

        guard let screenNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        let screenSize = targetScreen.frame.size
        let screenBounds = CGDisplayBounds(screenNumber)
        let timelineWindowID: CGWindowID?
        if let candidate = window, candidate.isVisible {
            timelineWindowID = CGWindowID(candidate.windowNumber)
        } else {
            timelineWindowID = nil
        }
        let captureStartTime = CFAbsoluteTimeGetCurrent()
        let captureTask = Task.detached(priority: .userInitiated) { [screenBounds, screenNumber, timelineWindowID] () -> CGImage? in
            // Prefer a below-window capture to avoid including the timeline overlay itself.
            if let timelineWindowID,
               let image = CGWindowListCreateImage(
                   screenBounds,
                   .optionOnScreenBelowWindow,
                   timelineWindowID,
                   [.boundsIgnoreFraming]
               ) {
                return image
            }

            // Fallback to full display capture when below-window capture is unavailable.
            return CGDisplayCreateImage(screenNumber)
        }
        let cgImage = await captureTask.value
        let captureElapsedMs = (CFAbsoluteTimeGetCurrent() - captureStartTime) * 1000
        Log.recordLatency(
            "timeline.live_screenshot.capture_ms",
            valueMs: captureElapsedMs,
            category: .ui,
            summaryEvery: 20,
            warningThresholdMs: 40,
            criticalThresholdMs: 120
        )

        guard let cgImage else {
            Log.warning("[TIMELINE-LIVE] Failed to capture live screenshot", category: .ui)
            return nil
        }

        return NSImage(cgImage: cgImage, size: screenSize)
    }

    /// Starts asynchronous live screenshot capture and then triggers live OCR.
    /// This keeps timeline open responsive by removing heavy capture from the critical show path.
    private func prepareLiveModeState(shouldUseLiveMode: Bool, viewModel: SimpleTimelineViewModel) {
        if shouldUseLiveMode {
            // Prime live mode before showing the window so open animation/render path
            // matches previous behavior while screenshot capture finishes in background.
            viewModel.isInLiveMode = true
            viewModel.liveScreenshot = nil
        } else {
            viewModel.isInLiveMode = false
            viewModel.liveScreenshot = nil
        }
    }

    /// Starts asynchronous live screenshot capture and then triggers live OCR.
    /// This keeps timeline open responsive by removing heavy capture from the critical show path.
    private func startLiveModeCaptureIfNeeded(shouldUseLiveMode: Bool, viewModel: SimpleTimelineViewModel) {
        guard shouldUseLiveMode else {
            viewModel.isInLiveMode = false
            viewModel.liveScreenshot = nil
            return
        }

        let targetViewModel = viewModel
        liveModeCaptureTask = Task { @MainActor [weak self, weak targetViewModel] in
            guard let self, let targetViewModel else { return }
            let screenshot = await self.captureLiveScreenshotAsync()
            guard !Task.isCancelled else { return }
            guard self.isVisible, self.timelineViewModel === targetViewModel else { return }
            guard targetViewModel.isNewestLoadedFrameRecent() else {
                targetViewModel.isInLiveMode = false
                targetViewModel.liveScreenshot = nil
                return
            }
            guard targetViewModel.isNearLatestLoadedFrame(within: Self.instantLiveReopenFrameThreshold) else { return }
            guard let screenshot else {
                // Fall back to historical frame rendering if live capture fails.
                targetViewModel.isInLiveMode = false
                targetViewModel.liveScreenshot = nil
                return
            }

            targetViewModel.isInLiveMode = true
            targetViewModel.liveScreenshot = screenshot
            targetViewModel.performLiveOCR()
        }
    }

    /// Refresh metadata when timeline launches so hidden windows don't need periodic background refresh.
    private func refreshTimelineMetadataOnShow(
        viewModel: SimpleTimelineViewModel,
        navigateToNewest: Bool,
        allowNearLiveAutoAdvance: Bool
    ) {
        Task { @MainActor [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            guard self.isVisible, self.timelineViewModel === viewModel else { return }

            await viewModel.refreshFrameData(
                navigateToNewest: navigateToNewest,
                allowNearLiveAutoAdvance: allowNearLiveAutoAdvance,
                refreshPresentation: true
            )
        }
    }


    /// Save state for cross-session persistence (call on app termination)
    public func saveStateForTermination() {
        Log.info("[TIMELINE-PRERENDER] 💾 saveStateForTermination() called", category: .ui)
        timelineViewModel?.saveState()
    }

    /// Completely destroy the pre-rendered window (call when memory pressure is high or app is terminating)
    public func destroyPreparedWindow() {
        Log.info("[TIMELINE-PRERENDER] 🗑️ destroyPreparedWindow() called", category: .ui)
        // Save state before destroying for cross-session persistence
        timelineViewModel?.saveState()
        timelineViewModel?.compactPresentationState(reason: "destroyPreparedWindow", purgeDiskFrameBuffer: true)
        destroyMountedPresentation()
        if let coordinator {
            Task {
                await coordinator.purgeVideoDecodingCaches(reason: "destroyPreparedWindow")
            }
        }
        timelineViewModel = nil
        isPrepared = false
    }

    @MainActor
    private func compactHiddenPresentationState() async {
        let viewModel = timelineViewModel

        if let viewModel {
            viewModel.isTapeHidden = true
            viewModel.resetControlsVisibilityForNextOpen()  // Reset controls visibility so they show on next open
            viewModel.resetFrameZoom()  // Reset zoom so it's at 100% on next open
            viewModel.compactPresentationState(
                reason: "hide-keep-headless-state",
                purgeDiskFrameBuffer: false
            )
            // Reset zoom region state on hide.
            viewModel.exitZoomRegion()
        } else {
            Log.warning("[TimelineToggle] Missing timeline view model during hide compaction", category: .ui)
        }

        // Always detach any mounted presentation and purge decode caches, even if the
        // prepared view model vanished unexpectedly. Otherwise hidden decoder work can linger.
        destroyMountedPresentation()
        if let coordinator {
            await coordinator.purgeVideoDecodingCaches(reason: "timeline hidden")
        }
    }

    private func scheduleDeferredHostingViewDetach() {
        cancelDeferredHostingViewDetach()
        deferredHostingViewDetachTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.hostingViewDetachDelay, clock: .continuous)
            guard let self, !self.isVisible else { return }
            self.hostingView?.removeFromSuperview()
        }
    }

    private func cancelDeferredHostingViewDetach() {
        deferredHostingViewDetachTask?.cancel()
        deferredHostingViewDetachTask = nil
    }

    private func ensurePreparedViewModel(coordinator: AppCoordinator) -> SimpleTimelineViewModel {
        if let existing = timelineViewModel {
            isPrepared = true
            return existing
        }

        let viewModel = SimpleTimelineViewModel(coordinator: coordinator)
        setTimelineViewModel(viewModel)
        isPrepared = true
        return viewModel
    }

    func refreshTapeIndicatorsAfterExternalMutation(reason: String) {
        timelineViewModel?.refreshTapeIndicatorsAfterExternalMutation(reason: reason)
    }

    private func mountPresentationIfNeeded(
        on screen: NSScreen,
        coordinator: AppCoordinator,
        viewModel: SimpleTimelineViewModel
    ) {
        if let window {
            if window.frame != screen.frame {
                window.setFrame(screen.frame, display: false)
            }

            if let hostingView, hostingView.superview == nil {
                hostingView.frame = window.contentView?.bounds ?? .zero
                window.contentView?.addSubview(hostingView)
                hostingView.needsLayout = true
                window.contentView?.needsLayout = true
            }
            return
        }

        guard let coordinatorWrapper else {
            Log.error("[TIMELINE] Coordinator wrapper not initialized", category: .ui)
            return
        }

        let window = createWindow(for: screen)
        let timelineView = SimpleTimelineView(
            coordinator: coordinator,
            viewModel: viewModel,
            onClose: { [weak self] in
                self?.hide()
            }
        )
        .environmentObject(coordinatorWrapper)

        let hostingView = FirstMouseHostingView(rootView: timelineView)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hostingView)

        self.window = window
        self.hostingView = hostingView
    }

    private func destroyMountedPresentation() {
        cancelDeferredHostingViewDetach()
        cancelWindowFadeIn(reason: "destroyMountedPresentation")
        liveModeCaptureTask?.cancel()
        liveModeCaptureTask = nil
        stopObservingApplicationActivation()
        timelineViewModel?.setPresentationWorkEnabled(false, reason: "destroyMountedPresentation")

        window?.orderOut(nil)
        hostingView?.removeFromSuperview()
        hostingView = nil
        window = nil
    }

    /// Toggle timeline visibility
    public func toggle() {
        Log.info(
            "[TimelineToggle] toggle invoked currentlyVisible=\(isVisible) searchOverlayVisible=\(timelineViewModel?.isSearchOverlayVisible ?? false)",
            category: .ui
        )
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Hide the timeline to show dashboard or settings
    /// This prevents the dashboard from being auto-hidden when the timeline closes
    public func hideToShowDashboard() {
        isHidingToShowDashboard = true
        hide(restorePreviousFocus: false)
    }

    /// Show the timeline and navigate to a specific date
    public func showAndNavigate(to date: Date) {
        show()

        // Navigate after a brief delay to allow the view to initialize
        Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(300_000_000)), clock: .continuous) // 0.3 seconds
            await timelineViewModel?.navigateToHour(date)
        }
    }

    /// Show timeline and apply deeplink search state (`q`, `app`, `t`/`timestamp`).
    public func showSearch(query: String?, timestamp: Date?, appBundleID: String?, source: String = "unknown") {
        deeplinkSearchInvocationCounter += 1
        let invocationID = deeplinkSearchInvocationCounter
        Log.info(
            "[DeeplinkSearch] Invocation #\(invocationID) source=\(source), query=\(query ?? "nil"), timestamp=\(String(describing: timestamp)), app=\(appBundleID ?? "nil")",
            category: .ui
        )

        if let timestamp {
            showAndNavigate(to: timestamp)
        } else {
            show()
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.coordinator != nil else {
                Log.warning("[DeeplinkSearch] Invocation #\(invocationID) failed - timeline coordinator unavailable", category: .ui)
                return
            }
            let viewModel = await self.awaitTimelineViewModelReady()

            Log.info("[DeeplinkSearch] Invocation #\(invocationID) applying deeplink payload", category: .ui)
            viewModel.applySearchDeeplink(query: query, appBundleID: appBundleID, source: source)
        }
    }

    /// Show the timeline and open the spotlight search overlay, preserving any existing search state.
    public func showSearchOverlay(
        source: String = "unknown",
        recentEntriesRevealDelay: TimeInterval = 0.3
    ) {
        Log.info(
            "[TimelineSearchOverlay] showSearchOverlay source=\(source) isVisible=\(isVisible) searchOverlayVisible=\(timelineViewModel?.isSearchOverlayVisible ?? false)",
            category: .ui
        )
        show()

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.coordinator != nil else {
                Log.warning(
                    "[TimelineSearchOverlay] Failed to open search overlay because the timeline coordinator is unavailable source=\(source)",
                    category: .ui
                )
                return
            }
            let viewModel = await self.awaitTimelineViewModelReady()

            _ = Self.presentSearchOverlay(
                on: viewModel,
                coordinator: self.coordinator,
                recentEntriesRevealDelay: recentEntriesRevealDelay
            )
        }
    }

    @MainActor
    private func awaitTimelineViewModelReady() async -> SimpleTimelineViewModel {
        if let timelineViewModel {
            return timelineViewModel
        }

        return await withCheckedContinuation { continuation in
            pendingTimelineViewModelWaiters.append(continuation)
        }
    }

    @discardableResult
    static func presentSearchOverlay(
        on viewModel: SimpleTimelineViewModel,
        coordinator: AppCoordinator?,
        recentEntriesRevealDelay: TimeInterval = 0.3
    ) -> Bool {
        let wasVisible = viewModel.isSearchOverlayVisible
        viewModel.openSearchOverlay(recentEntriesRevealDelay: recentEntriesRevealDelay)

        if !wasVisible, let coordinator {
            DashboardViewModel.recordSearchDialogOpen(coordinator: coordinator)
        }

        return !wasVisible
    }

    private func setTimelineViewModel(_ viewModel: SimpleTimelineViewModel) {
        timelineViewModel = viewModel

        let waiters = pendingTimelineViewModelWaiters
        pendingTimelineViewModelWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: viewModel)
        }
    }

    private func isSingleAppOnlyIncludeFilter(_ criteria: FilterCriteria, matching bundleID: String? = nil) -> Bool {
        guard criteria.appFilterMode == .include,
              let selectedApps = criteria.selectedApps,
              selectedApps.count == 1 else {
            return false
        }
        if let bundleID {
            guard selectedApps.contains(bundleID) else { return false }
        }

        let hasNoSources = criteria.selectedSources == nil || criteria.selectedSources?.isEmpty == true
        let hasNoTags = criteria.selectedTags == nil || criteria.selectedTags?.isEmpty == true
        let hasNoWindowFilter = criteria.windowNameFilter?.isEmpty ?? true
        let hasNoBrowserFilter = criteria.browserUrlFilter?.isEmpty ?? true

        return hasNoSources &&
            criteria.hiddenFilter == .hide &&
            criteria.commentFilter == .allFrames &&
            hasNoTags &&
            criteria.tagFilterMode == .include &&
            hasNoWindowFilter &&
            hasNoBrowserFilter &&
            criteria.effectiveDateRanges.isEmpty
    }

    /// Resolve quick app filter trigger key from an NSEvent.
    /// Supports Option+F.
    private func quickAppFilterTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == [.option] && (key == "f" || event.keyCode == 3) {
            return "Option+F"
        }
        return nil
    }

    /// Resolve add-tag shortcut key from an NSEvent.
    /// Supports Cmd+T.
    private func addTagShortcutTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        guard event.keyCode == 17 else { // T key
            return nil
        }
        if modifiers == [.command] {
            return "Cmd+T"
        }
        return nil
    }

    /// Resolve add-comment shortcut key from an NSEvent.
    /// Supports Option+C.
    private func addCommentShortcutTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        guard event.keyCode == 8 else { // C key
            return nil
        }
        if modifiers == [.option] {
            return "Option+C"
        }
        return nil
    }

    /// Resolve open-link shortcut key from an NSEvent.
    /// Supports Cmd+Shift+L with both keycode and character fallback.
    private func openLinkShortcutTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        let matchesLKey = event.keyCode == 37 || event.charactersIgnoringModifiers?.lowercased() == "l"
        guard matchesLKey else { return nil }
        return modifiers == [.command, .shift] ? "Cmd+Shift+L" : nil
    }

    /// Resolve copy-link shortcut key from an NSEvent.
    /// Supports Cmd+L with both keycode and character fallback.
    private func copyLinkShortcutTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        let matchesLKey = event.keyCode == 37 || event.charactersIgnoringModifiers?.lowercased() == "l"
        guard matchesLKey else { return nil }
        return modifiers == [.command] ? "Cmd+L" : nil
    }

    /// Resolve copy-YouTube-markdown shortcut key from an NSEvent.
    /// Supports Option+Cmd+L with both keycode and character fallback.
    private func copyYouTubeMarkdownLinkShortcutTrigger(
        for event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        let matchesLKey = event.keyCode == 37 || event.charactersIgnoringModifiers?.lowercased() == "l"
        guard matchesLKey else { return nil }
        return modifiers == [.command, .option] ? "Option+Cmd+L" : nil
    }

    /// Resolve copy-moment-link shortcut key from an NSEvent.
    /// Supports Option+Shift+L with both keycode and character fallback.
    private func copyMomentLinkShortcutTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        let matchesLKey = event.keyCode == 37 || event.charactersIgnoringModifiers?.lowercased() == "l"
        guard matchesLKey else { return nil }
        return modifiers == [.option, .shift] ? "Option+Shift+L" : nil
    }

    /// Toggle quick app filter for the app at the current playhead.
    /// First press applies a single-app include filter, second press clears it.
    private func togglePlayheadAppFilter(trigger: String) {
        guard let viewModel = timelineViewModel else {
            return
        }

        let shortcutMetric = trigger == "Option+F" ? "opt+f" : "cmd+f"
        recordShortcut(shortcutMetric)

        guard let currentFrame = viewModel.currentTimelineFrame else {
            return
        }

        guard let bundleID = currentFrame.frame.metadata.appBundleID, !bundleID.isEmpty else {
            return
        }

        if isSingleAppOnlyIncludeFilter(viewModel.filterCriteria, matching: bundleID) {
            viewModel.beginCmdFQuickFilterLatencyTrace(
                bundleID: bundleID,
                action: "clear_app_filter",
                trigger: trigger,
                source: currentFrame.frame.source
            )
            viewModel.clearAllFilters()
            return
        }

        viewModel.beginCmdFQuickFilterLatencyTrace(
            bundleID: bundleID,
            action: "apply_app_filter",
            trigger: trigger,
            source: currentFrame.frame.source
        )

        var criteria = FilterCriteria()
        criteria.selectedApps = Set([bundleID])
        criteria.appFilterMode = .include

        // Use the same pending+apply path as the filter panel's Apply button.
        viewModel.pendingFilterCriteria = criteria
        viewModel.applyFilters()
    }

    /// Hide or unhide the visible segment block at the current playhead index.
    private func hidePlayheadSegment(trigger _: String) {
        guard let viewModel = timelineViewModel else { return }
        guard !viewModel.frames.isEmpty else { return }

        let clampedIndex = max(0, min(viewModel.currentIndex, viewModel.frames.count - 1))
        viewModel.timelineContextMenuSegmentIndex = clampedIndex

        let isShowingHiddenSegments = viewModel.filterCriteria.hiddenFilter != .hide
        let isPlayheadSegmentHidden = viewModel.isFrameHidden(at: clampedIndex)

        if isShowingHiddenSegments && isPlayheadSegmentHidden {
            viewModel.unhideSelectedTimelineSegment()
        } else {
            viewModel.hideSelectedTimelineSegment()
        }
    }

    /// Open the timeline segment "Add Tag" submenu for the current playhead index.
    private func openAddTagSubmenuAtPlayhead(trigger _: String) {
        guard let viewModel = timelineViewModel else {
            return
        }
        guard !viewModel.frames.isEmpty else {
            return
        }

        let clampedIndex = max(0, min(viewModel.currentIndex, viewModel.frames.count - 1))
        let menuLocation = defaultTimelineContextMenuLocation()

        viewModel.dismissOtherDialogs()

        // Reset menu state before re-opening to avoid stale/half-mounted submenu state.
        viewModel.timelineContextMenuSegmentIndex = clampedIndex
        viewModel.timelineContextMenuLocation = menuLocation
        viewModel.selectedFrameIndex = clampedIndex
        viewModel.showTimelineContextMenu = false
        viewModel.showTagSubmenu = false
        viewModel.showNewTagInput = false
        viewModel.newTagName = ""
        viewModel.isHoveringAddTagButton = false

        // Open context menu on next runloop, then load tags, then open submenu.
        DispatchQueue.main.async { [weak self] in
            guard let self, let viewModel = self.timelineViewModel else {
                return
            }
            let liveIndex = max(0, min(viewModel.currentIndex, max(0, viewModel.frames.count - 1)))
            viewModel.timelineContextMenuSegmentIndex = liveIndex
            viewModel.timelineContextMenuLocation = menuLocation
            viewModel.selectedFrameIndex = liveIndex
            viewModel.showTimelineContextMenu = true
            viewModel.isHoveringAddTagButton = true

            Task { @MainActor in
                await viewModel.loadTags()

                DispatchQueue.main.async { [weak self] in
                    guard let self, let viewModel = self.timelineViewModel else {
                        return
                    }
                    // Re-assert menu visibility before opening submenu.
                    viewModel.showTimelineContextMenu = true
                    viewModel.isHoveringAddTagButton = true
                    viewModel.recordTagSubmenuOpen(source: "keyboard_cmd_t")
                    withAnimation(.easeOut(duration: 0.12)) {
                        viewModel.showTagSubmenu = true
                    }
                }
            }
        }
    }

    /// Open the timeline segment "Add Comment" composer for the current playhead index.
    private func openAddCommentComposerAtPlayhead(source: String) {
        guard let viewModel = timelineViewModel else {
            return
        }
        guard !viewModel.frames.isEmpty else {
            return
        }

        let clampedIndex = max(0, min(viewModel.currentIndex, viewModel.frames.count - 1))
        guard let block = viewModel.getBlock(forFrameAt: clampedIndex) else {
            return
        }

        viewModel.dismissOtherDialogs()
        withAnimation(.easeOut(duration: 0.15)) {
            viewModel.openCommentSubmenuForTimelineBlock(block, source: source)
        }
    }

    private func defaultTimelineContextMenuLocation() -> CGPoint {
        guard let contentView = window?.contentView else {
            return .zero
        }
        let size = contentView.bounds.size
        return CGPoint(x: size.width * 0.5, y: max(48, size.height - 140))
    }

    /// Show the timeline with a pre-applied filter for an app and window name
    /// This instantly opens a filtered timeline view without showing a dialog
    /// - Parameters:
    ///   - startDate: Optional start date for filtering (e.g., week start)
    ///   - endDate: Optional end date for filtering (e.g., now)
    ///   - clickStartTime: Optional start time from when the tab was clicked (for end-to-end timing)
    public func showWithFilter(bundleID: String, windowName: String?, browserUrl: String? = nil, startDate: Date? = nil, endDate: Date? = nil, clickStartTime: CFAbsoluteTime? = nil) {
        let startTime = clickStartTime ?? CFAbsoluteTimeGetCurrent()

        // Build the filter criteria upfront
        var criteria = FilterCriteria()
        criteria.selectedApps = Set([bundleID])
        criteria.appFilterMode = .include
        if let url = browserUrl, !url.isEmpty {
            criteria.browserUrlFilter = url
        } else if let window = windowName, !window.isEmpty {
            criteria.windowNameFilter = window
        }
        // Add date range filter
        criteria.startDate = startDate
        criteria.endDate = endDate

        // Prepare window invisibly first (don't show yet)
        prepareWindowInvisibly()

        // Load data, then fade in once ready
        Task { @MainActor in
            guard let viewModel = timelineViewModel, let coordinator = coordinator else { return }

            // Dashboard-driven timeline opens should not carry stale search highlight overlays.
            viewModel.resetSearchHighlightState()

            // Apply the filter criteria to viewModel
            viewModel.filterCriteria = criteria
            viewModel.pendingFilterCriteria = criteria

            // Query and load frames
            let frames = try? await coordinator.getMostRecentFramesWithVideoInfo(limit: 50, filters: criteria)

            // Load frames directly into viewModel
            await viewModel.loadFramesDirectly(frames ?? [], clickStartTime: startTime)

            // Small delay to let the view settle before fade-in
            try? await Task.sleep(for: .nanoseconds(Int64(100_000_000)), clock: .continuous) // 0.1 seconds

            // Now fade in the window with data already loaded
            fadeInPreparedWindow()

        }
    }

    /// Prepare the window invisibly without showing it yet
    /// Used by showWithFilter to load data before revealing
    private func prepareWindowInvisibly() {
        guard !isVisible, let coordinator = coordinator else { return }
        captureFocusRestoreTarget()

        // Remember if dashboard was the key window before we take over
        dashboardWasKeyWindow = DashboardWindowController.shared.isVisible &&
            NSApp.keyWindow == DashboardWindowController.shared.window

        // Get the screen where the mouse cursor is located
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        let viewModel = ensurePreparedViewModel(coordinator: coordinator)

        mountPresentationIfNeeded(
            on: targetScreen,
            coordinator: coordinator,
            viewModel: viewModel
        )

        // Ensure tape starts hidden for slide-up animation
        viewModel.isTapeHidden = true
    }

    /// Fade in the prepared window (called after data is loaded)
    private func fadeInPreparedWindow() {
        guard let window = window, let coordinator = coordinator else { return }
        cancelWindowFadeIn(reason: "fadeInPreparedWindow")

        // Reattach SwiftUI view if it was detached (on hide, we remove it from superview to stop display cycle)
        if let hostingView = hostingView, hostingView.superview == nil {
            hostingView.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(hostingView)
            hostingView.needsLayout = true
            window.contentView?.needsLayout = true
        }

        // Ensure tape starts hidden and cancel any pending animation
        timelineViewModel?.isTapeHidden = true
        tapeShowAnimationTask?.cancel()

        // Force video reload before showing
        if let viewModel = timelineViewModel, viewModel.frames.count > 1 {
            viewModel.forceVideoReload = true
            let original = viewModel.currentIndex
            viewModel.currentIndex = max(0, original - 1)
            viewModel.currentIndex = original
        }

        // Fade in for filter/historical path (data already loaded)
        window.alphaValue = 0
        // Re-enable mouse events before showing (was disabled while hidden to prevent blocking clicks)
        window.ignoresMouseEvents = false
        window.collectionBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior.insert(.moveToActiveSpace)
        // Mark visible before activation to avoid activation-time dashboard reveal
        // races that can switch Spaces on some machines.
        isVisible = true
        Self.setEmergencyTimelineVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let hostingView = hostingView {
            DispatchQueue.main.async { [weak hostingView] in
                hostingView?.layoutSubtreeIfNeeded()
            }
        }

        if let viewModel = timelineViewModel {
            scheduleHistoricalFadeIn(window: window, viewModel: viewModel)
        }

        // Trigger tape slide-up animation
        tapeShowAnimationTask = Task { @MainActor in
            await Task.yield()
            guard let viewModel = self.timelineViewModel, !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                viewModel.isTapeHidden = false
            }
        }

        // Track timeline open event
        DashboardViewModel.recordTimelineOpen(coordinator: coordinator)

        // Setup keyboard monitoring
        setupEventMonitors()

        // Notify coordinator to pause frame processing
        Task {
            await coordinator.setTimelineVisible(true)
        }

        // Post notification so menu bar can hide recording indicator
        NotificationCenter.default.post(name: .timelineDidOpen, object: nil)
    }

    private func cancelWindowFadeIn(reason _: String) {
        windowFadeInTask?.cancel()
        windowFadeInTask = nil
        windowFadeInGeneration &+= 1
    }

    private func scheduleHistoricalFadeIn(window: NSWindow, viewModel: SimpleTimelineViewModel) {
        cancelWindowFadeIn(reason: "scheduleHistoricalFadeIn")
        windowFadeInGeneration &+= 1
        let generation = windowFadeInGeneration
        windowFadeInTask = Task { @MainActor [weak self, weak viewModel] in
            guard let self, let viewModel else { return }

            _ = await viewModel.prepareHistoricalOpenStillFallbackIfNeeded()

            guard !Task.isCancelled,
                  self.windowFadeInGeneration == generation,
                  self.isVisible,
                  !self.isHiding,
                  self.window === window,
                  self.timelineViewModel === viewModel else {
                return
            }

            await NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            })

            if self.windowFadeInGeneration == generation {
                self.windowFadeInTask = nil
            }
        }
    }

    // MARK: - Window Creation

    private func createWindow(for screen: NSScreen) -> NSWindow {
        // Use custom window subclass that can become key even when borderless
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Configure window properties
        window.level = .screenSaver
        window.animationBehavior = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        // Keep timeline opens deterministic across machines/Spaces:
        // move the overlay to the active Desktop at open time instead of
        // relying on "join all Spaces" behavior, which can vary with user settings.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]

        // Make it cover the entire screen including menu bar
        window.setFrame(screen.frame, display: true)

        // Create content view with transparent background.
        // SwiftUI controls the visible backdrop (black during normal mode,
        // transparent while awaiting live screenshot when requested).
        let contentView = NSView(frame: screen.frame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView

        return window
    }

    // MARK: - Event Monitoring

    private func setupEventMonitors() {
        // Monitor for mouse events to handle click-drag scrubbing on the timeline tape
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isVisible else { return event }

            switch event.type {
            case .leftMouseDown:
                // Don't start tape drag if Shift is held (Shift+Drag is zoom region)
                guard !event.modifierFlags.contains(.shift) else { return event }

                // Check if the click is in the tape area
                let clickPoint = event.locationInWindow
                let isInTapeArea = self.isPointInTapeArea(clickPoint)
                let startedNearPlaybackControls = self.isPointNearPlaybackControls(clickPoint)

                // Playback controls (play/pause + speed menu) should always receive click
                // completion; don't prime tape drag in this region.
                if startedNearPlaybackControls {
                    return event
                }

                if isInTapeArea {
                    // Don't start drag if overlays are open
                    if let viewModel = self.timelineViewModel,
                       !viewModel.isSearchOverlayVisible,
                       !viewModel.isFilterDropdownOpen,
                       !viewModel.isDateSearchActive,
                       !viewModel.showTagSubmenu,
                       !viewModel.isCalendarPickerVisible {
                        // Cancel any ongoing momentum from a previous drag
                        viewModel.cancelTapeDragMomentum()

                        self.tapeDragStartX = clickPoint.x
                        self.tapeDragLastX = clickPoint.x
                        self.tapeDragStartPoint = clickPoint
                        self.tapeDragStartedNearPlaybackControls = startedNearPlaybackControls
                        self.isTapeDragging = true
                        self.tapeDragDidExceedThreshold = false
                        self.tapeDragVelocitySamples.removeAll()
                        // Don't consume — allow tap gestures to fire if user doesn't drag
                    }
                }
                return event

            case .leftMouseDragged:
                if self.isTapeDragging {
                    let currentX = event.locationInWindow.x
                    let totalDistance = abs(currentX - self.tapeDragStartX)

                    if !self.tapeDragDidExceedThreshold {
                        // Check if we've moved far enough to be a drag (not a click)
                        if totalDistance >= Self.tapeDragMinDistance {
                            self.tapeDragDidExceedThreshold = true
                            NSCursor.closedHand.push()
                            // Defer heavy operations during drag
                            if let viewModel = self.timelineViewModel {
                                Task { @MainActor in
                                    if !viewModel.isActivelyScrolling {
                                        viewModel.isActivelyScrolling = true
                                        viewModel.dismissContextMenu()
                                        viewModel.dismissTimelineContextMenu()
                                    }
                                }
                            }
                        } else {
                            return event // Not yet a drag, let other handlers process
                        }
                    }

                    // Calculate pixel delta since last drag event
                    let deltaX = currentX - self.tapeDragLastX
                    self.tapeDragLastX = currentX

                    // Record velocity sample (prune old samples)
                    let now = CFAbsoluteTimeGetCurrent()
                    self.tapeDragVelocitySamples.append((time: now, delta: deltaX))
                    self.tapeDragVelocitySamples.removeAll { now - $0.time > Self.velocitySampleWindow }

                    // Feed delta into the scroll handling system
                    // Negate: dragging right (positive deltaX) should move tape right (grab-and-pull)
                    if abs(deltaX) > 0.001, let viewModel = self.timelineViewModel {
                        Task { @MainActor in
                            await viewModel.handleScroll(delta: -deltaX, isTrackpad: true)
                        }
                    }

                    return nil // Consume the event to prevent other handlers
                }
                return event

            case .leftMouseUp:
                if self.isTapeDragging {
                    let wasDragging = self.tapeDragDidExceedThreshold
                    self.isTapeDragging = false
                    self.tapeDragDidExceedThreshold = false

                    if wasDragging {
                        NSCursor.pop()

                        // Calculate release velocity from recent samples
                        let now = CFAbsoluteTimeGetCurrent()
                        let recentSamples = self.tapeDragVelocitySamples.filter { now - $0.time <= Self.velocitySampleWindow }
                        self.tapeDragVelocitySamples.removeAll()

                        var velocity: CGFloat = 0
                        if recentSamples.count >= 2,
                           let first = recentSamples.first, let last = recentSamples.last {
                            let dt = last.time - first.time
                            if dt > 0.001 {
                                let totalDelta = recentSamples.reduce(0) { $0 + $1.delta }
                                velocity = totalDelta / CGFloat(dt) // pixels per second
                            }
                        }

                        if let viewModel = self.timelineViewModel {
                            // Negate velocity to match scroll convention (same as drag delta)
                            let scrollVelocity = -velocity
                            Task { @MainActor in
                                viewModel.endTapeDrag(withVelocity: scrollVelocity)
                            }
                        }
                        self.tapeDragStartedNearPlaybackControls = false
                        self.tapeDragStartPoint = .zero
                        return nil // Consume the event
                    }
                    self.tapeDragStartedNearPlaybackControls = false
                    self.tapeDragStartPoint = .zero
                    // If we never exceeded the threshold, let the event through
                    // so .onTapGesture on FrameSegmentView can handle it
                }
                return event

            case .flagsChanged:
                return event

            default:
                return event
            }
        }

        // Monitor for all key events globally (when timeline is visible but not key window)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return }

            if event.type == .keyDown {
                // Ignore timeline keyboard shortcuts while another app is frontmost.
                guard self.shouldHandleTimelineKeyboardShortcuts() else {
                    return
                }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let openLinkTrigger = self.openLinkShortcutTrigger(for: event, modifiers: modifiers)
                let copyLinkTrigger = self.copyLinkShortcutTrigger(for: event, modifiers: modifiers)
                let copyMomentLinkTrigger = self.copyMomentLinkShortcutTrigger(for: event, modifiers: modifiers)
                // Keep Option+C local to the timeline window; do not react globally.
                if self.addCommentShortcutTrigger(for: event, modifiers: modifiers) != nil {
                    return
                }
                if openLinkTrigger != nil || copyLinkTrigger != nil || copyMomentLinkTrigger != nil {
                    self.handleKeyEvent(event)
                    return
                }
                self.handleKeyEvent(event)
            } else if event.type == .scrollWheel {
                // Don't handle scroll events when search UI, filter dropdown, or tag submenu should own wheel input.
                if let viewModel = self.timelineViewModel,
                   (viewModel.searchViewModel.isRecentEntriesPopoverVisible ||
                    (viewModel.isSearchOverlayVisible &&
                     (viewModel.searchViewModel.isDropdownOpen || viewModel.searchViewModel.isSearchOverlayExpanded)) ||
                    viewModel.isFilterDropdownOpen ||
                    viewModel.showTagSubmenu) {
                    return // Let SwiftUI handle it
                }
                self.handleScrollEvent(event, source: "GLOBAL")
            } else if event.type == .magnify {
                self.handleMagnifyEvent(event)
            }
        }

        // Also monitor local events (when our window is key)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            if event.type == .keyDown {
                let isTextFieldActive: Bool = {
                    guard let window = self?.window,
                          let firstResponder = window.firstResponder else {
                        return false
                    }
                    return firstResponder is NSTextView || firstResponder is NSTextField
                }()

                // Always handle certain shortcuts even when text field is active
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let openLinkTrigger = self?.openLinkShortcutTrigger(for: event, modifiers: modifiers)
                let copyLinkTrigger = self?.copyLinkShortcutTrigger(for: event, modifiers: modifiers)
                let copyYouTubeMarkdownLinkTrigger = self?.copyYouTubeMarkdownLinkShortcutTrigger(for: event, modifiers: modifiers)
                let copyMomentLinkTrigger = self?.copyMomentLinkShortcutTrigger(for: event, modifiers: modifiers)
                if event.keyCode == 53 { // Escape
                    if self?.handleKeyEvent(event) == true {
                        return nil // Always consume when handled
                    }

                    return event
                }

                // Cmd+F toggles in-frame search even when the in-frame text field is focused.
                if event.keyCode == 3 && modifiers == [.command] { // Cmd+F
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+W dismisses the timeline even when a timeline text field is focused.
                if Self.shouldDismissTimelineWithCommandW(
                    keyCode: event.keyCode,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                    modifiers: modifiers
                ) {
                    if self?.handleKeyEvent(event) == true {
                        return nil
                    }
                    return event
                }

                // When in-frame search text field is focused, let AppKit own other key handling
                // (selection, clipboard, caret movement, etc.) so timeline shortcuts don't fire.
                let isInFrameSearchFieldActive: Bool = {
                    guard isTextFieldActive,
                          let viewModel = self?.timelineViewModel else {
                        return false
                    }
                    return viewModel.isInFrameSearchVisible
                }()
                if isInFrameSearchFieldActive {
                    if openLinkTrigger == nil
                        && copyLinkTrigger == nil
                        && copyYouTubeMarkdownLinkTrigger == nil {
                        return event
                    }
                }

                // Cmd+K to toggle search overlay
                if event.keyCode == 40 && modifiers == [.command] { // Cmd+K
                    if let viewModel = self?.timelineViewModel,
                       viewModel.showCommentSubmenu,
                       isTextFieldActive {
                        // Let the in-modal text editor own Cmd+K for link insertion.
                        return event
                    }
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Option+H to hide the segment at playhead
                if event.keyCode == 4 && modifiers == [.option] { // Option+H
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Add Tag submenu shortcut for segment at playhead (Cmd+T)
                if self?.addTagShortcutTrigger(for: event, modifiers: modifiers) != nil {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Option+F to quick-filter by the app at playhead
                if self?.quickAppFilterTrigger(for: event, modifiers: modifiers) != nil {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+Shift+F to toggle filter panel
                if event.keyCode == 3 && modifiers == [.command, .shift] { // Cmd+Shift+F
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+G to toggle date search
                if event.keyCode == 5 && modifiers == [.command] { // Cmd+G
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+=/+ to zoom in (handle before system can intercept)
                if (event.keyCode == 24 || event.keyCode == 69) && (modifiers == [.command] || modifiers == [.command, .shift]) {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+- to zoom out (handle before system can intercept)
                if (event.keyCode == 27 || event.keyCode == 78) && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+0 or Ctrl+0 to reset zoom (handle before system can intercept)
                if event.keyCode == 29 && (modifiers == [.command] || modifiers == [.control]) {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+A to select all (handle before system can intercept)
                // But let it pass through when a dialog with text input is active
                if event.keyCode == 0 && modifiers == [.command] {
                    if let viewModel = self?.timelineViewModel,
                       (viewModel.isSearchOverlayVisible ||
                        viewModel.isFilterPanelVisible ||
                        viewModel.isDateSearchActive ||
                        viewModel.showCommentSubmenu) {
                        return event // Let the text field handle Cmd+A
                    }
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+C to copy (handle before system can intercept)
                if event.charactersIgnoringModifiers == "c" && modifiers == [.command] {
                    // When editing text (e.g., filter fields), let AppKit handle Cmd+C.
                    if isTextFieldActive {
                        return event
                    }
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+S to save image (handle before system can intercept)
                if event.charactersIgnoringModifiers == "s" && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Link shortcuts (Cmd+L / Cmd+Shift+L / Option+Cmd+L / Option+Shift+L): handle before AppKit key-equivalent fallback.
                if openLinkTrigger != nil
                    || copyLinkTrigger != nil
                    || copyYouTubeMarkdownLinkTrigger != nil
                    || copyMomentLinkTrigger != nil {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume to avoid dead-end beep
                }

                // Cmd+; to toggle more options menu (handle before system can intercept)
                if event.charactersIgnoringModifiers == ";" && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+H to toggle controls visibility (handle before system can intercept)
                if event.keyCode == 4 && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+J to go to now (handle before system can intercept)
                if event.keyCode == 38 && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+P to toggle peek mode (handle before system can intercept)
                if event.keyCode == 35 && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // For other keys, let text field handle them if it's active
                if isTextFieldActive {
                    return event // Let the text field handle it
                }

                if self?.handleKeyEvent(event) == true {
                    return nil // Consume the event
                }
            } else if event.type == .scrollWheel {
                // Let UI overlays consume scrolling before timeline navigation.
                if let viewModel = self?.timelineViewModel {
                    // Comment overlay thread/composer are scrollable and should own wheel events.
                    if viewModel.showCommentSubmenu {
                        return event
                    }
                    // Filter-panel popovers are ScrollViews.
                    if viewModel.isFilterDropdownOpen {
                        return event
                    }
                    // Timeline context-menu tag submenu is also scrollable.
                    if viewModel.showTagSubmenu {
                        return event
                    }
                    // The recent-entry popover should own wheel events while open.
                    if viewModel.searchViewModel.isRecentEntriesPopoverVisible {
                        return event
                    }
                    // Expanded search overlay (and its dropdowns) should own wheel events.
                    if viewModel.isSearchOverlayVisible &&
                        (viewModel.searchViewModel.isDropdownOpen ||
                         viewModel.searchViewModel.isSearchOverlayExpanded) {
                        return event
                    }
                }
                self?.handleScrollEvent(event, source: "LOCAL")
                return nil // Consume scroll events
            } else if event.type == .magnify {
                self?.handleMagnifyEvent(event)
                return nil // Consume magnify events
            }
            return event
        }
    }

    private func removeEventMonitors() {
        // End any in-progress tape drag before removing monitors
        forceEndTapeDrag()

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard shouldHandleTimelineKeyboardShortcuts() else {
            return false
        }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let addTagTrigger = addTagShortcutTrigger(for: event, modifiers: modifiers)
        let addCommentTrigger = addCommentShortcutTrigger(for: event, modifiers: modifiers)
        let isAddTagShortcut = addTagTrigger != nil

        // Don't handle escape if a modal panel (save panel, etc.) is open
        if NSApp.modalWindow != nil {
            return false
        }

        // Don't handle escape if our window is not the key window (e.g., save panel is open)
        if let keyWindow = NSApp.keyWindow, keyWindow != window {
            // Option+C must remain timeline-local; don't steal focus for it.
            if isAddTagShortcut {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            } else {
                return false
            }
        }

        // Escape key - cascading behavior based on current state
        if event.keyCode == 53 { // Escape
            if let viewModel = timelineViewModel {
                // If the tag submenu is open, close only the submenu first and keep
                // the parent right-click menu visible.
                if viewModel.showTagSubmenu {
                    withAnimation(.easeOut(duration: 0.12)) {
                        viewModel.showTagSubmenu = false
                        viewModel.showNewTagInput = false
                        viewModel.newTagName = ""
                        viewModel.isHoveringAddTagButton = false
                    }
                    return true
                }
                // If the comment link popover is open, close it first.
                if viewModel.showCommentSubmenu && viewModel.isCommentLinkPopoverPresented {
                    viewModel.requestCloseCommentLinkPopover()
                    return true
                }
                // In all-comments browser mode, Escape should return to local thread comments
                // before dismissing the full comment submenu.
                if viewModel.showCommentSubmenu && viewModel.isAllCommentsBrowserActive {
                    viewModel.requestReturnToThreadComments()
                    return true
                }
                // Close comment submenu with its dedicated fade-out path.
                if viewModel.showCommentSubmenu {
                    viewModel.dismissCommentSubmenu()
                    return true
                }
                // Right-click menus should dismiss before any higher-level escape behavior.
                if viewModel.showTimelineContextMenu || viewModel.showContextMenu || viewModel.showCommentSubmenu {
                    withAnimation(.easeOut(duration: 0.12)) {
                        viewModel.dismissContextMenu()
                        viewModel.dismissTimelineContextMenu()
                    }
                    return true
                }
                // If currently dragging to create zoom region, cancel the drag
                if viewModel.isDraggingZoomRegion {
                    viewModel.cancelZoomRegionDrag()
                    return true
                }
                // If calendar picker is showing, close it first with animation
                if viewModel.isCalendarPickerVisible {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        viewModel.isCalendarPickerVisible = false
                        viewModel.hoursWithFrames = []
                        viewModel.selectedCalendarDate = nil
                        viewModel.calendarKeyboardFocus = .dateGrid
                        viewModel.selectedCalendarHour = nil
                    }
                    return true
                }
                // If zoom slider is expanded, collapse it
                if viewModel.isZoomSliderExpanded {
                    withAnimation(.easeOut(duration: 0.12)) {
                        viewModel.isZoomSliderExpanded = false
                    }
                    return true
                }
                // If date search is active, close it with animation
                if viewModel.isDateSearchActive {
                    viewModel.closeDateSearch()
                    return true
                }
                // If recent entries popover is open, hide it before dismissing search overlay.
                if viewModel.isSearchOverlayVisible && viewModel.searchViewModel.isRecentEntriesPopoverVisible {
                    viewModel.searchViewModel.requestDismissRecentEntriesPopoverByUser()
                    return true
                }
                // If search overlay is visible and a filter dropdown is open, close the dropdown first.
                if viewModel.isSearchOverlayVisible && viewModel.searchViewModel.isDropdownOpen {
                    // When date popover calendar is open, let the popover consume Escape first
                    // so it can collapse calendar before the entire dropdown is dismissed.
                    if viewModel.searchViewModel.isDatePopoverHandlingKeys {
                        return false
                    }
                    viewModel.searchViewModel.closeDropdownsSignal += 1
                    return true
                }
                // If search overlay is expanded with no submitted query/results payload,
                // collapse to compact mode and clear active filters instead of dismissing.
                if viewModel.isSearchOverlayVisible {
                    let searchViewModel = viewModel.searchViewModel
                    if searchViewModel.isSearchOverlayExpanded &&
                        !searchViewModel.shouldDismissExpandedOverlayOnEscape {
                        searchViewModel.clearAllFilters()
                        searchViewModel.resetSearchOrderToDefault()
                        searchViewModel.requestOverlayCollapse()
                        return true
                    }

                    // Otherwise keep existing behavior: dismiss the overlay.
                    searchViewModel.requestOverlayDismiss(clearSearchState: true)
                    return true
                }
                // If in-frame search is active, close it before falling through to timeline close.
                if viewModel.isInFrameSearchVisible || !viewModel.inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    viewModel.closeInFrameSearch(clearQuery: true)
                    return true
                }
                // If search highlight is showing, clear it and return to search results if available
                if viewModel.isShowingSearchHighlight {
                    viewModel.clearSearchHighlight()
                    // If there are search results to return to, reopen the search overlay
                    if viewModel.searchViewModel.results != nil && !viewModel.searchViewModel.searchQuery.isEmpty {
                        viewModel.isSearchOverlayVisible = true
                    }
                    return true
                }
                // If delete confirmation is showing, cancel it
                if viewModel.showDeleteConfirmation {
                    viewModel.cancelDelete()
                    return true
                }
                // If zoom region is active, exit zoom mode
                if viewModel.isZoomRegionActive {
                    viewModel.exitZoomRegion()
                    return true
                }
                // If text selection is active, clear it
                if viewModel.hasSelection {
                    viewModel.clearTextSelection()
                    return true
                }
                // If in peek mode, exit peek mode and return to filtered view
                if viewModel.isPeeking {
                    viewModel.exitPeek()
                    return true
                }
                // If filter panel is visible with an open dropdown, close dropdown first.
                // This avoids falling through to timeline close when a dropdown-level Escape
                // handler does not consume the event in time.
                if viewModel.isFilterPanelVisible && viewModel.isFilterDropdownOpen {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterDropdown()
                    }
                    return true
                }
                // If filter panel is visible (no dropdown), close it
                if viewModel.isFilterPanelVisible {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterPanel()
                    }
                    return true
                }
                // If filters are active (but panel is closed), clear them
                if viewModel.filterCriteria.hasActiveFilters {
                    viewModel.clearAllFilters()
                    return true
                }
            }
            // Otherwise close the timeline
            hide()
            return true
        }

        if Self.shouldDismissTimelineWithCommandW(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers
        ) {
            recordShortcut("cmd+w")
            hide()
            return true
        }

        // Check if it's the toggle shortcut (uses saved shortcut config)
        let shortcutConfig = loadTimelineShortcut()
        let expectedKeyCode = keyCodeForString(shortcutConfig.key)
        if event.keyCode == expectedKeyCode && modifiers == shortcutConfig.modifiers.nsModifiers {
            hide()
            return true
        }

        // Cmd+F to toggle in-frame search
        if event.keyCode == 3 && modifiers == [.command] { // F key with Command
            recordShortcut("cmd+f")
            if let viewModel = timelineViewModel {
                viewModel.toggleInFrameSearch()
            }
            return true
        }

        // Cmd+G to toggle date search panel ("Go to" date)
        if event.keyCode == 5 && modifiers == [.command] { // G key with Command
            recordShortcut("cmd+g")
            if let viewModel = timelineViewModel {
                viewModel.toggleDateSearch()
            }
            return true
        }

        // Cmd+K to toggle search overlay
        if event.keyCode == 40 && modifiers == [.command] { // K key with Command
            recordShortcut("cmd+k")
            if let viewModel = timelineViewModel {
                guard Self.shouldToggleSearchOverlayFromShortcut(isActivelyScrolling: viewModel.isActivelyScrolling) else {
                    Log.info("[TimelineShortcut] Cmd+K ignored while scroll is active", category: .ui)
                    return true
                }
                let wasVisible = viewModel.isSearchOverlayVisible
                Log.info(
                    "[TimelineShortcut] Cmd+K wasVisible=\(wasVisible) queryEmpty=\(viewModel.searchViewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                    category: .ui
                )
                if wasVisible {
                    viewModel.closeSearchOverlay()
                } else {
                    _ = Self.presentSearchOverlay(
                        on: viewModel,
                        coordinator: coordinator,
                        recentEntriesRevealDelay: 0.3
                    )
                }
            }
            return true
        }

        // Option+H to hide segment block at playhead
        if event.keyCode == 4 && modifiers == [.option] { // H key with Option
            recordShortcut("opt+h")
            hidePlayheadSegment(trigger: "Option+H")
            return true
        }

        // Add Tag submenu for segment block at playhead (Cmd+T)
        if let trigger = addTagTrigger {
            recordShortcut("cmd+t")
            openAddTagSubmenuAtPlayhead(trigger: trigger)
            return true
        }

        // Add Comment composer for segment block at playhead (Option+C)
        if addCommentTrigger != nil {
            recordShortcut("opt+c")
            openAddCommentComposerAtPlayhead(source: "keyboard_opt_c")
            return true
        }

        // Option+F to toggle app filter for the current playhead frame
        if let trigger = quickAppFilterTrigger(for: event, modifiers: modifiers) {
            togglePlayheadAppFilter(trigger: trigger)
            return true
        }

        // Cmd+Shift+F to toggle filter panel
        if event.keyCode == 3 && modifiers == [.command, .shift] { // F key with Command+Shift
            recordShortcut("cmd+shift+f")
            if let viewModel = timelineViewModel {
                if viewModel.isFilterPanelVisible {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterPanel()
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        viewModel.openFilterPanel()
                    }
                }
            }
            return true
        }

        // Delete or Backspace key to delete selected frame
        if (event.keyCode == 51 || event.keyCode == 117) && modifiers.isEmpty { // Backspace (51) or Delete (117)
            if let viewModel = timelineViewModel, viewModel.selectedFrameIndex != nil {
                viewModel.requestDeleteSelectedFrame()
                return true
            }
        }

        // Handle delete confirmation dialog keyboard shortcuts
        if let viewModel = timelineViewModel, viewModel.showDeleteConfirmation {
            // Enter/Return confirms deletion
            if event.keyCode == 36 || event.keyCode == 76 { // Return (36) or Enter (76)
                viewModel.confirmDeleteSelectedFrame()
                return true
            }
            // Escape cancels (handled above, but also catch it here for the dialog)
            if event.keyCode == 53 { // Escape
                viewModel.cancelDelete()
                return true
            }
        }

        // Cmd+A to select all text on the frame
        // Skip when a dialog with text input is active - let the text field handle it
        if event.keyCode == 0 && modifiers == [.command] { // A key with Command
            if let viewModel = timelineViewModel {
                // Don't intercept when dialogs with text inputs are open
                if viewModel.isSearchOverlayVisible ||
                    viewModel.isFilterPanelVisible ||
                    viewModel.isDateSearchActive ||
                    viewModel.showCommentSubmenu {
                    return false // Let the text field handle Cmd+A
                }
                recordShortcut("cmd+a")
                viewModel.selectAllText()
                return true
            }
        }

        // Cmd+C to copy selected text, otherwise copy the active image context.
        if event.charactersIgnoringModifiers == "c" && modifiers == [.command] {
            recordShortcut("cmd+c")
            if let viewModel = timelineViewModel {
                if viewModel.hasSelection {
                    viewModel.copySelectedText()
                } else if viewModel.isZoomRegionActive {
                    viewModel.copyZoomedRegionImage()
                } else {
                    copyCurrentFrameImage()
                }
                return true
            }
        }

        // Cmd+S to save image
        if event.charactersIgnoringModifiers == "s" && modifiers == [.command] {
            recordShortcut("cmd+s")
            saveCurrentFrameImage()
            return true
        }

        // Cmd+Shift+L to open current browser link
        if openLinkShortcutTrigger(for: event, modifiers: modifiers) != nil {
            recordShortcut("cmd+shift+l")
            if timelineViewModel?.openCurrentBrowserURL() == true {
                hide(restorePreviousFocus: false)
                return true
            }
            return false
        }

        // Cmd+L to copy current browser URL
        if copyLinkShortcutTrigger(for: event, modifiers: modifiers) != nil {
            recordShortcut("cmd+l")
            if let viewModel = timelineViewModel, viewModel.copyCurrentBrowserURL() {
                return true
            }
            return true
        }

        // Option+Cmd+L to copy YouTube markdown link
        if copyYouTubeMarkdownLinkShortcutTrigger(for: event, modifiers: modifiers) != nil {
            recordShortcut("opt+cmd+l")
            if let viewModel = timelineViewModel, viewModel.copyCurrentYouTubeMarkdownLink() {
                return true
            }
            return true
        }

        // Option+Shift+L to copy moment link
        if copyMomentLinkShortcutTrigger(for: event, modifiers: modifiers) != nil {
            recordShortcut("opt+shift+l")
            _ = copyMomentLink()
            return true
        }

        // Cmd+; to toggle more options menu
        if event.charactersIgnoringModifiers == ";" && modifiers == [.command] {
            recordShortcut("cmd+;")
            if let viewModel = timelineViewModel {
                viewModel.toggleMoreOptionsMenu()
                return true
            }
            return false
        }

        // Cmd+H to toggle timeline controls visibility
        if event.keyCode == 4 && modifiers == [.command] { // H key with Command
            recordShortcut("cmd+h")
            if let viewModel = timelineViewModel {
                viewModel.toggleControlsVisibility(showRestoreHint: true)
                return true
            }
        }

        // Cmd+P to toggle peek mode (view full context while filtered)
        if event.keyCode == 35 && modifiers == [.command] { // P key with Command
            recordShortcut("cmd+p")
            if let viewModel = timelineViewModel {
                // Only allow peek if we have active filters or are already peeking
                if viewModel.filterCriteria.hasActiveFilters || viewModel.isPeeking {
                    viewModel.togglePeek()
                    return true
                }
            }
        }

        // Cmd+J to go to now (most recent frame)
        if event.keyCode == 38 && modifiers == [.command] { // J key with Command
            recordShortcut("cmd+j")
            if let viewModel = timelineViewModel {
                viewModel.goToNow()
                return true
            }
        }

        // Cmd+Z to undo (go back to last stopped playhead position)
        if event.keyCode == 6 && modifiers == [.command] { // Z key with Command
            if let viewModel = timelineViewModel {
                if viewModel.undoToLastStoppedPosition() {
                    recordShortcut("cmd+z")
                    return true
                }
            }
            // Don't consume the event if there's nothing to undo
            return false
        }

        // Cmd+Shift+Z to redo (go forward to last undone playhead position)
        if event.keyCode == 6 && modifiers == [.command, .shift] { // Z key with Command+Shift
            if let viewModel = timelineViewModel {
                if viewModel.redoLastUndonePosition() {
                    recordShortcut("cmd+shift+z")
                    return true
                }
            }
            // Don't consume the event if there's nothing to redo
            return false
        }

        // Space bar to toggle play/pause (only when video controls are enabled)
        if event.keyCode == 49 && modifiers.isEmpty { // Space
            if let viewModel = timelineViewModel, viewModel.showVideoControls {
                viewModel.togglePlayback()
                return true
            }
        }

        // Shift+> to increase playback speed (only when video controls are enabled)
        if event.characters == ">" {
            if let viewModel = timelineViewModel, viewModel.showVideoControls {
                let speeds: [Double] = [1, 2, 4, 8]
                if let currentIdx = speeds.firstIndex(of: viewModel.playbackSpeed), currentIdx < speeds.count - 1 {
                    let newSpeed = speeds[currentIdx + 1]
                    viewModel.setPlaybackSpeed(newSpeed)
                    viewModel.showToast("Speed: \(Int(newSpeed))x")
                }
                return true
            }
        }

        // Shift+< to decrease playback speed (only when video controls are enabled)
        if event.characters == "<" {
            if let viewModel = timelineViewModel, viewModel.showVideoControls {
                let speeds: [Double] = [1, 2, 4, 8]
                if let currentIdx = speeds.firstIndex(of: viewModel.playbackSpeed), currentIdx > 0 {
                    let newSpeed = speeds[currentIdx - 1]
                    viewModel.setPlaybackSpeed(newSpeed)
                    viewModel.showToast("Speed: \(Int(newSpeed))x")
                }
                return true
            }
        }

        // Calendar picker keyboard navigation should consume arrow/enter keys
        // while the picker is visible so timeline scrubbing does not trigger.
        if let viewModel = timelineViewModel,
           viewModel.isCalendarPickerVisible,
           modifiers.isEmpty {
            if event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126 {
                return viewModel.handleCalendarPickerArrowKey(event.keyCode)
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return or Enter
                return viewModel.handleCalendarPickerEnterKey()
            }
        }

        // While the filter panel is open, let the panel own arrow-key navigation.
        // This prevents left/right from scrubbing the timeline behind the panel.
        if let viewModel = timelineViewModel,
           viewModel.isFilterPanelVisible,
           modifiers.isEmpty,
           (event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126) {
            return false
        }

        // Left arrow, J, or L - navigate to previous frame (Option = 3x speed)
        // Skip when search UI is open so overlay controls can own arrow keys.
        if let viewModel = timelineViewModel,
           viewModel.isSearchOverlayVisible,
           !viewModel.searchViewModel.searchQuery.isEmpty,
           (event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126) {
            return false
        }
        // Skip when a search filter dropdown is open (e.g., DateFilterPopover uses arrow keys for calendar navigation)
        if let viewModel = timelineViewModel, viewModel.searchViewModel.isDropdownOpen, (event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126) {
            return false
        }
        // Cmd+Left: jump to the start of the previous consecutive timeline block
        if event.keyCode == 123 && modifiers == [.command] {
            if let viewModel = timelineViewModel, viewModel.navigateToPreviousBlockStart() {
                recordShortcut("cmd+left")
                if let coordinator = coordinator {
                    DashboardViewModel.recordArrowKeyNavigation(coordinator: coordinator, direction: "left")
                }
            }
            return true // Consume even at boundary to avoid system "bonk" sound
        }

        if Self.shouldNavigateTimelineBackward(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers
        ) {
            if let viewModel = timelineViewModel {
                let step = modifiers.contains(.option) ? 3 : 1
                viewModel.navigateToFrame(viewModel.currentIndex - step)
                // Record arrow key navigation metric
                if let coordinator = coordinator {
                    DashboardViewModel.recordArrowKeyNavigation(coordinator: coordinator, direction: "left")
                }
            }
            return true // Always consume to prevent system "bonk" sound
        }

        // Right arrow, K, or ; - navigate to next frame (Option = 3x speed)
        // Cmd+Right: jump to the start of the next consecutive timeline block
        if event.keyCode == 124 && modifiers == [.command] {
            if let viewModel = timelineViewModel, viewModel.navigateToNextBlockStartOrNewestFrame() {
                recordShortcut("cmd+right")
                if let coordinator = coordinator {
                    DashboardViewModel.recordArrowKeyNavigation(coordinator: coordinator, direction: "right")
                }
            }
            return true // Consume even at boundary to avoid system "bonk" sound
        }

        if Self.shouldNavigateTimelineForward(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers
        ) {
            if let viewModel = timelineViewModel {
                let step = modifiers.contains(.option) ? 3 : 1
                viewModel.navigateToFrame(viewModel.currentIndex + step)
                // Record arrow key navigation metric
                if let coordinator = coordinator {
                    DashboardViewModel.recordArrowKeyNavigation(coordinator: coordinator, direction: "right")
                }
            }
            return true // Always consume to prevent system "bonk" sound
        }

        // Ctrl+0 to reset frame zoom to 100%
        if event.keyCode == 29 && modifiers == [.control] { // 0 key with Control
            recordShortcut("ctrl+0")
            if let viewModel = timelineViewModel, viewModel.isFrameZoomed {
                viewModel.resetFrameZoom()
                return true
            }
        }

        // Cmd+0 to reset frame zoom to 100% (alternative shortcut)
        if event.keyCode == 29 && modifiers == [.command] { // 0 key with Command
            recordShortcut("cmd+0")
            if let viewModel = timelineViewModel, viewModel.isFrameZoomed {
                viewModel.resetFrameZoom()
                return true
            }
        }

        // Cmd++ (Cmd+=) to zoom in frame
        // Key code 24 is '=' which is '+' with shift, but Cmd+= works as zoom in
        if (event.keyCode == 24 || event.keyCode == 69) && (modifiers == [.command] || modifiers == [.command, .shift]) {
            recordShortcut("cmd++")
            if let viewModel = timelineViewModel {
                viewModel.applyMagnification(1.25, animated: true) // Zoom in by 25%
                return true
            }
        }

        // Cmd+- to zoom out frame
        if (event.keyCode == 27 || event.keyCode == 78) && modifiers == [.command] { // - key (main or numpad)
            recordShortcut("cmd+-")
            if let viewModel = timelineViewModel {
                viewModel.applyMagnification(0.8, animated: true) // Zoom out by 20%
                return true
            }
        }

        // TEMP: Debug shortcuts for testing detach/reattach fix (uncomment to use)
        // #if DEBUG
        // // Option+1 — Detach hosting view + refresh data in background (simulates real hide scenario)
        // if event.keyCode == 18 && modifiers == [.option] { // 1
        //     if let hostingView = hostingView, hostingView.superview != nil {
        //         hostingView.removeFromSuperview()
        //         Log.info("[DEV-TEST] ⚡ Detached hosting view, now refreshing data while detached...", category: .ui)
        //         Task { @MainActor in
        //             await self.timelineViewModel?.refreshFrameData(navigateToNewest: true)
        //             Log.info("[DEV-TEST] ⚡ Data refreshed while detached. frames=\(self.timelineViewModel?.frames.count ?? 0)", category: .ui)
        //         }
        //     }
        //     return true
        // }
        // // Option+2 — Reattach hosting view WITHOUT objectWillChange (should show stale tape)
        // if event.keyCode == 19 && modifiers == [.option] { // 2
        //     if let hostingView = hostingView, hostingView.superview == nil, let window = window {
        //         hostingView.frame = window.contentView?.bounds ?? .zero
        //         window.contentView?.addSubview(hostingView)
        //         hostingView.layoutSubtreeIfNeeded()
        //         Log.info("[DEV-TEST] ⚡ Reattached hosting view (WITHOUT objectWillChange)", category: .ui)
        //     }
        //     return true
        // }
        // // Option+3 — Send objectWillChange (should fix stale tape)
        // if event.keyCode == 20 && modifiers == [.option] { // 3
        //     return true
        // }
        // #endif

        // Any other key (not a modifier) clears text selection
        if let viewModel = timelineViewModel,
           viewModel.hasSelection,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control),
           event.keyCode != 53 { // Don't clear on Escape (handled above)
            // Only clear for non-navigation keys
            let navigationKeys: Set<UInt16> = [123, 124, 125, 126, 37, 38, 40, 41, 49] // Arrow keys + J, K, L, ; + Space
            if !navigationKeys.contains(event.keyCode) {
                viewModel.clearTextSelection()
            }
        }

        return false
    }

    /// Check if a window-coordinate point is within the timeline tape area
    private func isPointInTapeArea(_ pointInWindow: CGPoint) -> Bool {
        guard let viewModel = timelineViewModel else { return false }

        // Don't allow tape dragging when controls are hidden or tape is hidden
        guard !viewModel.areControlsHidden && !viewModel.isTapeHidden else { return false }

        // In NSWindow coordinates, Y=0 is at the BOTTOM
        // The tape is positioned at the bottom with .padding(.bottom, tapeBottomPadding)
        let tapeHeight = TimelineScaleFactor.tapeHeight           // 42 * scale
        let tapeBottomPadding = TimelineScaleFactor.tapeBottomPadding  // 40 * scale

        let tapeBottomY = tapeBottomPadding
        let tapeTopY = tapeBottomPadding + tapeHeight

        // Add generous padding for easier grabbing
        let hitPadding: CGFloat = 10 * TimelineScaleFactor.current
        let hitBottom = max(0, tapeBottomY - hitPadding)
        let hitTop = tapeTopY + hitPadding

        return pointInWindow.y >= hitBottom && pointInWindow.y <= hitTop
    }

    /// Hit region near playback controls.
    /// Derived from the same layout metrics as TimelineTapeView to avoid tap-vs-drag conflicts.
    private func isPointNearPlaybackControls(_ pointInWindow: CGPoint) -> Bool {
        guard let viewModel = timelineViewModel,
              viewModel.showVideoControls,
              !viewModel.areControlsHidden,
              !viewModel.isTapeHidden,
              let window = window else {
            return false
        }

        let scale = TimelineScaleFactor.current
        let controlButtonSize = TimelineScaleFactor.controlButtonSize
        let controlSpacing = TimelineScaleFactor.controlSpacing
        let centerX = window.contentView?.bounds.midX ?? window.frame.width / 2
        let controlsCenterY = TimelineScaleFactor.tapeBottomPadding + TimelineScaleFactor.tapeHeight + TimelineScaleFactor.controlsYOffset

        // Keep this in sync with TimelineTapeView.playhead:
        // middleSideControlsWidth = controlButtonSize * 2 + 6 + 8 + (controlButtonSize + controlSpacing)
        let middleSideControlsWidth = (controlButtonSize * 3) + controlSpacing + 14
        let datetimeWidth = estimatedDatetimeControlWidth(for: viewModel, scale: scale)
        let rightControlsLeadingX = centerX + (datetimeWidth / 2) + controlSpacing

        // Cover both "Go to now/refresh" and play button targets.
        let horizontalPadding = 16 * scale
        let minX = rightControlsLeadingX - horizontalPadding
        let maxX = rightControlsLeadingX + middleSideControlsWidth + horizontalPadding

        // Include slight overlap with tape hit area to catch low-edge play clicks.
        let verticalPadding = 18 * scale
        let minY = controlsCenterY - (controlButtonSize / 2) - verticalPadding
        let maxY = controlsCenterY + (controlButtonSize / 2) + verticalPadding

        return pointInWindow.x >= minX &&
            pointInWindow.x <= maxX &&
            pointInWindow.y >= minY &&
            pointInWindow.y <= maxY
    }

    /// Estimate the runtime width of the datetime control so click hit-testing matches localized labels.
    private func estimatedDatetimeControlWidth(for viewModel: SimpleTimelineViewModel, scale: CGFloat) -> CGFloat {
        let dateFont = NSFont.systemFont(ofSize: TimelineScaleFactor.fontCaption, weight: .medium)
        let timeFont = NSFont.monospacedSystemFont(ofSize: TimelineScaleFactor.fontMono, weight: .regular)
        let chevronFont = NSFont.systemFont(ofSize: TimelineScaleFactor.fontTiny, weight: .bold)

        let dateWidth = (viewModel.currentDateString as NSString).size(withAttributes: [.font: dateFont]).width
        let timeWidth = (viewModel.currentTimeString as NSString).size(withAttributes: [.font: timeFont]).width
        let chevronWidth = ("▾" as NSString).size(withAttributes: [.font: chevronFont]).width

        // Match DatetimeButton horizontal spacing/padding.
        let contentWidth = dateWidth +
            TimelineScaleFactor.iconSpacing +
            timeWidth +
            TimelineScaleFactor.iconSpacing +
            chevronWidth
        let paddedWidth = contentWidth + (TimelineScaleFactor.paddingH * 2)

        // Clamp to avoid pathological under/over-estimation.
        let minWidth = 120 * scale
        let maxWidth = 480 * scale
        return min(maxWidth, max(minWidth, ceil(paddedWidth)))
    }

    /// Force-end any in-progress tape drag (e.g., on window focus loss)
    private func forceEndTapeDrag() {
        guard isTapeDragging else { return }
        let wasDragging = tapeDragDidExceedThreshold
        isTapeDragging = false
        tapeDragDidExceedThreshold = false
        tapeDragVelocitySamples.removeAll()
        tapeDragStartedNearPlaybackControls = false
        tapeDragStartPoint = .zero

        if wasDragging {
            NSCursor.pop()
            if let viewModel = timelineViewModel {
                Task { @MainActor in
                    viewModel.endTapeDrag(withVelocity: 0)
                }
            }
        }
    }

    private func handleScrollEvent(_ event: NSEvent, source: String) {
        guard isVisible, let viewModel = timelineViewModel else { return }

        // Dedicated overlays own wheel gestures while visible.
        if viewModel.showCommentSubmenu {
            return
        }

        if viewModel.isInLiveMode, CFAbsoluteTimeGetCurrent() < suppressLiveScrollUntil {
            return
        }

        let orientationRaw = Self.timelineSettingsStore.string(forKey: "timelineScrollOrientation") ?? "horizontal"
        let orientation = TimelineScrollOrientation(rawValue: orientationRaw) ?? .horizontal
        let delta: Double
        switch orientation {
        case .horizontal:
            // Default behavior: left/right swipes move timeline.
            delta = -event.scrollingDeltaX
        case .vertical:
            // Optional behavior: up/down swipes move timeline.
            delta = -event.scrollingDeltaY
        }

        // --- Scroll orientation mismatch detection ---
        if !hasShownScrollOrientationHint {
            let wrongAxisMag = abs(orientation == .horizontal ? event.scrollingDeltaY : event.scrollingDeltaX)
            let rightAxisMag = abs(orientation == .horizontal ? event.scrollingDeltaX : event.scrollingDeltaY)

            let now = CFAbsoluteTimeGetCurrent()
            if now - scrollAccumStartTime > 2.0 {
                wrongAxisScrollAccum = 0
                rightAxisScrollAccum = 0
                scrollAccumStartTime = now
            }
            wrongAxisScrollAccum += wrongAxisMag
            rightAxisScrollAccum += rightAxisMag

            if wrongAxisScrollAccum > 500,
               rightAxisScrollAccum < 5 || wrongAxisScrollAccum > 5 * rightAxisScrollAccum {
                hasShownScrollOrientationHint = true
                viewModel.showScrollOrientationHint(current: orientation.rawValue)
            }
        }

        // Trackpads have precise scrolling deltas, mice do not
        let isTrackpad = event.hasPreciseScrollingDeltas

        if abs(delta) > 0.001 {
            // Cancel any tape drag momentum on real scroll input
            viewModel.cancelTapeDragMomentum()

            onScroll?(delta)
            // Forward scroll to view model
            Task { @MainActor in
                await viewModel.handleScroll(delta: CGFloat(delta), isTrackpad: isTrackpad)
            }
        }
    }

    private func handleMagnifyEvent(_ event: NSEvent) {
        guard isVisible, let viewModel = timelineViewModel, let window = window else { return }

        // Don't handle magnify when zoom region or search overlay is active
        if viewModel.isZoomRegionActive || viewModel.isSearchOverlayVisible {
            return
        }

        // magnification is the delta from the last event (can be positive or negative)
        // Convert to a scale factor: 1.0 + magnification
        let magnification = event.magnification
        let scaleFactor = 1.0 + magnification

        // Get mouse location in window coordinates and convert to normalized anchor point
        let mouseLocation = event.locationInWindow
        let windowSize = window.frame.size

        // Convert to normalized coordinates (0-1 range, with 0.5,0.5 being center)
        // Note: macOS window coordinates have Y=0 at bottom, so we flip Y
        let normalizedX = mouseLocation.x / windowSize.width
        let normalizedY = 1.0 - (mouseLocation.y / windowSize.height)
        let anchor = CGPoint(x: normalizedX, y: normalizedY)

        // Apply the magnification with anchor point
        viewModel.applyMagnification(scaleFactor, anchor: anchor, frameSize: windowSize)
    }

    // MARK: - Key Code Mapping

    private func keyCodeForString(_ key: String) -> UInt16 {
        switch key.lowercased() {
        case "space": return 49
        case "return", "enter": return 36
        case "tab": return 48
        case "escape", "esc": return 53
        case "delete", "backspace": return 51
        case "left", "leftarrow", "←": return 123
        case "right", "rightarrow", "→": return 124
        case "down", "downarrow", "↓": return 125
        case "up", "uparrow", "↑": return 126

        // Letters
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6

        // Numbers
        case "0": return 29
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25

        default: return 0
        }
    }

    // MARK: - Scrub Distance Tracking

    /// Accumulate scrub distance for the current session
    public func accumulateScrubDistance(_ distance: Double) {
        sessionScrubDistance += distance
    }

    // MARK: - Keyboard Shortcut Tracking

    /// Record keyboard shortcut usage
    // MARK: - Image & Link Actions (Keyboard Shortcuts)

    private func copyCurrentFrameImage() {
        guard let viewModel = timelineViewModel else { return }
        viewModel.copyCurrentFrameImageToClipboard()
    }

    private func saveCurrentFrameImage() {
        guard let viewModel = timelineViewModel else { return }
        getCurrentFrameImage(viewModel: viewModel) { [weak self] image in
            guard let image = image else { return }

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.png]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let timestamp = formatter.string(from: viewModel.currentTimestamp ?? Date())
            savePanel.nameFieldStringValue = "retrace-\(timestamp).png"
            savePanel.level = .screenSaver + 1

            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        try? pngData.write(to: url)
                        if let coordinator = self?.coordinator {
                            DashboardViewModel.recordImageSave(coordinator: coordinator, frameID: viewModel.currentFrame?.id.value)
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    private func copyMomentLink() -> Bool {
        guard let viewModel = timelineViewModel,
              !viewModel.isInLiveMode,
              let timestamp = viewModel.currentTimestamp,
              let url = DeeplinkHandler.generateTimelineLink(timestamp: timestamp) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        viewModel.showToast("Moment Link copied")
        if let coordinator = coordinator {
            DashboardViewModel.recordDeeplinkCopy(coordinator: coordinator, url: url.absoluteString)
        }
        return true
    }

    private func getCurrentFrameImage(viewModel: SimpleTimelineViewModel, completion: @escaping (NSImage?) -> Void) {
        if viewModel.isInLiveMode {
            completion(viewModel.liveScreenshot)
            return
        }

        if let image = viewModel.currentImage {
            completion(image)
            return
        }

        guard let videoInfo = viewModel.currentVideoInfo else {
            completion(nil)
            return
        }

        var actualVideoPath = videoInfo.videoPath
        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                completion(nil)
                return
            }
        }

        guard let url = MP4SymlinkResolver.resolveURL(for: actualVideoPath) else {
            completion(nil)
            return
        }

        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        let time = videoInfo.frameTimeCMTime

        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            DispatchQueue.main.async {
                if let cgImage = cgImage {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    completion(nsImage)
                } else {
                    completion(nil)
                }
            }
        }
    }

    private func recordShortcut(_ shortcut: String) {
        if let coordinator = coordinator {
            DashboardViewModel.recordKeyboardShortcut(coordinator: coordinator, shortcut: shortcut)
        }
    }

    private func formattedPoint(_ point: CGPoint) -> String {
        "(\(Int(point.x)),\(Int(point.y)))"
    }

    // MARK: - Session Metrics

    /// Force-record active session metrics without blocking the main actor.
    /// Returns true when metrics were flushed before timeout, false otherwise.
    public func forceRecordSessionMetrics(timeoutMs: UInt64 = 350) async -> Bool {
        guard let startTime = sessionStartTime, let coordinator = coordinator else { return true }

        let durationMs = Int64(Date().timeIntervalSince(startTime) * 1000)
        let scrubDistance = sessionScrubDistance > 0 ? Int(sessionScrubDistance) : nil

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await coordinator.recordMetricEvent(metricType: .timelineSessionDuration, metadata: "\(durationMs)")
                    if let scrubDistance {
                        try await coordinator.recordMetricEvent(metricType: .scrubDistance, metadata: "\(scrubDistance)")
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .nanoseconds(Int64(timeoutMs * 1_000_000)), clock: .continuous)
                    throw SessionMetricFlushTimeout()
                }

                _ = try await group.next()
                group.cancelAll()
            }

            Log.info("[TIMELINE] Session metrics flush completed during termination", category: .ui)
            return true
        } catch is SessionMetricFlushTimeout {
            Log.warning("[TIMELINE] Session metrics flush timed out after \(timeoutMs)ms during termination", category: .ui)
            return false
        } catch {
            Log.warning("[TIMELINE] Session metrics flush failed during termination: \(error)", category: .ui)
            return false
        }
    }
}

private struct SessionMetricFlushTimeout: Error {}

// MARK: - Notifications

extension Notification.Name {
    static let timelineDidOpen = Notification.Name("timelineDidOpen")
    static let timelineDidClose = Notification.Name("timelineDidClose")
    static let navigateTimelineToDate = Notification.Name("navigateTimelineToDate")
}

// MARK: - Custom Window for Text Input Support

/// Custom NSWindow subclass that can become key window even when borderless
/// This is required for text fields to receive keyboard input properly
class KeyableWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, modifiers.isEmpty, event.keyCode == 53 {
            onEscape?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape {
            onEscape()
            return
        }

        super.cancelOperation(sender)
    }
}

/// Custom hosting view that accepts first mouse to enable hover on first interaction
class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - String Extension for Debug Logging
extension String {
    func appendToFile(at path: String) throws {
        if let data = self.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let fileHandle = FileHandle(forWritingAtPath: path) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try self.write(toFile: path, atomically: false, encoding: .utf8)
            }
        }
    }
}
