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
    private var refWrapper: DisplaySwitchMonitorRef?

    /// Callback when display switch is detected
    nonisolated(unsafe) var onDisplaySwitch: (@Sendable (UInt32, UInt32) async -> Void)?

    /// Callback when accessibility permission is denied
    nonisolated(unsafe) var onAccessibilityPermissionDenied: (@Sendable () async -> Void)?

    /// Callback when active window changes (app switch or window focus change within app)
    /// Fires for immediate capture when captureOnWindowChange is enabled
    nonisolated(unsafe) var onWindowChange: (@Sendable () async -> Void)?

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
                // Notify window change for immediate capture (app switch)
                if let callback = self.onWindowChange {
                    await callback()
                }
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
    /// Uses safe wrappers to prevent crashes if permissions are revoked
    private func setupAXObserverForFrontmostApp() async {
        // Remove existing observer first
        await removeCurrentAXObserver()

        // Check permission before attempting any AX operations
        guard PermissionMonitor.shared.hasAccessibilityPermission() else {
            if let callback = onAccessibilityPermissionDenied {
                await callback()
            }
            return
        }

        // Get frontmost app on main actor
        let app: NSRunningApplication? = await MainActor.run {
            NSWorkspace.shared.frontmostApplication
        }

        guard let app = app else {
            return
        }

        let pid = app.processIdentifier

        // Use safe wrapper to create observer
        guard let observer = PermissionMonitor.shared.safeCreateAXObserver(
            pid: pid,
            callback: { (observer, element, notification, refcon) in
                // Callback when window moved or focused window changed
                guard let refcon = refcon else { return }
                let monitor = Unmanaged<DisplaySwitchMonitorRef>.fromOpaque(refcon).takeUnretainedValue()
                Task {
                    await monitor.monitor.handleWindowChangeFromAX()
                }
            }
        ) else {
            Log.warning("[DisplaySwitchMonitor] Failed to create AX observer for \(app.localizedName ?? "unknown") - permission may have been revoked", category: .capture)
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Create ref wrapper to pass self to callback
        // Store it in the actor so it doesn't get deallocated
        let wrapper = DisplaySwitchMonitorRef(monitor: self)
        self.refWrapper = wrapper
        let refPtr = Unmanaged.passUnretained(wrapper).toOpaque()

        // Add notifications for window moved, focused window changed, and title changed
        // These may fail if permission is revoked mid-setup, but won't crash
        AXObserverAddNotification(observer, appElement, kAXMovedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appElement, kAXTitleChangedNotification as CFString, refPtr)

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
        self.refWrapper = nil
    }

    // MARK: - Private Methods

    /// Handle window change from AX observer (window focus change within app)
    /// Triggers immediate capture callback and then checks for display switch
    func handleWindowChangeFromAX() async {
        // Check permission first - if revoked, clean up and notify
        guard PermissionMonitor.shared.hasAccessibilityPermission() else {
            Log.warning("[DisplaySwitchMonitor] AX callback received but permission revoked - cleaning up", category: .capture)
            await removeCurrentAXObserver()
            if let callback = onAccessibilityPermissionDenied {
                await callback()
            }
            return
        }

        // Notify window change for immediate capture
        if let callback = onWindowChange {
            await callback()
        }
        // Then check for display switch
        await checkForDisplaySwitch()
    }

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
