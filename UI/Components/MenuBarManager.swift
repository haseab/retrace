import SwiftUI
import AppKit
import App
import Shared

/// Manages the macOS menu bar icon and status menu
public class MenuBarManager: ObservableObject {

    // MARK: - Shared Instance

    /// Shared instance for accessing from Settings and other views
    public static var shared: MenuBarManager?

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private let coordinator: AppCoordinator
    private let onboardingManager: OnboardingManager
    private var refreshTimer: Timer?

    @Published public var isRecording = false

    /// Tracks whether recording indicator should be hidden (e.g., when timeline is open)
    private var shouldHideRecordingIndicator = false

    /// Tracks whether the menu bar icon should be visible (user preference)
    private var isMenuBarIconEnabled = true

    /// Cached shortcuts (loaded from OnboardingManager)
    private var timelineShortcut: ShortcutConfig = .defaultTimeline
    private var dashboardShortcut: ShortcutConfig = .defaultDashboard

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
            setupGlobalHotkey()
            setupAutoRefresh()
            // Sync with coordinator to get current recording state
            syncWithCoordinator()
        }
    }

    /// Setup timer to auto-refresh recording status
    private func setupAutoRefresh() {
        // Sync recording status every 2 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.syncWithCoordinator()
        }
        // Also sync immediately
        syncWithCoordinator()
    }

    /// Load shortcuts from OnboardingManager
    private func loadShortcuts() async {
        timelineShortcut = await onboardingManager.timelineShortcut
        dashboardShortcut = await onboardingManager.dashboardShortcut
        Log.info("[MenuBarManager] Loaded shortcuts - Timeline: \(timelineShortcut.displayString), Dashboard: \(dashboardShortcut.displayString)", category: .ui)
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

        // Register timeline global hotkey
        HotkeyManager.shared.registerHotkey(
            key: timelineShortcut.key,
            modifiers: timelineShortcut.modifiers.nsModifiers
        ) { [weak self] in
            self?.toggleTimelineOverlay()
        }

        // Register dashboard global hotkey
        HotkeyManager.shared.registerHotkey(
            key: dashboardShortcut.key,
            modifiers: dashboardShortcut.modifiers.nsModifiers
        ) { [weak self] in
            self?.toggleDashboard()
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

    /// Update the menu bar icon to show recording status
    private func updateIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }

        // Create custom image with two circles (like Rewind)
        let image = createStatusIcon(recording: recording)
        button.image = image
        button.image?.isTemplate = true
    }

    /// Create a custom status icon with two triangles (Retrace logo)
    /// Left triangle: Points left, filled when recording, outlined otherwise
    /// Right triangle: Points right, always outlined
    private func createStatusIcon(recording: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()

        // Triangle dimensions (matching logo proportions)
        let triangleHeight: CGFloat = 12
        let triangleWidth: CGFloat = 8
        let verticalCenter: CGFloat = size.height / 2
        let gap: CGFloat = 3.0 // Gap between triangles

        // Left triangle - Points left ◁ (recording indicator)
        let leftTriangle = NSBezierPath()
        let leftTip: CGFloat = 2
        let leftBase: CGFloat = leftTip + triangleWidth
        leftTriangle.move(to: NSPoint(x: leftTip, y: verticalCenter)) // Left tip
        leftTriangle.line(to: NSPoint(x: leftBase, y: verticalCenter - triangleHeight / 2)) // Top right
        leftTriangle.line(to: NSPoint(x: leftBase, y: verticalCenter + triangleHeight / 2)) // Bottom right
        leftTriangle.close()

        if recording {
            // Filled when recording
            NSColor.white.setFill()
            leftTriangle.fill()
        } else {
            // Outlined when not recording
            NSColor.white.setStroke()
            leftTriangle.lineWidth = 1.2
            leftTriangle.stroke()
        }

        // Right triangle - Points right ▷ (always outlined)
        let rightTriangle = NSBezierPath()
        let rightBase: CGFloat = leftBase + gap
        let rightTip: CGFloat = rightBase + triangleWidth
        rightTriangle.move(to: NSPoint(x: rightTip, y: verticalCenter)) // Right tip
        rightTriangle.line(to: NSPoint(x: rightBase, y: verticalCenter - triangleHeight / 2)) // Top left
        rightTriangle.line(to: NSPoint(x: rightBase, y: verticalCenter + triangleHeight / 2)) // Bottom left
        rightTriangle.close()

        NSColor.white.setStroke()
        rightTriangle.lineWidth = 1.2
        rightTriangle.stroke()

        image.unlockFocus()
        return image
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
        menu.addItem(timelineItem)

        // Open Dashboard
        let dashboardItem = NSMenuItem(
            title: "Dashboard",
            action: #selector(openDashboard),
            keyEquivalent: dashboardShortcut.menuKeyEquivalent
        )
        dashboardItem.keyEquivalentModifierMask = dashboardShortcut.modifiers.nsModifiers
        menu.addItem(dashboardItem)

        menu.addItem(NSMenuItem.separator())

        // Start/Pause Recording
        let recordingItem = NSMenuItem(
            title: isRecording ? "Pause Recording" : "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: "r"
        )
        recordingItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(recordingItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        // Report an Issue / Get Help
        let feedbackItem = NSMenuItem(
            title: "Report an Issue...",
            action: #selector(openFeedback),
            keyEquivalent: ""
        )
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

    @objc private func toggleRecording() {
        Task { @MainActor in
            do {
                // Check actual coordinator state first
                let coordinatorIsRunning = await coordinator.getStatus().isRunning
                Log.debug("[MenuBar] toggleRecording called, coordinatorIsRunning=\(coordinatorIsRunning)", category: .ui)

                if coordinatorIsRunning {
                    Log.debug("[MenuBar] Stopping pipeline...", category: .ui)
                    try await coordinator.stopPipeline()
                    Log.debug("[MenuBar] Pipeline stopped, updating status to false", category: .ui)
                    updateRecordingStatus(false)
                } else {
                    Log.debug("[MenuBar] Starting pipeline...", category: .ui)
                    try await coordinator.startPipeline()
                    Log.debug("[MenuBar] Pipeline started, updating status to true", category: .ui)
                    updateRecordingStatus(true)
                }
            } catch {
                Log.error("[MenuBar] Failed to toggle recording: \(error)", category: .ui)
                // Sync state with coordinator on error
                let actualState = await coordinator.getStatus().isRunning
                updateRecordingStatus(actualState)
            }
        }
    }

    /// Sync recording status with coordinator
    public func syncWithCoordinator() {
        Task { @MainActor in
            let status = await coordinator.getStatus()
            if isRecording != status.isRunning {
                updateRecordingStatus(status.isRunning)
            }
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
        isRecording = recording
        setupMenu()
        updateIcon(recording: recording)
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
        refreshTimer?.invalidate()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openTimeline = Notification.Name("openTimeline")
    static let openSearch = Notification.Name("openSearch")
    static let openDashboard = Notification.Name("openDashboard")
    static let toggleDashboard = Notification.Name("toggleDashboard")
    static let openSettings = Notification.Name("openSettings")
    static let openFeedback = Notification.Name("openFeedback")
    static let dataSourceDidChange = Notification.Name("dataSourceDidChange")
}
