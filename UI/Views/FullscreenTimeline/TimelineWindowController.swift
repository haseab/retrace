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

    static let accessibilityPermissionRevokedNotification = Notification.Name("AccessibilityPermissionRevoked")

    // MARK: - Singleton

    public static let shared = TimelineWindowController()

    private override init() {
        super.init()
        setupEmergencyTapPermissionObservers()
        setupEmergencyEscapeTap()
    }

    // MARK: - Session Duration Tracking

    /// Tracks when the timeline was opened for duration tracking
    var sessionStartTime: Date?
    var sessionScrubDistance: Double = 0

    // MARK: - Properties

    var window: NSWindow?
    var coordinator: AppCoordinator?
    var coordinatorWrapper: AppCoordinatorWrapper?
    var eventMonitor: Any?
    var localEventMonitor: Any?
    var mouseEventMonitor: Any?  // Debug monitor for shift-drag investigation
    var timelineViewModel: SimpleTimelineViewModel?
    var pendingTimelineViewModelWaiters: [CheckedContinuation<SimpleTimelineViewModel, Never>] = []
    var hostingView: NSView?
    var deferredHostingViewDetachTask: Task<Void, Never>?
    var tapeShowAnimationTask: Task<Void, Never>?
    var liveModeCaptureTask: Task<Void, Never>?
    var windowFadeInTask: Task<Void, Never>?
    var deferredSearchOverlayRestoreTask: Task<Void, Never>?
    var shouldRestoreSearchOverlayAfterNextShow = false
    var windowFadeInGeneration: UInt64 = 0
    var workspaceActivationObserver: Any?
    let hideCompletionCoordinator = HideCompletionCoordinator()
    var isHiding = false
    var presentationState: PresentationState = .hidden
    /// Ignore scroll-wheel input for a short grace period after opening in live mode.
    /// This prevents residual trackpad momentum from immediately exiting live mode.
    var suppressLiveScrollUntil: CFAbsoluteTime = 0

    // MARK: - Emergency Escape (CGEvent tap for when main thread is blocked)

    /// CGEvent tap for emergency escape - runs on a dedicated background thread
    /// This allows closing the timeline even when the main thread is frozen
    struct EmergencyTapState {
        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var runLoop: CFRunLoop?
        var tapThread: Thread?
        var isInstallingTap = false
        var setupToken: UInt64 = 0
        var isTimelineVisible = false
    }

    nonisolated(unsafe) static var emergencyTapState = EmergencyTapState()
    nonisolated(unsafe) static var emergencyTapStateLock = NSLock()

    /// Whether a prepared headless timeline state exists and is ready to mount on demand.
    var isPrepared = false

    /// When the timeline was last hidden (for cache expiry check)
    var lastHiddenAt: Date?

    /// Whether the timeline overlay is currently visible
    public var isVisible: Bool {
        presentationState.isVisibleToClients
    }

    /// Shared hidden-state cache expiry used by timeline and search-state invalidation.
    nonisolated static let hiddenStateCacheExpirationSeconds: TimeInterval = 60
    /// Show the Cmd+Z recovery hint only for a short window after cache expiry actually snaps away from history.
    nonisolated static let positionRecoveryHintGracePeriodSeconds: TimeInterval = 60
    /// Reopen policy: when playhead is within this many latest loaded frames, open in live mode immediately.
    /// This only applies when the newest loaded frame is still recent.
    static let instantLiveReopenFrameThreshold: Int = 3
    /// Reopen policy: hidden duration required before instant near-edge positions auto-advance to newest.
    static let instantLiveReopenExpirationSeconds: TimeInterval = 2
    /// Reopen policy: if playhead is this close (< threshold) to latest frame, allow auto-advance after expiry.
    /// This only applies when the newest loaded frame is still recent.
    static let nearLiveReopenFrameThreshold: Int = 50
    /// Reopen policy: hidden duration required before near-live positions auto-advance to newest.
    static let nearLiveReopenExpirationSeconds: TimeInterval = 10
    /// Delay before detaching hosting view after hide to keep rapid reopen seamless.
    static let hostingViewDetachDelay: Duration = .milliseconds(350)
    /// Delay preserved spotlight overlay reopen until after live-mode presentation settles.
    static let liveSearchOverlayRestoreDelayMs = 180
    /// Small delay after the historical fade completes so the search pops after the reveal.
    static let historicalSearchOverlayRestoreDelayMs = 80

    /// Monotonic counter for deeplink search invocations (debug tracing).
    var deeplinkSearchInvocationCounter = 0

    /// Whether the dashboard was the key window when timeline opened
    var dashboardWasKeyWindow = false

    /// Whether the timeline is hiding to show dashboard/settings (don't auto-hide dashboard in this case)
    var isHidingToShowDashboard = false

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
    var focusRestoreTarget: FocusRestoreTarget?

    /// Callback when timeline closes
    public var onClose: (() -> Void)?

    /// Callback for scroll events (delta value)
    public var onScroll: ((Double) -> Void)?

    // MARK: - Tape Click-Drag State

    /// Whether the user is currently click-dragging the timeline tape
    var isTapeDragging = false

    /// The last mouse X position during a tape drag (in window coordinates)
    var tapeDragLastX: CGFloat = 0

    /// The mouse X position where the tape drag started (for minimum distance threshold)
    var tapeDragStartX: CGFloat = 0

    /// The full mouse position where the tape drag started (for click diagnostics)
    var tapeDragStartPoint: CGPoint = .zero

    /// Whether drag has passed the minimum distance threshold to be considered a drag (vs a click)
    var tapeDragDidExceedThreshold = false

    /// Whether the current drag candidate started near the playback controls area
    var tapeDragStartedNearPlaybackControls = false

    /// Minimum pixel distance before a mouseDown+mouseDragged is treated as a drag (not a tap)
    static let tapeDragMinDistance: CGFloat = 3.0

    /// Recent drag samples for velocity calculation (timestamp, deltaX)
    var tapeDragVelocitySamples: [(time: CFAbsoluteTime, delta: CGFloat)] = []

    /// Maximum age of velocity samples to consider (seconds)
    static let velocitySampleWindow: CFAbsoluteTime = 0.08
    /// Live-mode scroll suppression window (seconds) applied on open.
    static let liveScrollSuppressDuration: CFAbsoluteTime = 0.30
    static let timelineSettingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard

    /// Accumulated wrong-axis and right-axis scroll magnitudes for orientation mismatch detection
    var wrongAxisScrollAccum: CGFloat = 0
    var rightAxisScrollAccum: CGFloat = 0
    /// Timestamp when accumulation started
    var scrollAccumStartTime: CFAbsoluteTime = 0
    /// Whether the orientation hint has already been shown this session (don't repeat)
    var hasShownScrollOrientationHint: Bool = false

    enum TimelineScrollOrientation: String {
        case horizontal
        case vertical
    }

    enum PresentationState: String {
        case hidden
        case showing
        case visible
        case hiding

        var isVisibleToClients: Bool {
            switch self {
            case .hidden:
                return false
            case .showing, .visible, .hiding:
                return true
            }
        }
    }

    enum ToggleAction: Equatable {
        case show
        case hide
    }

    enum SearchOverlayShortcutAction: Equatable {
        case open
        case focusField
        case close
    }

    enum SearchResultNavigationDirection: Equatable {
        case previous
        case next
    }

    struct VisibilitySnapshot {
        let windowExists: Bool
        let windowVisible: Bool
        let windowMiniaturized: Bool
        let windowAlphaValue: CGFloat
        let appHidden: Bool

        var isActuallyVisible: Bool {
            TimelineWindowController.isActuallyVisible(
                windowExists: windowExists,
                windowVisible: windowVisible,
                windowMiniaturized: windowMiniaturized,
                windowAlphaValue: windowAlphaValue,
                appHidden: appHidden
            )
        }
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

    nonisolated static func shouldDismissTimelineForActivatedApplication(
        isTimelineVisible: Bool,
        activatedProcessID: pid_t?,
        currentProcessID: pid_t
    ) -> Bool {
        guard isTimelineVisible, let activatedProcessID else { return false }
        return activatedProcessID != currentProcessID
    }

    nonisolated static func shouldShowPositionRecoveryHintOnReopen(
        hiddenElapsedSeconds: TimeInterval,
        didSnapToNewest: Bool
    ) -> Bool {
        guard didSnapToNewest, hiddenElapsedSeconds.isFinite else { return false }
        guard hiddenElapsedSeconds > hiddenStateCacheExpirationSeconds else { return false }
        return hiddenElapsedSeconds <= hiddenStateCacheExpirationSeconds + positionRecoveryHintGracePeriodSeconds
    }

    nonisolated static func isActuallyVisible(
        windowExists: Bool,
        windowVisible: Bool,
        windowMiniaturized: Bool,
        windowAlphaValue: CGFloat,
        appHidden: Bool
    ) -> Bool {
        windowExists &&
            windowVisible &&
            !windowMiniaturized &&
            windowAlphaValue > 0.01 &&
            !appHidden
    }

    nonisolated static func reconciledPresentationState(
        currentState: PresentationState,
        windowExists: Bool,
        isActuallyVisible: Bool
    ) -> PresentationState {
        switch currentState {
        case .hidden:
            return isActuallyVisible ? .visible : .hidden
        case .showing:
            if isActuallyVisible {
                return .visible
            }
            return windowExists ? .showing : .hidden
        case .visible:
            return isActuallyVisible ? .visible : .hidden
        case .hiding:
            return isActuallyVisible ? .hiding : .hidden
        }
    }

    nonisolated static func toggleAction(
        presentationState: PresentationState,
        isActuallyVisible: Bool
    ) -> ToggleAction {
        let effectiveState: PresentationState
        switch presentationState {
        case .visible where !isActuallyVisible:
            effectiveState = .hidden
        case .hidden where isActuallyVisible:
            effectiveState = .visible
        default:
            effectiveState = presentationState
        }

        switch effectiveState {
        case .hidden, .hiding:
            return .show
        case .showing, .visible:
            return .hide
        }
    }

    nonisolated static func withEmergencyTapState<T>(
        _ body: (inout EmergencyTapState) -> T
    ) -> T {
        emergencyTapStateLock.lock()
        defer { emergencyTapStateLock.unlock() }
        return body(&emergencyTapState)
    }

    nonisolated static func readEmergencyTapState<T>(
        _ body: (EmergencyTapState) -> T
    ) -> T {
        emergencyTapStateLock.lock()
        defer { emergencyTapStateLock.unlock() }
        return body(emergencyTapState)
    }

    nonisolated static func emergencyEventTapIfValid() -> CFMachPort? {
        readEmergencyTapState { state in
            guard let eventTap = state.eventTap, CFMachPortIsValid(eventTap) else {
                return nil
            }
            return eventTap
        }
    }

    nonisolated static func setEmergencyTimelineVisible(_ visible: Bool) {
        withEmergencyTapState { state in
            state.isTimelineVisible = visible
        }
    }

    nonisolated static func isEmergencyTimelineVisible() -> Bool {
        readEmergencyTapState(\.isTimelineVisible)
    }

    func startObservingApplicationActivation() {
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

    func stopObservingApplicationActivation() {
        guard let workspaceActivationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        self.workspaceActivationObserver = nil
    }

    var currentVisibilitySnapshot: VisibilitySnapshot {
        VisibilitySnapshot(
            windowExists: window != nil,
            windowVisible: window?.isVisible ?? false,
            windowMiniaturized: window?.isMiniaturized ?? false,
            windowAlphaValue: window?.alphaValue ?? 0,
            appHidden: NSApp.isHidden
        )
    }

    var isActuallyVisible: Bool {
        currentVisibilitySnapshot.isActuallyVisible
    }

    func reconcileVisibilityState(reason: String) {
        let snapshot = currentVisibilitySnapshot
        let previousState = presentationState
        let reconciledState = Self.reconciledPresentationState(
            currentState: previousState,
            windowExists: snapshot.windowExists,
            isActuallyVisible: snapshot.isActuallyVisible
        )

        guard reconciledState != previousState else { return }
        presentationState = reconciledState

        if reconciledState == .visible {
            Self.setEmergencyTimelineVisible(true)
            startObservingApplicationActivation()
        } else if reconciledState == .hidden {
            Self.setEmergencyTimelineVisible(false)
            stopObservingApplicationActivation()
        }

        Log.info(
            "[TimelineVisibility] reconciled reason=\(reason) from=\(previousState.rawValue) to=\(reconciledState.rawValue) actualVisible=\(snapshot.isActuallyVisible) windowExists=\(snapshot.windowExists) windowVisible=\(snapshot.windowVisible) windowMini=\(snapshot.windowMiniaturized) windowAlpha=\(String(format: "%.2f", snapshot.windowAlphaValue)) appHidden=\(snapshot.appHidden)",
            category: .ui
        )

        guard previousState == .visible, reconciledState == .hidden, !isHiding else {
            return
        }

        synchronizeHiddenStateAfterExternalDismissal(reason: reason, force: true)
    }

    func recordVisibleSessionMetricsIfNeeded() {
        guard let startTime = sessionStartTime, let coordinator = coordinator else { return }

        let durationMs = Int64(Date().timeIntervalSince(startTime) * 1000)
        DashboardViewModel.recordTimelineSession(coordinator: coordinator, durationMs: durationMs)

        if sessionScrubDistance > 0 {
            DashboardViewModel.recordScrubDistance(coordinator: coordinator, distancePixels: sessionScrubDistance)
        }

        sessionStartTime = nil
        sessionScrubDistance = 0
    }

    func dismissTransientTimelineUIForHide() {
        tapeShowAnimationTask?.cancel()
        guard let viewModel = timelineViewModel else { return }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            viewModel.setTapeHidden(true)
        }
        dismissSearchAndTimelineMenusForHide(on: viewModel)
        dismissVisibleOverlaysForHide(on: viewModel)
    }

    func dismissSearchAndTimelineMenusForHide(on viewModel: SimpleTimelineViewModel) {
        // Abort in-flight search work now that the timeline is dismissing.
        viewModel.searchViewModel.cancelSearch()

        // Ensure right-click menus don't persist across timeline sessions.
        viewModel.dismissContextMenu()
        viewModel.dismissTimelineContextMenu()
        viewModel.clearTimelineTapeRightClickHint(animated: false)
    }

    func dismissVisibleOverlaysForHide(on viewModel: SimpleTimelineViewModel) {
        if viewModel.isFilterPanelVisible {
            viewModel.dismissFilterPanel()
        }
        if viewModel.isCalendarPickerVisible {
            viewModel.closeCalendarPicker()
        }
        if viewModel.isDateSearchActive {
            viewModel.closeDateSearch()
        }
        if viewModel.isSearchOverlayVisible {
            prepareSearchOverlayForHide(on: viewModel)
        }
        if viewModel.isInFrameSearchVisible ||
            !viewModel.inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.closeInFrameSearch(clearQuery: true)
        }
    }

    func prepareSearchOverlayForHide(on viewModel: SimpleTimelineViewModel) {
        // Preserve overlay state across timeline toggle, but do not keep the
        // spotlight view mounted during the next timeline-open animation.
        viewModel.searchViewModel.requestDismissRecentEntriesPopoverByUser()
        viewModel.searchViewModel.suppressRecentEntriesForNextOverlayOpen()
        shouldRestoreSearchOverlayAfterNextShow = true
        viewModel.closeSearchOverlay()
    }

    func prepareForHiddenStateTransition(reason: String) {
        stopObservingApplicationActivation()
        cancelWindowFadeIn(reason: reason)
        if deferredSearchOverlayRestoreTask != nil {
            shouldRestoreSearchOverlayAfterNextShow = true
        }
        cancelDeferredSearchOverlayRestore()
        liveModeCaptureTask?.cancel()
        liveModeCaptureTask = nil
        recordVisibleSessionMetricsIfNeeded()
        dismissTransientTimelineUIForHide()
        removeEventMonitors()
        scheduleDeferredHostingViewDetach()
    }

    func synchronizeHiddenStateAfterExternalDismissal(
        reason: String,
        force: Bool = false,
        restorePreviousFocus: Bool = false
    ) {
        let snapshot = currentVisibilitySnapshot
        let needsSynchronization = force ||
            presentationState != .hidden ||
            snapshot.windowVisible
        guard needsSynchronization else { return }
        guard !isHiding else { return }

        Log.warning(
            "[TimelineVisibility] synchronizing hidden state after external dismissal reason=\(reason) state=\(presentationState.rawValue) windowExists=\(snapshot.windowExists) windowVisible=\(snapshot.windowVisible) windowMini=\(snapshot.windowMiniaturized) windowAlpha=\(String(format: "%.2f", snapshot.windowAlphaValue)) appHidden=\(snapshot.appHidden)",
            category: .ui
        )

        prepareForHiddenStateTransition(reason: "external-dismissal.\(reason)")
        applyHiddenState(
            restorePreviousFocus: restorePreviousFocus,
            hideRequestedAt: nil,
            reason: "external-dismissal.\(reason)"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishHideTransitionCleanup()
        }
    }

    func dismissForActivatedApplication(_ activatedApplication: NSRunningApplication?) {
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
        reconcileVisibilityState(reason: "hideAndWait")
        if isHiding {
            return await hideCompletionCoordinator.wait()
        }

        guard isVisible else { return true }
        guard window != nil else {
            return await withCheckedContinuation { continuation in
                hideCompletionCoordinator.append(continuation)
                synchronizeHiddenStateAfterExternalDismissal(
                    reason: "hideAndWaitMissingWindow",
                    restorePreviousFocus: restorePreviousFocus
                )
            }
        }

        return await withCheckedContinuation { continuation in
            hideCompletionCoordinator.append(continuation)
            hide(restorePreviousFocus: restorePreviousFocus)
        }
    }

    func captureFocusRestoreTarget() {
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
    }

    func restoreFocusIfNeeded(
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
              !app.isTerminated else { return }

        if let hideElapsedMs {
            Log.recordLatency(
                "timeline.focus.restore_after_hide_ms",
                valueMs: hideElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 350,
                criticalThresholdMs: 700
            )
        }

        _ = app.activate(options: [.activateIgnoringOtherApps])
    }

    func applyHiddenState(
        restorePreviousFocus: Bool,
        hideRequestedAt: CFAbsoluteTime?,
        reason _: String
    ) {
        let wasHidingToShowDashboard = isHidingToShowDashboard
        isHiding = false

        // Only hide dashboard if it wasn't the active window before timeline opened
        // AND we're not hiding specifically to show the dashboard/settings.
        if dashboardWasKeyWindow != true,
           !wasHidingToShowDashboard,
           DashboardWindowController.shared.window?.attachedSheet == nil {
            DashboardWindowController.shared.hide()
        }
        isHidingToShowDashboard = false

        if let window {
            // Ignore mouse events while hidden to prevent blocking clicks on other windows.
            window.ignoresMouseEvents = true
            window.orderOut(nil)
        }
        presentationState = .hidden
        Self.setEmergencyTimelineVisible(false)
        lastHiddenAt = Date()
        suppressLiveScrollUntil = 0

        if let hideRequestedAt {
            let hideElapsedMs = (CFAbsoluteTimeGetCurrent() - hideRequestedAt) * 1000
            Log.recordLatency(
                "timeline.hide.window_hidden_ms",
                valueMs: hideElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 300,
                criticalThresholdMs: 600
            )
        }

        restoreFocusIfNeeded(
            requestedRestore: restorePreviousFocus,
            wasHidingToShowDashboard: wasHidingToShowDashboard,
            hideRequestedAt: hideRequestedAt
        )
    }

    func finishHideTransitionCleanup() async {
        // Mark timeline hidden before post-hide refresh so frame reads can use relaxed timing.
        if let coordinator {
            await coordinator.setTimelineVisible(false)
        }

        hideCompletionCoordinator.resumeAll(hidden: true)

        await compactHiddenPresentationState()

        onClose?()
        TimelineScaleFactor.resetCache()
        NotificationCenter.default.post(name: .timelineDidClose, object: nil)
    }
}
