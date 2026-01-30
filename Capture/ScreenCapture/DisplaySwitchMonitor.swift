import Foundation
import AppKit
import ApplicationServices
import Shared

/// Monitors active window changes and detects when user switches to a different display
/// Uses NSWorkspace notifications and Accessibility API for real-time detection
actor DisplaySwitchMonitor {

    // MARK: - Properties

    private let displayMonitor: DisplayMonitor
    private var currentDisplayID: UInt32?
    private var notificationTask: Task<Void, Never>?
    private var axObserver: AXObserver?
    private var observedApp: NSRunningApplication?

    /// Callback when display switch is detected
    nonisolated(unsafe) var onDisplaySwitch: (@Sendable (UInt32, UInt32) async -> Void)?

    /// Callback when accessibility permission is denied
    nonisolated(unsafe) var onAccessibilityPermissionDenied: (@Sendable () async -> Void)?

    // MARK: - Initialization

    init(displayMonitor: DisplayMonitor) {
        self.displayMonitor = displayMonitor
    }

    // MARK: - Lifecycle

    /// Start monitoring for display switches
    func startMonitoring(initialDisplayID: UInt32) {
        self.currentDisplayID = initialDisplayID

        // Start listening to workspace notifications on main actor
        notificationTask = Task { @MainActor in
            let center = NSWorkspace.shared.notificationCenter

            // Set up initial AX observer for frontmost app
            await self.setupAXObserverForFrontmostApp()

            // Observe when user switches to a different application
            for await _ in center.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                await self.checkForDisplaySwitch()
                // Re-setup AX observer for the new frontmost app
                await self.setupAXObserverForFrontmostApp()
            }
        }
    }

    /// Stop monitoring
    func stopMonitoring() async {
        notificationTask?.cancel()
        notificationTask = nil
        currentDisplayID = nil
        await removeCurrentAXObserver()
    }

    // MARK: - Accessibility Observer

    /// Set up AX observer for the frontmost application to detect window moves
    private func setupAXObserverForFrontmostApp() async {
        // Remove existing observer first
        await removeCurrentAXObserver()

        // Get frontmost app on main actor
        let app: NSRunningApplication? = await MainActor.run {
            NSWorkspace.shared.frontmostApplication
        }

        guard let app = app else { return }

        let pid = app.processIdentifier
        var observer: AXObserver?

        // Create observer
        let result = AXObserverCreate(pid, { (observer, element, notification, refcon) in
            // Callback when window moved or focused window changed
            guard let refcon = refcon else { return }
            let monitor = Unmanaged<DisplaySwitchMonitorRef>.fromOpaque(refcon).takeUnretainedValue()
            Task {
                await monitor.monitor.checkForDisplaySwitch()
            }
        }, &observer)

        guard result == .success, let observer = observer else {
            Log.warning("[DisplaySwitchMonitor] Failed to create AX observer for \(app.localizedName ?? "unknown")", category: .capture)
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Create ref wrapper to pass self to callback
        let refWrapper = DisplaySwitchMonitorRef(monitor: self)
        let refPtr = Unmanaged.passRetained(refWrapper).toOpaque()

        // Add notifications for window moved and focused window changed
        AXObserverAddNotification(observer, appElement, kAXMovedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refPtr)

        // Add observer to run loop on main actor
        await MainActor.run {
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }

        self.axObserver = observer
        self.observedApp = app

        Log.debug("[DisplaySwitchMonitor] AX observer set up for \(app.localizedName ?? "unknown")", category: .capture)
    }

    /// Remove the current AX observer
    private func removeCurrentAXObserver() async {
        if let observer = self.axObserver {
            await MainActor.run {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        self.axObserver = nil
        self.observedApp = nil
    }

    // MARK: - Private Methods

    /// Check if the active window is on a different display
    private func checkForDisplaySwitch() async {
        guard let currentDisplay = currentDisplayID else { return }

        // Get the active display ID
        let (newDisplayID, hasAXPermission) = await displayMonitor.getActiveDisplayIDWithPermissionStatus()

        // Check if AX permission was denied
        if !hasAXPermission {
            if let callback = onAccessibilityPermissionDenied {
                await callback()
            }
            // Continue with current display even if AX is denied
            return
        }

        // If display changed, notify
        if newDisplayID != currentDisplay {
            // logger.info("Display switch detected: \(currentDisplay) → \(newDisplayID)")
            currentDisplayID = newDisplayID
            if let callback = onDisplaySwitch {
                await callback(currentDisplay, newDisplayID)
            }
        }
    }

    /// Get current display ID
    func getCurrentDisplayID() -> UInt32? {
        currentDisplayID
    }
}

// MARK: - Helper for AX Callback

/// Reference wrapper to pass DisplaySwitchMonitor to AX callback
private final class DisplaySwitchMonitorRef: @unchecked Sendable {
    let monitor: DisplaySwitchMonitor

    init(monitor: DisplaySwitchMonitor) {
        self.monitor = monitor
    }
}
