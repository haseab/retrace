import Foundation
import AppKit
import ApplicationServices
import Shared

/// Monitors system permissions and notifies when they change
/// Provides safe wrappers for permission-sensitive API calls
public actor PermissionMonitor {

    // MARK: - Singleton

    public static let shared = PermissionMonitor()

    // MARK: - Properties

    private var isMonitoring = false
    private var monitorTask: Task<Void, Never>?
    private var lastAccessibilityStatus = false
    private var lastScreenRecordingStatus = false

    /// Callback when accessibility permission is revoked while app is running
    nonisolated(unsafe) public var onAccessibilityRevoked: (@Sendable () async -> Void)?

    /// Callback when screen recording permission is revoked while app is running
    nonisolated(unsafe) public var onScreenRecordingRevoked: (@Sendable () async -> Void)?

    /// Callback when any permission is revoked (for UI alerts)
    nonisolated(unsafe) public var onPermissionRevoked: (@Sendable (_ permission: String) async -> Void)?

    // MARK: - Cached Permission Status

    /// Cached accessibility permission status (updated by monitoring loop)
    /// Using nonisolated(unsafe) for fast access without actor hop
    private nonisolated(unsafe) var _cachedAccessibilityStatus: Bool = false
    private nonisolated(unsafe) var _cachedScreenRecordingStatus: Bool = false
    private nonisolated(unsafe) var _hasCachedStatus: Bool = false

    // MARK: - Permission Checking (Safe Wrappers)

    /// Check accessibility permission without prompting
    /// Returns cached value for performance - updated every 2 seconds by monitor
    public nonisolated func hasAccessibilityPermission() -> Bool {
        // If we have a cached status, use it (fast path)
        if _hasCachedStatus {
            return _cachedAccessibilityStatus
        }
        // First call or monitoring not started - do actual check
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let result = AXIsProcessTrustedWithOptions(options as CFDictionary)
        _cachedAccessibilityStatus = result
        _hasCachedStatus = true
        return result
    }

    /// Check screen recording permission
    /// Returns cached value for performance - updated every 2 seconds by monitor
    public nonisolated func hasScreenRecordingPermission() -> Bool {
        // If we have a cached status, use it (fast path)
        if _hasCachedStatus {
            return _cachedScreenRecordingStatus
        }
        // First call or monitoring not started - do actual check
        let result = CGPreflightScreenCaptureAccess()
        _cachedScreenRecordingStatus = result
        _hasCachedStatus = true
        return result
    }

    /// Force refresh the cached permission status (call after permission changes)
    public nonisolated func refreshCachedStatus() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        _cachedAccessibilityStatus = AXIsProcessTrustedWithOptions(options as CFDictionary)
        _cachedScreenRecordingStatus = CGPreflightScreenCaptureAccess()
        _hasCachedStatus = true
    }

    // MARK: - Safe AX API Wrappers

    /// Safely create an AX observer, returning nil if permissions are revoked
    /// This prevents crashes when permissions change mid-operation
    public nonisolated func safeCreateAXObserver(
        pid: pid_t,
        callback: @escaping AXObserverCallback
    ) -> AXObserver? {
        // Check permission first
        guard hasAccessibilityPermission() else {
            Log.warning("[PermissionMonitor] Cannot create AX observer - accessibility permission denied", category: .capture)
            return nil
        }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, callback, &observer)

        if result != .success {
            Log.warning("[PermissionMonitor] AXObserverCreate failed with error: \(result.rawValue)", category: .capture)
            return nil
        }

        return observer
    }

    /// Safely get an attribute value from an AX element
    /// Returns nil if permission is denied or the call fails
    public nonisolated func safeGetAttribute<T>(
        element: AXUIElement,
        attribute: String
    ) -> T? {
        // Quick permission check
        guard hasAccessibilityPermission() else {
            return nil
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        switch result {
        case .success:
            return value as? T
        case .apiDisabled, .notImplemented:
            // Permission was revoked
            Log.warning("[PermissionMonitor] AX API disabled or not implemented for attribute: \(attribute)", category: .capture)
            return nil
        case .noValue, .attributeUnsupported:
            // Normal cases where value doesn't exist
            return nil
        case .cannotComplete:
            // Transient error, app may be busy
            return nil
        default:
            return nil
        }
    }

    /// Safely get the focused window for an application
    /// Returns nil if permission denied or no focused window
    public nonisolated func safeGetFocusedWindow(for pid: pid_t) -> AXUIElement? {
        guard hasAccessibilityPermission() else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        return safeGetAttribute(element: appElement, attribute: kAXFocusedWindowAttribute as String)
    }

    /// Safely get the window title for a process
    /// Returns nil if permission denied or no window
    public nonisolated func safeGetWindowTitle(for pid: pid_t) -> String? {
        guard let window = safeGetFocusedWindow(for: pid) else {
            return nil
        }

        return safeGetAttribute(element: window, attribute: kAXTitleAttribute as String)
    }

    /// Safely get the window frame (position + size)
    /// Returns nil if permission denied or cannot get frame
    public nonisolated func safeGetWindowFrame(for pid: pid_t) -> CGRect? {
        guard hasAccessibilityPermission() else {
            return nil
        }

        guard let window = safeGetFocusedWindow(for: pid) else {
            return nil
        }

        // Get position
        var positionValue: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
        guard posResult == .success, let posValue = positionValue else {
            return nil
        }

        // Get size
        var sizeValue: CFTypeRef?
        let sizeResult = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        guard sizeResult == .success, let szValue = sizeValue else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(szValue as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    // MARK: - Monitoring

    /// Start monitoring for permission changes
    /// Polls every few seconds to detect if user revokes permissions
    public func startMonitoring() {
        guard !isMonitoring else { return }

        isMonitoring = true

        // Do actual system check and initialize both cache and tracking variables
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let axStatus = AXIsProcessTrustedWithOptions(options as CFDictionary)
        let screenStatus = CGPreflightScreenCaptureAccess()

        lastAccessibilityStatus = axStatus
        lastScreenRecordingStatus = screenStatus
        _cachedAccessibilityStatus = axStatus
        _cachedScreenRecordingStatus = screenStatus
        _hasCachedStatus = true

        Log.info("[PermissionMonitor] Starting permission monitoring (AX: \(lastAccessibilityStatus), Screen: \(lastScreenRecordingStatus))", category: .capture)

        monitorTask = Task { [weak self] in
            // Check every 2 seconds
            let checkInterval: UInt64 = 2_000_000_000

            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(Int64(checkInterval)), clock: .continuous)
                guard !Task.isCancelled else { break }

                await self?.checkPermissionChanges()
            }
        }
    }

    /// Stop monitoring for permission changes
    public func stopMonitoring() {
        isMonitoring = false
        monitorTask?.cancel()
        monitorTask = nil
        Log.info("[PermissionMonitor] Stopped permission monitoring", category: .capture)
    }

    /// Check if permissions have changed and notify if revoked
    private func checkPermissionChanges() async {
        // Do actual system check (not cached) and update cache
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let currentAX = AXIsProcessTrustedWithOptions(options as CFDictionary)
        let currentScreen = CGPreflightScreenCaptureAccess()

        // Update cached values
        _cachedAccessibilityStatus = currentAX
        _cachedScreenRecordingStatus = currentScreen
        _hasCachedStatus = true

        // Check if accessibility was revoked
        if lastAccessibilityStatus && !currentAX {
            Log.warning("[PermissionMonitor] Accessibility permission was REVOKED", category: .capture)
            lastAccessibilityStatus = currentAX

            if let callback = onAccessibilityRevoked {
                await callback()
            }
            if let callback = onPermissionRevoked {
                await callback("Accessibility")
            }
        } else if !lastAccessibilityStatus && currentAX {
            Log.info("[PermissionMonitor] Accessibility permission was GRANTED", category: .capture)
            lastAccessibilityStatus = currentAX
        }

        // Check if screen recording was revoked
        if lastScreenRecordingStatus && !currentScreen {
            Log.warning("[PermissionMonitor] Screen recording permission was REVOKED", category: .capture)
            lastScreenRecordingStatus = currentScreen

            if let callback = onScreenRecordingRevoked {
                await callback()
            }
            if let callback = onPermissionRevoked {
                await callback("Screen Recording")
            }
        } else if !lastScreenRecordingStatus && currentScreen {
            Log.info("[PermissionMonitor] Screen recording permission was GRANTED", category: .capture)
            lastScreenRecordingStatus = currentScreen
        }
    }

    /// Force an immediate permission check (useful before sensitive operations)
    public func forceCheck() async {
        await checkPermissionChanges()
    }
}
