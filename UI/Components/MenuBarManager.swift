import SwiftUI
import AppKit
import App
import Shared
import Dispatch

/// Manages the macOS menu bar icon and status menu
public class MenuBarManager: ObservableObject {

    // MARK: - Shared Instance

    /// Shared instance for accessing from Settings and other views
    public static var shared: MenuBarManager?

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private let coordinator: AppCoordinator
    private let onboardingManager: OnboardingManager
    private var refreshTimer: DispatchSourceTimer?

    @Published public var isRecording = false

    /// Tracks whether recording indicator should be hidden (e.g., when timeline is open)
    private var shouldHideRecordingIndicator = false

    /// Tracks whether the menu bar icon should be visible (user preference)
    private var isMenuBarIconEnabled = true

    /// Cached shortcuts (loaded from OnboardingManager)
    private var timelineShortcut: ShortcutConfig = .defaultTimeline
    private var dashboardShortcut: ShortcutConfig = .defaultDashboard
    private var recordingShortcut: ShortcutConfig = .defaultRecording

    /// Timer for icon fill animation
    private var iconAnimationTimer: Timer?
    /// Current fill progress for icon animation (0.0 to 1.0)
    private var iconFillProgress: CGFloat = 0.0

    // MARK: - Initialization

    public init(coordinator: AppCoordinator, onboardingManager: OnboardingManager) {
        self.coordinator = coordinator
        self.onboardingManager = onboardingManager
        MenuBarManager.shared = self
    }

    // MARK: - Setup

    public func setup() {
        // Don't create status item if menu bar icon is disabled
        guard isMenuBarIconEnabled else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if statusItem?.button != nil {
            // Start with icon showing current recording state
            updateIcon(recording: isRecording)
        }

        // Load shortcuts then setup menu and hotkeys
        Task { @MainActor in
            await loadShortcuts()
            setupMenu()
            setupTimelineNotifications()

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
        Log.info("[MenuBarManager] Loaded shortcuts - Timeline: \(timelineShortcut.displayString), Dashboard: \(dashboardShortcut.displayString), Recording: \(recordingShortcut.displayString)", category: .ui)
    }

    /// Reload shortcuts from storage and re-register hotkeys (called from Settings)
    public func reloadShortcuts() {
        Task { @MainActor in
            await loadShortcuts()
            setupGlobalHotkey()
            setupMenu()
        }
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
                modifiers: timelineShortcut.modifiers.nsModifiers
            ) { [weak self] in
                self?.toggleTimelineOverlay()
            }
        }

        // Register dashboard global hotkey (skip if cleared)
        if !dashboardShortcut.key.isEmpty {
            HotkeyManager.shared.registerHotkey(
                key: dashboardShortcut.key,
                modifiers: dashboardShortcut.modifiers.nsModifiers
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

        // Also configure the timeline window controller
        Task { @MainActor in
            TimelineWindowController.shared.configure(coordinator: coordinator)
        }
    }

    /// Toggle the fullscreen timeline overlay
    private func toggleTimelineOverlay() {
        Task { @MainActor in
            TimelineWindowController.shared.toggle()
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
                let currentlyRecording = await coordinator.getStatus().isRunning
                let shouldRecord = !currentlyRecording

                // Update state and animate icon
                isRecording = shouldRecord
                animateIconFill(toRecording: shouldRecord)

                if shouldRecord {
                    Log.debug("[MenuBar] Hotkey toggle ON - Starting pipeline...", category: .ui)
                    try await coordinator.startPipeline()
                } else {
                    Log.debug("[MenuBar] Hotkey toggle OFF - Stopping pipeline...", category: .ui)
                    try await coordinator.stopPipeline()
                }
            } catch {
                Log.error("[MenuBar] Failed to toggle recording via hotkey: \(error)", category: .ui)
                // Revert on error
                let actualState = await coordinator.getStatus().isRunning
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
        updateIcon(recording: isRecording)
    }

    /// Update the menu bar icon to show recording status (no animation)
    private func updateIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }

        let image = createStatusIcon(filled: recording)
        button.image = image
        button.image?.isTemplate = true
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
                    let image = self.createStatusIcon(filled: startFilled, scale: scale)
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
                    let image = self.createStatusIcon(filled: toRecording, scale: scale)
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
    /// Left triangle: Points left, filled or outlined based on state, with optional scale
    /// Right triangle: Points right, always outlined
    private func createStatusIcon(filled: Bool, scale: CGFloat = 1.0) -> NSImage {
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

        if filled {
            // Filled when recording (no border)
            NSColor.white.setFill()
            leftTriangle.fill()
        } else {
            // Outlined when not recording
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
        label.frame = NSRect(x: 40, y: 5, width: 100, height: 20)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        containerView.addSubview(label)

        // Custom toggle switch view - positioned on the far right
        let toggleWidth: CGFloat = 40
        let rightPadding: CGFloat = 8
        let toggleView = RecordingToggleSwitch(
            frame: NSRect(x: containerWidth - toggleWidth - rightPadding, y: 5, width: toggleWidth, height: 20),
            isOn: isRecording,
            onColor: NSColor(red: 11/255.0, green: 51/255.0, blue: 108/255.0, alpha: 1.0)
        )
        toggleView.target = self
        toggleView.action = #selector(recordingToggleChanged(_:))
        containerView.addSubview(toggleView)

        return containerView
    }

    /// Handle recording toggle switch change
    @objc private func recordingToggleChanged(_ sender: Any) {
        guard let toggle = sender as? RecordingToggleSwitch else { return }
        let shouldRecord = toggle.state == .on

        // Update state and animate icon (using common run loop mode to work while menu is open)
        isRecording = shouldRecord
        animateIconFillWithCommonMode(toRecording: shouldRecord)

        // Then perform the actual operation in the background
        Task { @MainActor in
            do {
                if shouldRecord {
                    Log.debug("[MenuBar] Toggle ON - Starting pipeline...", category: .ui)
                    try await coordinator.startPipeline()
                } else {
                    Log.debug("[MenuBar] Toggle OFF - Stopping pipeline...", category: .ui)
                    try await coordinator.stopPipeline()
                }
            } catch {
                Log.error("[MenuBar] Failed to toggle recording: \(error)", category: .ui)
                // Revert on error
                let actualState = await coordinator.getStatus().isRunning
                toggle.isOn = actualState
                isRecording = actualState
                updateIcon(recording: actualState)
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
                    let image = self.createStatusIcon(filled: startFilled, scale: scale)
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
                    let image = self.createStatusIcon(filled: toRecording, scale: scale)
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

    private func setupMenu() {
        let menu = NSMenu()

        // Status
        let statusMenuItem = NSMenuItem(
            title: isRecording ? "Recording..." : "Paused",
            action: nil,
            keyEquivalent: ""
        )
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Open Timeline
        let timelineItem = NSMenuItem(
            title: "Open Timeline",
            action: #selector(openTimeline),
            keyEquivalent: timelineShortcut.menuKeyEquivalent
        )
        timelineItem.keyEquivalentModifierMask = timelineShortcut.modifiers.nsModifiers
        timelineItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        menu.addItem(timelineItem)

        // Open Dashboard
        let dashboardItem = NSMenuItem(
            title: "Dashboard",
            action: #selector(openDashboard),
            keyEquivalent: dashboardShortcut.menuKeyEquivalent
        )
        dashboardItem.keyEquivalentModifierMask = dashboardShortcut.modifiers.nsModifiers
        dashboardItem.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        menu.addItem(dashboardItem)

        // System Monitor
        let monitorItem = NSMenuItem(
            title: "System Monitor",
            action: #selector(openSystemMonitor),
            keyEquivalent: ""
        )
        monitorItem.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        menu.addItem(monitorItem)

        menu.addItem(NSMenuItem.separator())

        // Recording toggle with switch
        let recordingItem = NSMenuItem()
        let recordingView = createRecordingToggleView()
        recordingItem.view = recordingView
        menu.addItem(recordingItem)

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

        // Report an Issue / Get Help
        let feedbackItem = NSMenuItem(
            title: "Report an Issue...",
            action: #selector(openFeedback),
            keyEquivalent: ""
        )
        feedbackItem.image = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: nil)
        menu.addItem(feedbackItem)

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

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func openTimeline() {
        // Open the fullscreen timeline overlay
        toggleTimelineOverlay()
    }

    @objc private func openSearch() {
        // Open timeline with search focused
        Task { @MainActor in
            TimelineWindowController.shared.show()
        }
        // The search panel will auto-show when timeline opens
    }

    @objc private func openDashboard() {
        NotificationCenter.default.post(name: .toggleDashboard, object: nil)
    }

    @objc private func openSystemMonitor() {
        NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
    }

    /// Sync recording status with coordinator
    /// Uses thread-safe statusHolder to avoid actor hop and prevent task pile-up
    public func syncWithCoordinator() {
        // Read status directly from thread-safe holder - no actor hop needed
        let status = coordinator.statusHolder.status
        if isRecording != status.isRunning {
            updateRecordingStatus(status.isRunning)
        }
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    @objc private func openFeedback() {
        NotificationCenter.default.post(name: .openFeedback, object: nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Update

    public func updateRecordingStatus(_ recording: Bool) {
        let wasRecording = isRecording
        isRecording = recording
        setupMenu()

        // Animate the icon fill if the state actually changed
        if wasRecording != recording {
            animateIconFill(toRecording: recording)
        } else {
            updateIcon(recording: recording)
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
        isOn.toggle()

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
    static let openFeedback = Notification.Name("openFeedback")
    static let openSystemMonitor = Notification.Name("openSystemMonitor")
    static let dataSourceDidChange = Notification.Name("dataSourceDidChange")
}
