import Foundation
import AppKit
import ApplicationServices
import Shared

/// Provides information about the currently active application
struct AppInfoProvider: Sendable {

    // MARK: - Constants

    /// Known browser bundle identifiers for URL extraction (references shared list)
    static var browserBundleIDs: Set<String> { AppInfo.browserBundleIDs }

    // MARK: - App Info Retrieval

    /// Get information about the frontmost application
    /// - Returns: FrameMetadata with app info, or minimal metadata if unavailable
    @MainActor
    func getFrontmostAppInfo() -> FrameMetadata {
        // Get frontmost app from NSWorkspace
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return FrameMetadata(displayID: CGMainDisplayID())
        }

        // Use bundleIdentifier if available, otherwise check if it's the current app (dev build)
        var bundleID = frontApp.bundleIdentifier
        var appName = frontApp.localizedName

        // Dev build fix: if bundleID is nil but this is Retrace (same PID), use known bundle ID
        if bundleID == nil && frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            bundleID = Bundle.main.bundleIdentifier ?? "io.retrace.app"
            appName = appName ?? "Retrace"
        }

        // Get window title via Accessibility API
        let windowName = getWindowTitle(for: frontApp.processIdentifier)

        // Get browser URL if applicable
        var browserURL: String? = nil
        if let bundleID = bundleID, Self.browserBundleIDs.contains(bundleID) {
            browserURL = BrowserURLExtractor.getURL(
                bundleID: bundleID,
                pid: frontApp.processIdentifier
            )
        }

        return FrameMetadata(
            appBundleID: bundleID,
            appName: appName,
            windowName: windowName,
            browserURL: browserURL,
            displayID: CGMainDisplayID()
        )
    }

    // MARK: - Private Helpers

    /// Get the title of the focused window using Accessibility API
    /// Uses safe wrappers to prevent crashes if permissions are revoked
    /// - Parameter pid: Process ID of the application
    /// - Returns: Window title if available
    private func getWindowTitle(for pid: pid_t) -> String? {
        // Use safe wrapper that checks permissions first
        return PermissionMonitor.shared.safeGetWindowTitle(for: pid)
    }

    /// Check if accessibility permissions are granted
    /// Uses the central PermissionMonitor for consistent checking
    static func hasAccessibilityPermission() -> Bool {
        return PermissionMonitor.shared.hasAccessibilityPermission()
    }

    /// Request accessibility permission (shows system dialog)
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
