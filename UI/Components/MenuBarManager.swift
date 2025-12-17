import SwiftUI
import AppKit
import App

/// Manages the macOS menu bar icon and status menu
public class MenuBarManager: ObservableObject {

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private let coordinator: AppCoordinator

    @Published public var isRecording = false

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Setup

    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if statusItem?.button != nil {
            // Start with custom icon showing both indicators
            updateIcon(recording: false)
        }

        setupMenu()
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
        menu.addItem(NSMenuItem(
            title: "Open Timeline",
            action: #selector(openTimeline),
            keyEquivalent: "t"
        ))

        // Open Search
        menu.addItem(NSMenuItem(
            title: "Search",
            action: #selector(openSearch),
            keyEquivalent: "f"
        ))

        // Open Dashboard
        menu.addItem(NSMenuItem(
            title: "Dashboard",
            action: #selector(openDashboard),
            keyEquivalent: "d"
        ))

        menu.addItem(NSMenuItem.separator())

        // Start/Pause Recording
        let recordingItem = NSMenuItem(
            title: isRecording ? "Pause Recording" : "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: "r"
        )
        menu.addItem(recordingItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        menu.addItem(NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(
            title: "Quit Retrace",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        // Set all targets
        for item in menu.items {
            item.target = self
        }

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func openTimeline() {
        NotificationCenter.default.post(name: .openTimeline, object: nil)
    }

    @objc private func openSearch() {
        NotificationCenter.default.post(name: .openSearch, object: nil)
    }

    @objc private func openDashboard() {
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }

    @objc private func toggleRecording() {
        Task { @MainActor in
            do {
                // Check actual coordinator state first
                let coordinatorIsRunning = await coordinator.getStatus().isRunning

                if coordinatorIsRunning {
                    try await coordinator.stopPipeline()
                    updateRecordingStatus(false)
                } else {
                    try await coordinator.startPipeline()
                    updateRecordingStatus(true)
                }
            } catch {
                print("Failed to toggle recording: \(error)")
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Update

    public func updateRecordingStatus(_ recording: Bool) {
        isRecording = recording
        setupMenu()
        updateIcon(recording: recording)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openTimeline = Notification.Name("openTimeline")
    static let openSearch = Notification.Name("openSearch")
    static let openDashboard = Notification.Name("openDashboard")
    static let openSettings = Notification.Name("openSettings")
}
