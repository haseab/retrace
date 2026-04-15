import AppKit
import SwiftUI
import App
import Shared
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers

@MainActor
extension TimelineWindowController {

    /// Save state for cross-session persistence (call on app termination)
    public func saveStateForTermination() {
        timelineViewModel?.saveState()
    }

    /// Completely destroy the pre-rendered window (call when memory pressure is high or app is terminating)
    public func destroyPreparedWindow() {
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
    func compactHiddenPresentationState() async {
        let viewModel = timelineViewModel

        if let viewModel {
            viewModel.setTapeHidden(true)
            viewModel.resetControlsVisibilityForNextOpen()  // Reset controls visibility so they show on next open
            viewModel.resetFrameZoom()  // Reset zoom so it's at 100% on next open
            viewModel.compactPresentationState(
                reason: "hide-keep-headless-state",
                purgeDiskFrameBuffer: false
            )
            // Reset zoom region state on hide.
            viewModel.exitZoomRegion()
        }

        // Always detach any mounted presentation and purge decode caches, even if the
        // prepared view model vanished unexpectedly. Otherwise hidden decoder work can linger.
        destroyMountedPresentation()
        if let coordinator {
            await coordinator.purgeVideoDecodingCaches(reason: "timeline hidden")
        }
    }

    func scheduleDeferredHostingViewDetach() {
        cancelDeferredHostingViewDetach()
        deferredHostingViewDetachTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.hostingViewDetachDelay, clock: .continuous)
            guard let self, !self.isVisible else { return }
            self.hostingView?.removeFromSuperview()
        }
    }

    func cancelDeferredHostingViewDetach() {
        deferredHostingViewDetachTask?.cancel()
        deferredHostingViewDetachTask = nil
    }

    func ensurePreparedViewModel(coordinator: AppCoordinator) -> SimpleTimelineViewModel {
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

    func mountPresentationIfNeeded(
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

    func destroyMountedPresentation() {
        cancelDeferredHostingViewDetach()
        cancelWindowFadeIn(reason: "destroyMountedPresentation")
        cancelDeferredSearchOverlayRestore()
        liveModeCaptureTask?.cancel()
        liveModeCaptureTask = nil
        stopObservingApplicationActivation()
        isHiding = false
        presentationState = .hidden
        Self.setEmergencyTimelineVisible(false)
        timelineViewModel?.setPresentationWorkEnabled(false, reason: "destroyMountedPresentation")

        window?.orderOut(nil)
        hostingView?.removeFromSuperview()
        hostingView = nil
        window = nil
    }

    @MainActor
    func awaitTimelineViewModelReady() async -> SimpleTimelineViewModel {
        if let timelineViewModel {
            return timelineViewModel
        }

        return await withCheckedContinuation { continuation in
            pendingTimelineViewModelWaiters.append(continuation)
        }
    }

    func setTimelineViewModel(_ viewModel: SimpleTimelineViewModel) {
        timelineViewModel = viewModel

        let waiters = pendingTimelineViewModelWaiters
        pendingTimelineViewModelWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: viewModel)
        }
    }

    // MARK: - Window Creation

    func createWindow(for screen: NSScreen) -> NSWindow {
        // Use custom window subclass that can become key even when borderless
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.delegate = self

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
}

@MainActor
extension TimelineWindowController {

    // MARK: - Emergency Escape CGEvent Tap

    func setupEmergencyTapPermissionObservers() {
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

    /// Sets up a CGEvent tap on a dedicated thread to handle Escape key
    /// This works even when the main thread is completely frozen
    func setupEmergencyEscapeTap() {
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

    func suspendEmergencyEscapeTapForPermissionLoss() {
        if let eventTap = Self.emergencyEventTapIfValid() {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            Log.warning("[TIMELINE] Suspended emergency escape event tap after permission revoke", category: .ui)
        }
    }

    func resumeEmergencyEscapeTapIfNeeded() {
        guard Self.hasEmergencyTapPermission() else { return }

        if let eventTap = Self.emergencyEventTapIfValid() {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }

        setupEmergencyEscapeTap()
    }

    // MARK: - Shortcut Loading

    static let timelineShortcutKey = "timelineShortcutConfig"

    /// Load the current timeline shortcut from UserDefaults
    func loadTimelineShortcut() -> ShortcutConfig {
        OnboardingManager.loadShortcutConfig(
            forKey: Self.timelineShortcutKey,
            fallback: .defaultTimeline
        )
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
            name: .openSettingsPauseReminderInterval,
            object: nil
        )
    }

    /// Handle toggle dashboard notification - if timeline is visible, hide it first
    @objc func handleToggleDashboard(_ notification: Notification) {
        reconcileVisibilityState(reason: "toggleDashboardNotification")
        guard isVisible else { return }
        // Timeline is visible, so hide it properly before showing dashboard
        hideToShowDashboard()
    }

    /// Handle open settings notification - if timeline is visible, hide it first
    @objc func handleOpenSettings(_ notification: Notification) {
        reconcileVisibilityState(reason: "openSettingsNotification")
        guard isVisible else { return }
        // Timeline is visible, so hide it properly before showing settings
        hideToShowDashboard()
    }

    /// Handle active display change - move hidden window to new screen
    @objc func handleDisplayChange(_ notification: Notification) {
        moveWindowToMouseScreen()
    }

    @objc func handleApplicationDidHide(_ notification: Notification) {
        guard isVisible else { return }
        synchronizeHiddenStateAfterExternalDismissal(reason: "applicationDidHide")
    }

    // MARK: - Pre-rendering

    /// Prepare a metadata-only timeline state at startup.
    /// The hidden window/view hierarchy is no longer kept alive; we only warm the view model.
    public func prepareWindow() {
        guard let coordinator = coordinator else { return }

        if isPrepared, timelineViewModel != nil { return }

        let viewModel = ensurePreparedViewModel(coordinator: coordinator)
        viewModel.setTapeHidden(true)

        // Load the most recent frame data in the background
        Task { @MainActor in
            await viewModel.loadMostRecentFrame(refreshPresentation: false)
        }

        isPrepared = true
    }

    /// Move the hidden window to the screen where the mouse is (for instant show on any screen)
    func moveWindowToMouseScreen() {
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
    func captureLiveScreenshotAsync() async -> NSImage? {
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
    func prepareLiveModeState(shouldUseLiveMode: Bool, viewModel: SimpleTimelineViewModel) {
        if shouldUseLiveMode {
            // Prime live mode before showing the window so open animation/render path
            // matches previous behavior while screenshot capture finishes in background.
            viewModel.setLivePresentationState(isActive: true, screenshot: nil)
        } else {
            viewModel.setLivePresentationState(isActive: false, screenshot: nil)
        }
    }

    /// Starts asynchronous live screenshot capture and then triggers live OCR.
    /// This keeps timeline open responsive by removing heavy capture from the critical show path.
    func startLiveModeCaptureIfNeeded(shouldUseLiveMode: Bool, viewModel: SimpleTimelineViewModel) {
        guard shouldUseLiveMode else {
            viewModel.setLivePresentationState(isActive: false, screenshot: nil)
            return
        }

        let targetViewModel = viewModel
        liveModeCaptureTask = Task { @MainActor [weak self, weak targetViewModel] in
            guard let self, let targetViewModel else { return }
            let screenshot = await self.captureLiveScreenshotAsync()
            guard !Task.isCancelled else { return }
            guard self.isVisible, self.timelineViewModel === targetViewModel else { return }
            guard targetViewModel.isNewestLoadedFrameRecent() else {
                targetViewModel.setLivePresentationState(isActive: false, screenshot: nil)
                return
            }
            guard targetViewModel.isNearLatestLoadedFrame(within: Self.instantLiveReopenFrameThreshold) else { return }
            guard let screenshot else {
                // Fall back to historical frame rendering if live capture fails.
                targetViewModel.setLivePresentationState(isActive: false, screenshot: nil)
                return
            }

            targetViewModel.setLivePresentationState(isActive: true, screenshot: screenshot)
            targetViewModel.performLiveOCR()
        }
    }

    /// Refresh metadata when timeline launches so hidden windows don't need periodic background refresh.
    func refreshTimelineMetadataOnShow(
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
}

extension TimelineWindowController {
    nonisolated static func hasEmergencyTapPermission() -> Bool {
        CGPreflightListenEventAccess()
    }

    nonisolated static func installEmergencyEscapeTap(expectedSetupToken: UInt64) {
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
                let isEscapeKey = keyCode == 53
                let isCmdOptionEscape =
                    keyCode == 53 && flags.contains(.maskCommand) && flags.contains(.maskAlternate)

                if isEscapeKey || isCmdOptionEscape {
                    DispatchQueue.main.async {
                        TimelineWindowController.shared.hide()
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            clearEmergencyTapInstallStateIfCurrent(expectedSetupToken: expectedSetupToken)
            Log.warning("[TIMELINE] Failed to create emergency escape event tap", category: .ui)
            return
        }

        installEmergencyEscapeTapIfValid(eventTap: eventTap, expectedSetupToken: expectedSetupToken)
    }

    nonisolated static func installEmergencyEscapeTapIfValid(
        eventTap: CFMachPort,
        expectedSetupToken: UInt64
    ) {
        guard shouldContinueInstallingEmergencyTap(expectedSetupToken: expectedSetupToken) else {
            clearEmergencyTapInstallStateIfCurrent(expectedSetupToken: expectedSetupToken)
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        let runLoop = CFRunLoopGetCurrent()

        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        withEmergencyTapState { state in
            state.eventTap = eventTap
            state.runLoopSource = runLoopSource
            state.runLoop = runLoop
            state.isInstallingTap = false
        }

        CFRunLoopRun()

        // Cleanup when run loop exits
        withEmergencyTapState { state in
            state.eventTap = nil
            state.runLoopSource = nil
            state.runLoop = nil
            state.tapThread = nil
            state.isInstallingTap = false
        }
    }

    nonisolated static func shouldContinueInstallingEmergencyTap(expectedSetupToken: UInt64) -> Bool {
        readEmergencyTapState { state in
            state.setupToken == expectedSetupToken
        }
    }

    nonisolated static func clearEmergencyTapInstallStateIfCurrent(expectedSetupToken: UInt64) {
        withEmergencyTapState { state in
            guard state.setupToken == expectedSetupToken else { return }
            state.isInstallingTap = false
        }
    }
}

// MARK: - NSWindowDelegate

extension TimelineWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow, closedWindow === window else {
            return
        }
        synchronizeHiddenStateAfterExternalDismissal(reason: "windowWillClose")
    }
}

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
