import SwiftUI
import AppKit
import App
import Shared

/// Manages the macOS menu bar icon and status menu
public class MenuBarManager: ObservableObject {

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private let coordinator: AppCoordinator
    private let onboardingManager: OnboardingManager
    private var refreshTimer: Timer?

    @Published public var isRecording = false

    /// Tracks whether recording indicator should be hidden (e.g., when timeline is open)
    private var shouldHideRecordingIndicator = false

    /// Cached shortcuts (loaded from OnboardingManager)
    private var timelineShortcut: ShortcutConfig = .defaultTimeline
    private var dashboardShortcut: ShortcutConfig = .defaultDashboard

    // MARK: - Initialization

    public init(coordinator: AppCoordinator, onboardingManager: OnboardingManager) {
        self.coordinator = coordinator
        self.onboardingManager = onboardingManager
    }

    // MARK: - Setup

    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if statusItem?.button != nil {
            // Start with custom icon showing both indicators
            updateIcon(recording: false)
        }

        // Load shortcuts then setup menu and hotkeys
        Task { @MainActor in
            await loadShortcuts()
            setupMenu()
            setupTimelineNotifications()
            setupGlobalHotkey()
            setupAutoRefresh()
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
        TimelineWindowController.shared.configure(coordinator: coordinator)
    }

    /// Toggle the fullscreen timeline overlay
    private func toggleTimelineOverlay() {
        TimelineWindowController.shared.toggle()
    }

    /// Toggle the dashboard window
    private func toggleDashboard() {
        NotificationCenter.default.post(name: .openDashboard, object: nil)
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

    /// Create a custom status icon with two circles
    /// Left circle: Screen recording status
    /// Right circle: Could be used for audio/other features
    private func createStatusIcon(recording: Bool) -> NSImage {
        let size = NSSize(width: 24, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()

        // Left circle - Screen recording indicator
        let leftCircle = NSBezierPath(ovalIn: NSRect(x: 2, y: 4, width: 10, height: 10))
        if recording {
            NSColor.white.setFill()
            leftCircle.fill()
        } else {
            NSColor.white.setStroke()
            leftCircle.lineWidth = 1.5
            leftCircle.stroke()
        }

        // Right circle - Placeholder for future features (audio, etc.)
        // For now, just show outline
        let rightCircle = NSBezierPath(ovalIn: NSRect(x: 14, y: 4, width: 8, height: 8))
        NSColor.white.withAlphaComponent(0.5).setStroke()
        rightCircle.lineWidth = 1.0
        rightCircle.stroke()

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
        TimelineWindowController.shared.show()
        // The search panel will auto-show when timeline opens
    }

    @objc private func openDashboard() {
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }

    @objc private func toggleRecording() {
        Task { @MainActor in
            do {
                // Check actual coordinator state first
                let coordinatorIsRunning = await coordinator.getStatus().isRunning
                print("[MenuBar] toggleRecording called, coordinatorIsRunning=\(coordinatorIsRunning)")

                if coordinatorIsRunning {
                    print("[MenuBar] Stopping pipeline...")
                    try await coordinator.stopPipeline()
                    print("[MenuBar] Pipeline stopped, updating status to false")
                    updateRecordingStatus(false)
                } else {
                    print("[MenuBar] Starting pipeline...")
                    try await coordinator.startPipeline()
                    print("[MenuBar] Pipeline started, updating status to true")
                    updateRecordingStatus(true)
                }
            } catch {
                print("[MenuBar] Failed to toggle recording: \(error)")
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
        if statusItem == nil {
            setup()
        }
        statusItem?.isVisible = true
    }

    /// Hide the menu bar icon
    public func hide() {
        statusItem?.isVisible = false
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
    static let openSettings = Notification.Name("openSettings")
    static let openFeedback = Notification.Name("openFeedback")
}
