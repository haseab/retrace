import AppKit
import SwiftUI
import App
import Shared

/// Manages the system monitor window as an on-demand window
@MainActor
public class SystemMonitorWindowController: NSObject {

    // MARK: - Singleton

    public static let shared = SystemMonitorWindowController()

    // MARK: - Properties

    private(set) var window: NSWindow?
    private var coordinator: AppCoordinator?

    /// Whether the window is currently visible
    public private(set) var isVisible = false

    // MARK: - Initialization

    private override init() {
        super.init()
        setupNotifications()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .openSystemMonitor,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.show()
            }
        }
    }

    // MARK: - Configuration

    /// Configure with the app coordinator (call once during app launch)
    public func configure(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Show/Hide

    /// Show the system monitor window
    public func show() {
        // If window already exists and is visible, just bring it to front
        if let window = window, window.isVisible {
            bringToFront()
            return
        }

        guard let coordinator = coordinator else {
            Log.error("[SystemMonitorWindowController] Cannot show - coordinator not configured", category: .ui)
            return
        }

        // Create window if needed
        if window == nil {
            window = createWindow(coordinator: coordinator)
        }

        guard let window = window else { return }

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        isVisible = true
    }

    /// Hide the window
    public func hide() {
        guard let window = window, isVisible else {
            return
        }

        window.orderOut(nil)
        isVisible = false
    }

    /// Bring window to front if visible
    public func bringToFront() {
        guard let window = window else { return }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - Window Creation

    private func createWindow(coordinator: AppCoordinator) -> NSWindow {
        let content = SystemMonitorView(coordinator: coordinator)
        let hostingController = NSHostingController(rootView: content)

        let window = NSWindow(contentViewController: hostingController)

        window.title = "System Monitor"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 500, height: 500))
        window.minSize = NSSize(width: 500, height: 500)
        window.maxSize = NSSize(width: 500, height: 500)
        window.center()

        window.level = .normal
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.backgroundColor = NSColor(named: "retraceBackground") ?? NSColor.windowBackgroundColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        window.delegate = self

        return window
    }
}

// MARK: - NSWindowDelegate

extension SystemMonitorWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}
