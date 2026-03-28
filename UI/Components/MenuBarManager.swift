import SwiftUI
import AppKit
import App
import Shared
import Dispatch

/// Manages the macOS menu bar icon and status menu
public class MenuBarManager: ObservableObject {
    typealias PrimaryAction = (title: String, imageSystemName: String)

    // MARK: - Shared Instance

    /// Shared instance for accessing from Settings and other views
    public static var shared: MenuBarManager?

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var lastStatusMenuOpenEventTimestamp: TimeInterval = 0
    private var localStatusClickMonitor: Any?
    private let coordinator: AppCoordinator
    private let onboardingManager: OnboardingManager
    private var refreshTimer: DispatchSourceTimer?
    private var autoResumeCountdownTimer: Timer?
    private weak var autoResumeStatusItem: NSMenuItem?

    @Published public var isRecording = false

    /// Tracks whether recording indicator should be hidden (e.g., when timeline is open)
    private var shouldHideRecordingIndicator = false

    /// Tracks whether the menu bar icon should be visible (user preference)
    private var isMenuBarIconEnabled = true

    /// Cached shortcuts (loaded from OnboardingManager)
    private var timelineShortcut: ShortcutConfig = .defaultTimeline
    private var dashboardShortcut: ShortcutConfig = .defaultDashboard
    private var recordingShortcut: ShortcutConfig = .defaultRecording
    private var systemMonitorShortcut: ShortcutConfig = .defaultSystemMonitor
    private var commentShortcut: ShortcutConfig = .defaultCommentCapture

    /// Timer for icon fill animation
    private var iconAnimationTimer: Timer?
    /// Current fill progress for icon animation (0.0 to 1.0)
    private var iconFillProgress: CGFloat = 0.0
    /// References used to keep the recording toggle pinned to the row's trailing edge.
    private weak var recordingToggleContainerView: NSView?
    private weak var recordingToggleControl: RecordingToggleSwitch?
    /// True when capture was paused via pause controls (not plain keyboard toggle off).
    private var isPausedByUser = false
    /// Pending task that resumes capture after a timed pause.
    private var scheduledResumeTask: Task<Void, Never>?
    /// Target wall clock time for timed resume (nil means paused indefinitely / no timed pause active).
    private var scheduledResumeDate: Date?

    private enum RecordingStatusIconStyle {
        case off
        case recording
        case paused
    }

    public var isPausedState: Bool {
        !isRecording && isPausedByUser
    }

    public var timedPauseRemainingSeconds: Int? {
        guard isPausedState, let scheduledResumeDate else { return nil }
        return max(0, Int(ceil(scheduledResumeDate.timeIntervalSinceNow)))
    }

    // MARK: - Initialization

    public init(coordinator: AppCoordinator, onboardingManager: OnboardingManager) {
        self.coordinator = coordinator
        self.onboardingManager = onboardingManager
        MenuBarManager.shared = self
    }

    // MARK: - Setup

    public func setup() {
        // Don't create status item if menu bar icon is disabled
        guard isMenuBarIconEnabled else {
            Log.debug("[MenuBarLifecycle] setup skipped: menu bar icon disabled", category: .ui)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        Log.debug("[MenuBarLifecycle] status item created", category: .ui)

        if statusItem?.button != nil {
            // Start with icon showing current recording state
            updateIconForCurrentState()
            configureStatusButtonClicks()
            setupStatusClickMonitors()
        } else {
            Log.error("[MenuBarLifecycle] status item button missing after creation", category: .ui)
        }

        // Load shortcuts then setup menu and hotkeys
        Task { @MainActor in
            await loadShortcuts()
            setupMenu()
            setupTimelineNotifications()
            configureWindowControllers()

            // Only setup global hotkeys if onboarding is past the permissions step (step 3)
            // This prevents HotkeyManager from calling AXIsProcessTrusted() before user grants permission
            let onboardingStep = UserDefaults.standard.integer(forKey: "onboardingCurrentStep")
            let hasCompletedOnboarding = await onboardingManager.hasCompletedOnboarding
            if hasCompletedOnboarding || onboardingStep >= 4 {
                setupGlobalHotkey()
            }

            setupAutoRefresh()
            // Sync with coordinator to get current recording state
            syncWithCoordinator()
        }
    }

    /// Setup timer to auto-refresh recording status
    private func setupAutoRefresh() {
        // Sync recording status every 2 seconds with leeway for power efficiency
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.syncWithCoordinator()
        }
        timer.resume()
        refreshTimer = timer

        // Setup periodic diagnostics logging (every 5 minutes)
        setupDiagnosticsLogging()
    }

    /// Setup periodic logging of UI responsiveness diagnostics
    private func setupDiagnosticsLogging() {
        let diagnosticsTimer = DispatchSource.makeTimerSource(queue: .main)
        diagnosticsTimer.schedule(deadline: .now() + 300, repeating: 300.0)
        diagnosticsTimer.setEventHandler { [weak self] in
            self?.logDiagnostics()
        }
        diagnosticsTimer.resume()
        // Store reference to prevent deallocation (reuse refreshTimer pattern)
        objc_setAssociatedObject(self, "diagnosticsTimer", diagnosticsTimer, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Log UI responsiveness diagnostics
    private func logDiagnostics() {
        let diag = coordinator.statusHolder.diagnostics
        let status = coordinator.statusHolder.status

        // Always log a health check
        Log.info("[UI Health] uptime=\(status.startTime.map { Int(-$0.timeIntervalSinceNow / 60) } ?? 0)min frames=\(status.framesProcessed) errors=\(status.errors) maxPendingActorReqs=\(diag.maxPending) slowResponses=\(diag.slowResponses)", category: .ui)

        // Warn if we're seeing signs of potential UI freeze conditions
        if diag.maxPending > 5 {
            Log.warning("[UI Health] High actor request pile-up detected: maxPending=\(diag.maxPending). This could indicate UI freeze risk.", category: .ui)
        }
        if diag.slowResponses > 10 {
            Log.warning("[UI Health] Multiple slow actor responses: count=\(diag.slowResponses). Actor may be overloaded.", category: .ui)
        }

        // Reset counters for next period
        coordinator.statusHolder.resetDiagnostics()
    }

    /// Load shortcuts from OnboardingManager
    private func loadShortcuts() async {
        timelineShortcut = await onboardingManager.timelineShortcut
        dashboardShortcut = await onboardingManager.dashboardShortcut
        recordingShortcut = await onboardingManager.recordingShortcut
        systemMonitorShortcut = await onboardingManager.systemMonitorShortcut
        commentShortcut = await onboardingManager.commentShortcut
        Log.info(
            "[MenuBarManager] Loaded shortcuts - Timeline: \(timelineShortcut.displayString), Dashboard: \(dashboardShortcut.displayString), Recording: \(recordingShortcut.displayString), Monitor: \(systemMonitorShortcut.displayString), Comment: \(commentShortcut.displayString)",
            category: .ui
        )
    }

    @MainActor
    private func reloadShortcutsMainActor() async {
        await loadShortcuts()
        setupGlobalHotkey()
        setupMenu()
    }

    /// Reload shortcuts from storage and re-register hotkeys (called from Settings)
    public func reloadShortcuts() {
        Task { @MainActor in
            await reloadShortcutsMainActor()
        }
    }

    /// Reload shortcuts immediately on the main actor for flows that need the
    /// hotkeys active before dismissing or advancing their UI.
    @MainActor
    public func reloadShortcutsNow() async {
        await reloadShortcutsMainActor()
    }

    @MainActor
    private func configureWindowControllers() {
        TimelineWindowController.shared.configure(coordinator: coordinator)
        StandaloneCommentComposerWindowController.shared.configure(coordinator: coordinator)
    }

    /// Setup notifications for timeline open/close
    private func setupTimelineNotifications() {
        NotificationCenter.default.addObserver(
            forName: .timelineDidOpen,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hideRecordingIndicator()
        }

        NotificationCenter.default.addObserver(
            forName: .timelineDidClose,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restoreRecordingIndicator()
        }
    }

    /// Setup global hotkeys for timeline and dashboard
    private func setupGlobalHotkey() {
        // Clear existing hotkeys before registering new ones
        // This prevents old shortcuts from persisting after settings changes
        HotkeyManager.shared.unregisterAll()

        // Register timeline global hotkey (skip if cleared)
        if !timelineShortcut.key.isEmpty {
            HotkeyManager.shared.registerHotkey(
                key: timelineShortcut.key,
                modifiers: timelineShortcut.modifiers.nsModifiers,
                allowsCarbonFallback: true
            ) { [weak self] in
                self?.toggleTimelineOverlay()
            }
        }

        // Register dashboard global hotkey (skip if cleared)
        if !dashboardShortcut.key.isEmpty {
            HotkeyManager.shared.registerHotkey(
                key: dashboardShortcut.key,
                modifiers: dashboardShortcut.modifiers.nsModifiers,
                allowsCarbonFallback: true
            ) { [weak self] in
                self?.toggleDashboard()
            }
        }

        // Register recording global hotkey (skip if cleared)
        if !recordingShortcut.key.isEmpty {
            HotkeyManager.shared.registerHotkey(
                key: recordingShortcut.key,
                modifiers: recordingShortcut.modifiers.nsModifiers
            ) { [weak self] in
                self?.toggleRecording()
            }
        }

        // Register system monitor global hotkey (skip if cleared)
        if !systemMonitorShortcut.key.isEmpty {
            HotkeyManager.shared.registerHotkey(
                key: systemMonitorShortcut.key,
                modifiers: systemMonitorShortcut.modifiers.nsModifiers
            ) { [weak self] in
                self?.toggleSystemMonitor()
            }
        }

        // Register quick-comment global hotkey (skip if cleared)
        if !commentShortcut.key.isEmpty {
            HotkeyManager.shared.registerHotkey(
                key: commentShortcut.key,
                modifiers: commentShortcut.modifiers.nsModifiers
            ) { [weak self] in
                self?.openCommentComposerFromHotkey()
            }
        }
    }

    /// Toggle the fullscreen timeline overlay
    private func toggleTimelineOverlay() {
        Task { @MainActor in
            TimelineWindowController.shared.toggle()
        }
    }

    private func keyboardShortcutMetricIdentifier(for shortcut: ShortcutConfig) -> String {
        var parts: [String] = []
        let modifiers = shortcut.modifiers
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }

        let normalizedKey = shortcut.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        parts.append(normalizedKey == "space" ? "space" : normalizedKey)
        return parts.joined(separator: "+")
    }

    /// Open the standalone quick-comment composer at the current moment.
    private func openCommentComposerFromHotkey() {
        Task { @MainActor in
            let source = "global_hotkey_comment"
            DashboardViewModel.recordKeyboardShortcut(
                coordinator: coordinator,
                shortcut: keyboardShortcutMetricIdentifier(for: commentShortcut)
            )
            let didHideTimeline = await TimelineWindowController.shared.hideAndWait(
                restorePreviousFocus: false
            )
            guard didHideTimeline else {
                Log.warning(
                    "[QuickComment] Aborting hotkey open because timeline did not finish hiding",
                    category: .ui
                )
                return
            }
            StandaloneCommentComposerWindowController.shared.openCommentComposerAtCurrentMoment(
                source: source
            )
        }
    }

    /// Toggle the dashboard window (show if hidden, hide if visible)
    private func toggleDashboard() {
        NotificationCenter.default.post(name: .toggleDashboard, object: nil)
    }

    /// Toggle recording on/off (called from global hotkey)
    private func toggleRecording() {
        Task { @MainActor in
            do {
                let currentlyRecording = coordinator.statusHolder.status.isRunning
                let shouldRecord = !currentlyRecording

                // Keyboard shortcut remains a plain toggle and clears any timed pause intent.
                clearScheduledResume()
                isPausedByUser = false

                // Update state and animate icon
                isRecording = shouldRecord
                animateIconFill(toRecording: shouldRecord)

                if shouldRecord {
                    Log.debug("[MenuBar] Hotkey toggle ON - Starting pipeline...", category: .ui)
                    try await coordinator.startPipeline()
                    DashboardViewModel.recordRecordingStartedFromMenu(
                        coordinator: coordinator,
                        source: "menu_hotkey"
                    )
                } else {
                    Log.debug("[MenuBar] Hotkey toggle OFF - Stopping pipeline...", category: .ui)
                    try await coordinator.stopPipeline()
                }
            } catch {
                Log.error("[MenuBar] Failed to toggle recording via hotkey: \(error)", category: .ui)
                // Revert on error
                let actualState = coordinator.statusHolder.status.isRunning
                isRecording = actualState
                updateIcon(recording: actualState)
            }
        }
    }

    /// Hide recording indicator (called when timeline opens)
    private func hideRecordingIndicator() {
        shouldHideRecordingIndicator = true
        updateIcon(recording: false)
    }

    /// Restore recording indicator (called when timeline closes)
    private func restoreRecordingIndicator() {
        shouldHideRecordingIndicator = false
        updateIconForCurrentState()
    }

    private func currentIconStyle() -> RecordingStatusIconStyle {
        if shouldHideRecordingIndicator {
            return .off
        }
        if isRecording {
            return .recording
        }
        return isPausedByUser ? .paused : .off
    }

    private func updateIconForCurrentState() {
        updateIcon(style: currentIconStyle())
    }

    /// Update the menu bar icon to show recording status (no animation)
    private func updateIcon(style: RecordingStatusIconStyle) {
        guard let button = statusItem?.button else { return }
        let image = createStatusIcon(style: style)
        button.image = image
        button.image?.isTemplate = true
    }

    /// Update the menu bar icon to show recording status (no animation)
    private func updateIcon(recording: Bool) {
        updateIcon(style: recording ? .recording : .off)
    }

    /// Animate the menu bar icon with a "press" effect when recording state changes
    /// The triangle shrinks down fast, then expands back slower
    private func animateIconFill(toRecording: Bool) {
        // Cancel any existing animation
        iconAnimationTimer?.invalidate()

        let frameRate: TimeInterval = 1.0 / 60.0
        let pressDuration: TimeInterval = 0.10   // Press down (100ms)
        let releaseDuration: TimeInterval = 0.30  // Release (300ms)
        let pressFrames = Int(pressDuration / frameRate)
        let releaseFrames = Int(releaseDuration / frameRate)
        var currentFrame = 0
        var phase: Int = 0  // 0 = pressing down, 1 = releasing

        let startFilled = !toRecording  // Current state before change
        let minScale: CGFloat = 0.3  // Shrink to 30% size

        iconAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameRate, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            currentFrame += 1

            if phase == 0 {
                // Phase 0: Fast shrinking (pressing down)
                let progress = CGFloat(currentFrame) / CGFloat(pressFrames)
                // Ease-in for snappy press feel
                let easedProgress = progress * progress
                let scale = 1.0 - ((1.0 - minScale) * easedProgress)

                if let button = self.statusItem?.button {
                    let image = self.createStatusIcon(style: startFilled ? .recording : .off, scale: scale)
                    button.image = image
                    button.image?.isTemplate = true
                }

                if currentFrame >= pressFrames {
                    // Switch to release phase and change fill state
                    phase = 1
                    currentFrame = 0
                }
            } else {
                // Phase 1: Slower expanding back (releasing) with new fill state
                let progress = CGFloat(currentFrame) / CGFloat(releaseFrames)
                // Ease-out for smooth release
                let easedProgress = 1.0 - pow(1.0 - progress, 3)
                let scale = minScale + ((1.0 - minScale) * easedProgress)

                if let button = self.statusItem?.button {
                    let image = self.createStatusIcon(style: toRecording ? .recording : .off, scale: scale)
                    button.image = image
                    button.image?.isTemplate = true
                }

                if currentFrame >= releaseFrames {
                    timer.invalidate()
                    // Ensure final state is correct
                    self.iconFillProgress = toRecording ? 1.0 : 0.0
                }
            }
        }
    }

    /// Create a custom status icon with two triangles (Retrace logo)
    /// Left triangle: Points left, supports recording/off/paused visual states, with optional scale
    /// Right triangle: Points right, always outlined
    private func createStatusIcon(style: RecordingStatusIconStyle, scale: CGFloat = 1.0) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()

        // Triangle dimensions (matching logo proportions)
        let baseTriangleHeight: CGFloat = 12
        let baseTriangleWidth: CGFloat = 8
        let verticalCenter: CGFloat = size.height / 2
        let gap: CGFloat = 3.0 // Gap between triangles

        // Apply scale to left triangle dimensions
        let triangleHeight = baseTriangleHeight * scale
        let triangleWidth = baseTriangleWidth * scale

        // Left triangle - Points left ◁ (recording indicator)
        // Center the scaled triangle at the same position
        let baseCenterX: CGFloat = 2 + (baseTriangleWidth / 2)  // Original center X
        let leftTip = baseCenterX - (triangleWidth / 2)
        let leftBase = baseCenterX + (triangleWidth / 2)

        let leftTriangle = NSBezierPath()
        leftTriangle.move(to: NSPoint(x: leftTip, y: verticalCenter))
        leftTriangle.line(to: NSPoint(x: leftBase, y: verticalCenter - triangleHeight / 2))
        leftTriangle.line(to: NSPoint(x: leftBase, y: verticalCenter + triangleHeight / 2))
        leftTriangle.close()

        switch style {
        case .recording:
            // Filled when recording (no border)
            NSColor.white.setFill()
            leftTriangle.fill()
        case .paused, .off:
            // Outlined when paused or fully off.
            NSColor.white.setStroke()
            leftTriangle.lineWidth = 1.2
            leftTriangle.stroke()
        }

        // Right triangle - Points right ▷ (always outlined, not scaled)
        let rightTriangle = NSBezierPath()
        let rightBase: CGFloat = 2 + baseTriangleWidth + gap
        let rightTip: CGFloat = rightBase + baseTriangleWidth
        rightTriangle.move(to: NSPoint(x: rightTip, y: verticalCenter)) // Right tip
        rightTriangle.line(to: NSPoint(x: rightBase, y: verticalCenter - baseTriangleHeight / 2)) // Top left
        rightTriangle.line(to: NSPoint(x: rightBase, y: verticalCenter + baseTriangleHeight / 2)) // Bottom left
        rightTriangle.close()

        NSColor.white.setStroke()
        rightTriangle.lineWidth = 1.2
        rightTriangle.stroke()

        image.unlockFocus()
        return image
    }

    /// Create a custom view with a toggle switch for recording
    private func createRecordingToggleView() -> NSView {
        let containerWidth: CGFloat = 235
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 30))

        // Icon
        let iconSize: CGFloat = 16
        let iconView = NSImageView(frame: NSRect(x: 17, y: 7, width: iconSize, height: iconSize))
        if let iconImage = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            iconView.image = iconImage.withSymbolConfiguration(config)
            iconView.contentTintColor = .secondaryLabelColor
        }
        containerView.addSubview(iconView)

        // Label
        let label = NSTextField(labelWithString: "Recording")
        label.frame = NSRect(x: 40, y: 5, width: 70, height: 20)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        containerView.addSubview(label)

        // Keyboard shortcut hint
        if !recordingShortcut.key.isEmpty {
            let shortcutLabel = NSTextField(labelWithString: recordingShortcut.displayString)
            shortcutLabel.font = NSFont.systemFont(ofSize: 13)
            shortcutLabel.textColor = .tertiaryLabelColor
            shortcutLabel.sizeToFit()
            let shortcutX = 40 + 70 + 2  // After the "Recording" label
            shortcutLabel.frame = NSRect(x: CGFloat(shortcutX), y: 5, width: shortcutLabel.frame.width, height: shortcutLabel.frame.height + 3)
            containerView.addSubview(shortcutLabel)
        }

        // Custom toggle switch view - positioned on the far right
        let toggleWidth: CGFloat = 40
        let rightPadding: CGFloat = 2
        let toggleView = RecordingToggleSwitch(
            frame: NSRect(x: containerWidth - toggleWidth - rightPadding, y: 5, width: toggleWidth, height: 20),
            isOn: isRecording,
            onColor: NSColor(red: 11/255.0, green: 51/255.0, blue: 108/255.0, alpha: 1.0)
        )
        toggleView.target = self
        toggleView.action = #selector(recordingToggleChanged(_:))
        containerView.addSubview(toggleView)

        recordingToggleContainerView = containerView
        recordingToggleControl = toggleView

        return containerView
    }

    /// Expands the custom recording row to match menu width and pins the toggle to the trailing edge.
    private func alignRecordingToggleToTrailingEdge(in menu: NSMenu) {
        guard let container = recordingToggleContainerView,
              let toggle = recordingToggleControl else { return }

        let targetWidth = max(container.frame.width, menu.size.width - 8)
        guard targetWidth > 0 else { return }

        var containerFrame = container.frame
        containerFrame.size.width = targetWidth
        container.frame = containerFrame

        var toggleFrame = toggle.frame
        let trailingPadding: CGFloat = 2
        toggleFrame.origin.x = targetWidth - toggleFrame.width - trailingPadding
        toggle.frame = toggleFrame
    }

    /// Handle recording toggle switch change
    @objc private func recordingToggleChanged(_ sender: Any) {
        guard let toggle = sender as? RecordingToggleSwitch else { return }
        let shouldRecord = toggle.state == .on

        clearScheduledResume()
        isPausedByUser = false

        // Update state and animate icon (using common run loop mode to work while menu is open)
        isRecording = shouldRecord
        animateIconFillWithCommonMode(toRecording: shouldRecord)
        refreshOpenRecordingControlsIfNeeded()

        // Then perform the actual operation in the background
        Task { @MainActor in
            do {
                if shouldRecord {
                    Log.debug("[MenuBar] Toggle ON - Starting pipeline...", category: .ui)
                    try await coordinator.startPipeline()
                    DashboardViewModel.recordRecordingStartedFromMenu(
                        coordinator: coordinator,
                        source: "menu_toggle"
                    )
                } else {
                    Log.debug("[MenuBar] Toggle OFF - Stopping pipeline...", category: .ui)
                    try await coordinator.stopPipeline()
                }
            } catch {
                Log.error("[MenuBar] Failed to toggle recording: \(error)", category: .ui)
                // Revert on error
                let actualState = coordinator.statusHolder.status.isRunning
                toggle.isOn = actualState
                isRecording = actualState
                updateIcon(recording: actualState)
                refreshOpenRecordingControlsIfNeeded()
            }
        }
    }

    /// Animate icon using common run loop mode (works while menu is open)
    private func animateIconFillWithCommonMode(toRecording: Bool) {
        iconAnimationTimer?.invalidate()

        let frameRate: TimeInterval = 1.0 / 60.0
        let pressDuration: TimeInterval = 0.10   // Press down (100ms)
        let releaseDuration: TimeInterval = 0.30  // Release (300ms)
        let pressFrames = Int(pressDuration / frameRate)
        let releaseFrames = Int(releaseDuration / frameRate)
        var currentFrame = 0
        var phase: Int = 0

        let startFilled = !toRecording
        let minScale: CGFloat = 0.3  // Shrink to 30% size

        // Use Timer with .common mode so it runs while menu is tracking
        let timer = Timer(timeInterval: frameRate, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            currentFrame += 1

            if phase == 0 {
                // Phase 0: Fast shrinking down
                let progress = CGFloat(currentFrame) / CGFloat(pressFrames)
                // Ease-in for snappy press feel
                let easedProgress = progress * progress
                let scale = 1.0 - ((1.0 - minScale) * easedProgress)

                if let button = self.statusItem?.button {
                    let image = self.createStatusIcon(style: startFilled ? .recording : .off, scale: scale)
                    button.image = image
                    button.image?.isTemplate = true
                }

                if currentFrame >= pressFrames {
                    phase = 1
                    currentFrame = 0
                }
            } else {
                // Phase 1: Slower expanding back with bounce
                let progress = CGFloat(currentFrame) / CGFloat(releaseFrames)
                // Ease-out for smooth release
                let easedProgress = 1.0 - pow(1.0 - progress, 3)
                let scale = minScale + ((1.0 - minScale) * easedProgress)

                if let button = self.statusItem?.button {
                    let image = self.createStatusIcon(style: toRecording ? .recording : .off, scale: scale)
                    button.image = image
                    button.image?.isTemplate = true
                }

                if currentFrame >= releaseFrames {
                    timer.invalidate()
                    self.iconFillProgress = toRecording ? 1.0 : 0.0
                }
            }
        }

        // Add to common run loop mode so it runs while menu is tracking
        RunLoop.main.add(timer, forMode: .common)
        iconAnimationTimer = timer
    }

    public func pauseRecording(for duration: TimeInterval?) async {
        clearScheduledResume()
        let wasRecording = coordinator.statusHolder.status.isRunning
        let isTimedPause = (duration ?? 0) > 0
        if wasRecording {
            // Timed pauses are treated as paused state; "Turn Off" is normal off state.
            isPausedByUser = isTimedPause
        }

        do {
            if wasRecording {
                Log.debug("[MenuBar] Pausing capture pipeline...", category: .ui)
                // Timed pause should come back ON after app relaunch; explicit "Turn Off" should persist OFF.
                try await coordinator.stopPipeline(persistState: !isTimedPause)

                if isTimedPause, let duration {
                    await MainActor.run {
                        DashboardViewModel.recordRecordingPauseSelected(
                            coordinator: coordinator,
                            source: "pause_menu",
                            durationSeconds: Int(duration)
                        )
                    }
                } else {
                    await MainActor.run {
                        DashboardViewModel.recordRecordingTurnedOff(
                            coordinator: coordinator,
                            source: "pause_menu"
                        )
                    }
                }
            }

            if wasRecording, isTimedPause, let duration {
                scheduleTimedResume(after: duration)
            }
        } catch {
            Log.error("[MenuBar] Failed to pause recording: \(error)", category: .ui)
        }

        syncWithCoordinator()
        updateIconForCurrentState()
    }

    private func startRecordingNow() async {
        clearScheduledResume()
        isPausedByUser = false
        do {
            try await coordinator.startPipeline()
            await MainActor.run {
                DashboardViewModel.recordRecordingStartedFromMenu(
                    coordinator: coordinator,
                    source: "status_menu_start"
                )
            }
        } catch {
            Log.error("[MenuBar] Failed to start recording: \(error)", category: .ui)
        }
        syncWithCoordinator()
    }

    private func clearScheduledResume(refreshMenu: Bool = true) {
        scheduledResumeTask?.cancel()
        scheduledResumeTask = nil

        if scheduledResumeDate != nil {
            scheduledResumeDate = nil
            if refreshMenu {
                setupMenu()
            }
        }
    }

    public func cancelScheduledResume() {
        clearScheduledResume()
    }

    private func scheduleTimedResume(after duration: TimeInterval) {
        guard duration > 0 else { return }

        let targetDate = Date().addingTimeInterval(duration)
        scheduledResumeDate = targetDate
        setupMenu()

        scheduledResumeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration), clock: .continuous)
            } catch {
                return
            }

            guard let self else { return }
            guard self.scheduledResumeDate == targetDate else { return }

            self.scheduledResumeDate = nil
            self.scheduledResumeTask = nil

            do {
                Log.info("[MenuBar] Timed pause ended - resuming capture", category: .ui)
                try await self.coordinator.startPipeline()
                DashboardViewModel.recordRecordingAutoResumed(
                    coordinator: self.coordinator,
                    source: "timed_pause",
                    pausedDurationSeconds: Int(duration)
                )
            } catch {
                Log.error("[MenuBar] Failed to auto-resume after timed pause: \(error)", category: .ui)
            }

            self.syncWithCoordinator()
            self.setupMenu()
        }
    }

    private func autoResumeSubtitle() -> String? {
        guard let remainingSeconds = timedPauseRemainingSeconds else { return nil }
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60

        if hours > 0 {
            return String(format: "Resumes in %d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "Resumes in %02d:%02d", minutes, seconds)
    }

    private func makeRecordingControlItems() -> [NSMenuItem] {
        autoResumeStatusItem = nil

        let recordingToggleItem = NSMenuItem()
        recordingToggleItem.view = createRecordingToggleView()
        var items: [NSMenuItem] = [recordingToggleItem]

        if isRecording {
            let pauseFor5Item = NSMenuItem(title: "Pause for 5 Minutes", action: #selector(pauseFor5Minutes), keyEquivalent: "")
            pauseFor5Item.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
            pauseFor5Item.target = self
            items.append(pauseFor5Item)

            let pauseFor30Item = NSMenuItem(title: "Pause for 30 Minutes", action: #selector(pauseFor30Minutes), keyEquivalent: "")
            pauseFor30Item.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
            pauseFor30Item.target = self
            items.append(pauseFor30Item)

            let pauseFor60Item = NSMenuItem(title: "Pause for 60 Minutes", action: #selector(pauseFor60Minutes), keyEquivalent: "")
            pauseFor60Item.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
            pauseFor60Item.target = self
            items.append(pauseFor60Item)
        } else if let subtitle = autoResumeSubtitle() {
            let resumeStatusItem = NSMenuItem(title: subtitle, action: nil, keyEquivalent: "")
            resumeStatusItem.isEnabled = false
            resumeStatusItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
            autoResumeStatusItem = resumeStatusItem
            items.append(resumeStatusItem)
        }

        return items
    }

    private func addRecordingControls(to menu: NSMenu) {
        for item in makeRecordingControlItems() {
            menu.addItem(item)
        }
    }

    /// Refresh only the recording-controls section while status menu is open.
    /// This keeps the menu visible and updates pause rows immediately after toggle changes.
    private func refreshOpenRecordingControlsIfNeeded() {
        guard let menu = statusItem?.menu else { return }

        let separatorIndices = menu.items.enumerated().compactMap { idx, item in
            item.isSeparatorItem ? idx : nil
        }
        guard separatorIndices.count >= 2 else { return }

        let firstSeparator = separatorIndices[0]
        let secondSeparator = separatorIndices[1]
        let insertionIndex = firstSeparator + 1

        if secondSeparator > insertionIndex {
            for _ in insertionIndex..<secondSeparator {
                menu.removeItem(at: insertionIndex)
            }
        }

        let refreshedItems = makeRecordingControlItems()
        for (offset, item) in refreshedItems.enumerated() {
            menu.insertItem(item, at: insertionIndex + offset)
        }

        alignRecordingToggleToTrailingEdge(in: menu)

        if autoResumeStatusItem != nil {
            startAutoResumeCountdownUpdates()
        } else {
            stopAutoResumeCountdownUpdates()
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        let visibleDashboardContent = visibleDashboardContentInFront()
        let primaryActions = Self.primaryActions(
            isDashboardFrontAndCenter: visibleDashboardContent == .dashboard,
            isSystemMonitorFrontAndCenter: visibleDashboardContent == .monitor
        )

        // Open Timeline
        let timelineItem = NSMenuItem(
            title: primaryActions.timeline.title,
            action: #selector(openTimeline),
            keyEquivalent: timelineShortcut.menuKeyEquivalent
        )
        timelineItem.keyEquivalentModifierMask = timelineShortcut.modifiers.nsModifiers
        timelineItem.image = NSImage(systemSymbolName: primaryActions.timeline.imageSystemName, accessibilityDescription: nil)
        menu.addItem(timelineItem)

        // Search Screen History
        let searchItem = NSMenuItem(
            title: primaryActions.search.title,
            action: #selector(openSearch),
            keyEquivalent: ""
        )
        searchItem.image = NSImage(systemSymbolName: primaryActions.search.imageSystemName, accessibilityDescription: nil)
        menu.addItem(searchItem)

        // Open Dashboard
        let dashboardItem = NSMenuItem(
            title: primaryActions.dashboard.title,
            action: visibleDashboardContent == .dashboard ? #selector(hideDashboardFromMenu) : #selector(openDashboard),
            keyEquivalent: dashboardShortcut.menuKeyEquivalent
        )
        dashboardItem.keyEquivalentModifierMask = dashboardShortcut.modifiers.nsModifiers
        dashboardItem.image = NSImage(systemSymbolName: primaryActions.dashboard.imageSystemName, accessibilityDescription: nil)
        menu.addItem(dashboardItem)

        // System Monitor
        let monitorItem = NSMenuItem(
            title: primaryActions.monitor.title,
            action: visibleDashboardContent == .monitor ? #selector(hideSystemMonitorFromMenu) : #selector(openSystemMonitor),
            keyEquivalent: systemMonitorShortcut.key.isEmpty ? "" : systemMonitorShortcut.menuKeyEquivalent
        )
        if !systemMonitorShortcut.key.isEmpty {
            monitorItem.keyEquivalentModifierMask = systemMonitorShortcut.modifiers.nsModifiers
        }
        monitorItem.image = NSImage(systemSymbolName: primaryActions.monitor.imageSystemName, accessibilityDescription: nil)
        menu.addItem(monitorItem)

        menu.addItem(NSMenuItem.separator())

        // Recording controls
        addRecordingControls(to: menu)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        // Check for updates
        let checkForUpdatesItem = NSMenuItem(
            title: UpdaterManager.shared.isCheckingForUpdates ? "Checking..." : "Check for Updates...",
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: ""
        )
        checkForUpdatesItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        checkForUpdatesItem.isEnabled = !UpdaterManager.shared.isCheckingForUpdates && UpdaterManager.shared.canCheckForUpdates
        menu.addItem(checkForUpdatesItem)

        // Changelog
        let changelogItem = NSMenuItem(
            title: "Changelog",
            action: #selector(openChangelog),
            keyEquivalent: ""
        )
        changelogItem.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: nil)
        menu.addItem(changelogItem)

        // Get Help
        let feedbackItem = NSMenuItem(
            title: "Get Help...",
            action: #selector(openFeedback),
            keyEquivalent: ""
        )
        feedbackItem.image = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: nil)
        menu.addItem(feedbackItem)

        menu.addItem(NSMenuItem.separator())

        // Version — clickable to open commit on GitHub (if available)
        let versionItem = NSMenuItem(
            title: "Retrace \(BuildInfo.displayVersion)",
            action: BuildInfo.commitURL != nil ? #selector(openCommitURL) : nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = BuildInfo.commitURL != nil
        menu.addItem(versionItem)

        // Branch on its own line for dev builds (keeps menu width reasonable)
        if let branch = BuildInfo.displayBranch {
            let branchItem = NSMenuItem()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            branchItem.attributedTitle = NSAttributedString(string: "  \(branch)", attributes: attrs)
            branchItem.isEnabled = false
            menu.addItem(branchItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Retrace",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        // Set all targets
        for item in menu.items {
            item.target = self
        }

        statusMenu = menu
    }

    /// Ensure both left-click and right-click open the status menu.
    private func configureStatusButtonClicks() {
        guard let button = statusItem?.button else {
            Log.error("[MenuBarLifecycle] cannot configure clicks: status button missing", category: .ui)
            return
        }
        button.target = self
        button.action = #selector(handleStatusButtonClick(_:))
        button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp])
        Log.debug("[MenuBarLifecycle] click handlers configured for left/right/other mouse down+up", category: .ui)
    }

    /// Adds a local monitor so right-click is still detected if NSStatusBarButton action dispatch misses it.
    private func setupStatusClickMonitors() {
        teardownStatusClickMonitors()

        localStatusClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]) { [weak self] event in
            self?.handleMonitoredStatusClick(event)
            return event
        }

        Log.debug("[MenuBarLifecycle] installed local secondary-click monitor", category: .ui)
    }

    private func teardownStatusClickMonitors() {
        if let localStatusClickMonitor {
            NSEvent.removeMonitor(localStatusClickMonitor)
            self.localStatusClickMonitor = nil
        }
    }

    /// Handle right/secondary click events from local monitor and open status menu if click lands on the menu bar button.
    private func handleMonitoredStatusClick(_ event: NSEvent) {
        guard Self.shouldOpenStatusMenu(for: event.type) else { return }
        guard let button = statusItem?.button else { return }
        guard isEventOnStatusButton(event, button: button) else { return }
        guard shouldOpenMenu(forEventTimestamp: event.timestamp) else { return }

        Log.debug(
            "[MenuBarLifecycle] local monitor captured secondary click type=\(String(describing: event.type)) button=\(event.buttonNumber) ts=\(event.timestamp)",
            category: .ui
        )

        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button else { return }
            self.showStatusMenu(from: button)
        }
    }

    /// Converts a local event location and checks whether it intersects the status bar button.
    private func isEventOnStatusButton(_ event: NSEvent, button: NSStatusBarButton) -> Bool {
        guard let window = button.window else { return false }

        let pointInWindow: NSPoint
        if event.window === window {
            pointInWindow = event.locationInWindow
        } else {
            pointInWindow = window.convertPoint(fromScreen: event.locationInWindow)
        }

        let pointInButton = button.convert(pointInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }

    /// De-duplicates down/up or monitor/action double-fires.
    private func shouldOpenMenu(forEventTimestamp eventTimestamp: TimeInterval?) -> Bool {
        guard let eventTimestamp else { return true }

        let delta = eventTimestamp - lastStatusMenuOpenEventTimestamp
        if delta >= 0, delta < 0.20 {
            Log.debug("[MenuBarLifecycle] duplicate click event ignored delta=\(String(format: "%.4f", delta))s", category: .ui)
            return false
        }

        lastStatusMenuOpenEventTimestamp = eventTimestamp
        return true
    }

    /// Determines whether the current event should trigger opening the menu.
    static func shouldOpenStatusMenu(for eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return true
        case nil:
            // Fallback to open menu when currentEvent is unavailable.
            return true
        default:
            return false
        }
    }

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let eventType = String(describing: event?.type)
        let buttonNumber = event.map { String($0.buttonNumber) } ?? "nil"
        let clickCount = event.map { String($0.clickCount) } ?? "nil"
        let eventTimestamp = event?.timestamp
        let isControlClick = event?.modifierFlags.contains(.control) == true

        Log.debug(
            "[MenuBarLifecycle] status button click received type=\(eventType) button=\(buttonNumber) clicks=\(clickCount) controlClick=\(isControlClick) ts=\(eventTimestamp.map { String($0) } ?? "nil")",
            category: .ui
        )

        guard Self.shouldOpenStatusMenu(for: event?.type) else {
            Log.debug("[MenuBarLifecycle] click ignored by event gate", category: .ui)
            return
        }

        guard shouldOpenMenu(forEventTimestamp: eventTimestamp) else { return }

        showStatusMenu(from: sender)
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        setupMenu()
        guard let menu = statusMenu, let statusItem else {
            Log.error("[MenuBarLifecycle] popup aborted: status menu is nil", category: .ui)
            return
        }
        alignRecordingToggleToTrailingEdge(in: menu)
        startAutoResumeCountdownUpdates()

        Log.debug(
            "[MenuBarLifecycle] opening status menu items=\(menu.items.count) via status-item attachment",
            category: .ui
        )

        // Present as a real status-item menu so it stays visually attached to the menu bar.
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
        stopAutoResumeCountdownUpdates()

        Log.debug("[MenuBarLifecycle] status menu closed", category: .ui)
    }

    private func startAutoResumeCountdownUpdates() {
        autoResumeCountdownTimer?.invalidate()
        autoResumeCountdownTimer = nil
        guard autoResumeStatusItem != nil else { return }

        autoResumeCountdownTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }

            guard let item = self.autoResumeStatusItem else {
                self.stopAutoResumeCountdownUpdates()
                return
            }

            if let subtitle = self.autoResumeSubtitle() {
                item.title = subtitle
            } else {
                self.stopAutoResumeCountdownUpdates()
            }
        }

        if let timer = autoResumeCountdownTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopAutoResumeCountdownUpdates() {
        autoResumeCountdownTimer?.invalidate()
        autoResumeCountdownTimer = nil
        autoResumeStatusItem = nil
    }

    // MARK: - Actions

    @objc private func openTimeline() {
        // Open the fullscreen timeline overlay
        toggleTimelineOverlay()
    }

    @objc private func openSearch() {
        // Open the timeline search overlay without resetting existing search state.
        Task { @MainActor in
            TimelineWindowController.shared.showSearchOverlay(source: "menu_bar_menu")
        }
    }

    @objc private func openDashboard() {
        Task { @MainActor in
            if TimelineWindowController.shared.isVisible {
                TimelineWindowController.shared.hideToShowDashboard()
            }
            DashboardWindowController.shared.showDashboard()
        }
    }

    @objc private func hideDashboardFromMenu() {
        Task { @MainActor in
            DashboardWindowController.shared.hide()
        }
    }

    @objc private func openChangelog() {
        Task { @MainActor in
            DashboardWindowController.shared.showChangelog()
        }
    }

    @objc private func openSystemMonitor() {
        NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
    }

    @objc private func hideSystemMonitorFromMenu() {
        NotificationCenter.default.post(name: .toggleSystemMonitor, object: nil)
    }

    @objc private func startRecordingFromMenu() {
        Task { @MainActor in
            await startRecordingNow()
        }
    }

    @objc private func pauseFor5Minutes() {
        applyPauseSelection(duration: 5 * 60)
    }

    @objc private func pauseFor30Minutes() {
        applyPauseSelection(duration: 30 * 60)
    }

    @objc private func pauseFor60Minutes() {
        applyPauseSelection(duration: 60 * 60)
    }

    @objc private func turnOffRecording() {
        applyPauseSelection(duration: nil)
    }

    /// Toggle system monitor from global hotkey - hides timeline if open, then toggles monitor view
    private func toggleSystemMonitor() {
        Task { @MainActor in
            if TimelineWindowController.shared.isVisible {
                TimelineWindowController.shared.hideToShowDashboard()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NotificationCenter.default.post(name: .toggleSystemMonitor, object: nil)
                }
            } else {
                NotificationCenter.default.post(name: .toggleSystemMonitor, object: nil)
            }
        }
    }

    /// Sync recording status with coordinator
    /// Uses thread-safe statusHolder to avoid actor hop and prevent task pile-up
    public func syncWithCoordinator() {
        // Read status directly from thread-safe holder - no actor hop needed
        let status = coordinator.statusHolder.status
        if status.isRunning {
            isPausedByUser = false
            if scheduledResumeDate != nil {
                clearScheduledResume(refreshMenu: false)
            }
        }
        if isRecording != status.isRunning {
            updateRecordingStatus(status.isRunning)
        } else {
            updateIconForCurrentState()
        }
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    @objc private func openFeedback() {
        Task { @MainActor in
            DashboardViewModel.recordHelpOpened(coordinator: coordinator, source: "menu_bar_menu")
        }
        NotificationCenter.default.post(name: .openFeedback, object: nil)
    }

    @objc private func checkForUpdatesFromMenu() {
        UpdaterManager.shared.checkForUpdates()
    }

    @objc private func openCommitURL() {
        if let url = BuildInfo.commitURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func applyPauseSelection(duration: TimeInterval?) {
        Task { @MainActor in
            await pauseRecording(for: duration)
        }
    }

    private enum VisibleDashboardContent {
        case dashboard
        case monitor
        case other
    }

    static func primaryActions(
        isDashboardFrontAndCenter: Bool,
        isSystemMonitorFrontAndCenter: Bool
    ) -> (
        timeline: PrimaryAction,
        search: PrimaryAction,
        dashboard: PrimaryAction,
        monitor: PrimaryAction
    ) {
        (
            timeline: (title: "Open Timeline", imageSystemName: "clock.arrow.circlepath"),
            search: (title: "Search Screen History", imageSystemName: "magnifyingglass"),
            dashboard: (
                title: isDashboardFrontAndCenter ? "Hide Dashboard" : "Open Dashboard",
                imageSystemName: "rectangle.3.group"
            ),
            monitor: (
                title: isSystemMonitorFrontAndCenter ? "Hide System Monitor" : "Open System Monitor",
                imageSystemName: "waveform.path.ecg"
            )
        )
    }

    private func visibleDashboardContentInFront() -> VisibleDashboardContent {
        guard NSApp.isActive else { return .other }

        let titles = [NSApp.keyWindow?.title, NSApp.mainWindow?.title]
        if titles.contains("Dashboard") {
            return .dashboard
        }
        if titles.contains("System Monitor") {
            return .monitor
        }
        return .other
    }

    // MARK: - Update

    public func updateRecordingStatus(_ recording: Bool) {
        let wasRecording = isRecording
        isRecording = recording
        if recording {
            isPausedByUser = false
        }
        setupMenu()

        // Animate only for true start/stop transitions; paused uses hatched static icon.
        if wasRecording != recording && !(wasRecording && !recording && isPausedByUser) {
            animateIconFill(toRecording: recording)
        } else {
            updateIconForCurrentState()
        }
    }

    /// Show the menu bar icon
    public func show() {
        isMenuBarIconEnabled = true
        DispatchQueue.main.async {
            if self.statusItem == nil {
                self.setup()
            }
        }
    }

    /// Hide the menu bar icon
    public func hide() {
        isMenuBarIconEnabled = false
        DispatchQueue.main.async {
            self.teardownStatusClickMonitors()
            if let item = self.statusItem {
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
            }
        }
    }

    // MARK: - Cleanup

    deinit {
        refreshTimer?.cancel()
        iconAnimationTimer?.invalidate()
        autoResumeCountdownTimer?.invalidate()
        scheduledResumeTask?.cancel()
        teardownStatusClickMonitors()
    }
}

// MARK: - Custom Toggle Switch

/// A custom toggle switch view with customizable on-color and animation
private class RecordingToggleSwitch: NSView {
    var isOn: Bool {
        didSet {
            if oldValue != isOn {
                animateToggle()
            }
        }
    }
    var onColor: NSColor
    weak var target: AnyObject?
    var action: Selector?

    private let trackWidth: CGFloat = 40
    private let trackHeight: CGFloat = 20
    private let knobDiameter: CGFloat = 16
    private let knobPadding: CGFloat = 2

    // Animation state
    private var knobProgress: CGFloat = 0.0  // 0.0 = off position, 1.0 = on position
    private var colorProgress: CGFloat = 0.0  // 0.0 = off color, 1.0 = on color
    private var animationTimer: Timer?

    init(frame: NSRect, isOn: Bool, onColor: NSColor) {
        self.isOn = isOn
        self.knobProgress = isOn ? 1.0 : 0.0
        self.colorProgress = isOn ? 1.0 : 0.0
        self.onColor = onColor
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func animateToggle() {
        animationTimer?.invalidate()

        let targetKnob: CGFloat = isOn ? 1.0 : 0.0
        let targetColor: CGFloat = isOn ? 1.0 : 0.0
        let duration: TimeInterval = 0.15
        let frameRate: TimeInterval = 1.0 / 60.0
        let totalFrames = Int(duration / frameRate)
        var currentFrame = 0

        let startKnob = knobProgress
        let startColor = colorProgress

        // Use Timer with .common mode so it runs while menu is tracking
        let timer = Timer(timeInterval: frameRate, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            currentFrame += 1
            let progress = CGFloat(currentFrame) / CGFloat(totalFrames)
            // Ease-out curve
            let easedProgress = 1.0 - pow(1.0 - progress, 3)

            self.knobProgress = startKnob + (targetKnob - startKnob) * easedProgress
            self.colorProgress = startColor + (targetColor - startColor) * easedProgress

            self.needsDisplay = true

            if currentFrame >= totalFrames {
                timer.invalidate()
                self.knobProgress = targetKnob
                self.colorProgress = targetColor
                self.needsDisplay = true
            }
        }

        // Add to common run loop mode so it runs while menu is tracking
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Draw track (pill shape)
        let trackRect = NSRect(
            x: (bounds.width - trackWidth) / 2,
            y: (bounds.height - trackHeight) / 2,
            width: trackWidth,
            height: trackHeight
        )

        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)

        // Interpolate color based on colorProgress
        let offColor = NSColor.systemGray.withAlphaComponent(0.4)
        let blendedColor = NSColor(
            red: offColor.redComponent + (onColor.redComponent - offColor.redComponent) * colorProgress,
            green: offColor.greenComponent + (onColor.greenComponent - offColor.greenComponent) * colorProgress,
            blue: offColor.blueComponent + (onColor.blueComponent - offColor.blueComponent) * colorProgress,
            alpha: offColor.alphaComponent + (onColor.alphaComponent - offColor.alphaComponent) * colorProgress
        )
        blendedColor.setFill()
        trackPath.fill()

        // Draw white border around track
        NSColor.white.withAlphaComponent(0.5).setStroke()
        trackPath.lineWidth = 1.0
        trackPath.stroke()

        // Draw knob (circle) - position based on knobProgress
        let offX = trackRect.minX + knobPadding
        let onX = trackRect.maxX - knobDiameter - knobPadding
        let knobX = offX + (onX - offX) * knobProgress
        let knobY = trackRect.minY + (trackHeight - knobDiameter) / 2

        let knobRect = NSRect(x: knobX, y: knobY, width: knobDiameter, height: knobDiameter)
        let knobPath = NSBezierPath(ovalIn: knobRect)

        // Add subtle shadow to knob
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        NSColor.white.setFill()
        knobPath.fill()
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        let nextState = !isOn
        isOn = nextState

        // Send action
        if let target = target, let action = action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    /// Property to check state (used by action handler)
    var state: NSControl.StateValue {
        return isOn ? .on : .off
    }

    deinit {
        animationTimer?.invalidate()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openTimeline = Notification.Name("openTimeline")
    static let openSearch = Notification.Name("openSearch")
    static let openDashboard = Notification.Name("openDashboard")
    static let toggleDashboard = Notification.Name("toggleDashboard")
    static let openSettings = Notification.Name("openSettings")
    static let openSettingsAppearance = Notification.Name("openSettingsAppearance")
    static let openSettingsPower = Notification.Name("openSettingsPower")
    static let openSettingsTags = Notification.Name("openSettingsTags")
    static let openSettingsPauseReminderInterval = Notification.Name("openSettingsPauseReminderInterval")
    static let openSettingsPowerOCRCard = Notification.Name("openSettingsPowerOCRCard")
    static let openSettingsPowerOCRPriority = Notification.Name("openSettingsPowerOCRPriority")
    static let openSettingsTimelineScrollOrientation = Notification.Name("openSettingsTimelineScrollOrientation")
    static let openFeedback = Notification.Name("openFeedback")
    static let openSystemMonitor = Notification.Name("openSystemMonitor")
    static let toggleSystemMonitor = Notification.Name("toggleSystemMonitor")
    static let dataSourceDidChange = Notification.Name("dataSourceDidChange")
}
