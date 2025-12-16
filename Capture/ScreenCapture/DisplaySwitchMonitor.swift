import Foundation
import AppKit
import Shared

/// Monitors active window changes and detects when user switches to a different display
/// Uses NSWorkspace notifications for real-time detection
actor DisplaySwitchMonitor {

    // MARK: - Properties

    private let displayMonitor: DisplayMonitor
    private var currentDisplayID: UInt32?
    private var notificationTask: Task<Void, Never>?

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

            // Observe when user switches to a different application
            for await _ in center.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                await self.checkForDisplaySwitch()
            }
        }
    }

    /// Stop monitoring
    func stopMonitoring() {
        notificationTask?.cancel()
        notificationTask = nil
        currentDisplayID = nil
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
