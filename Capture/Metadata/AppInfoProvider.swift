import Foundation
import AppKit
import ApplicationServices
import Shared

/// Provides information about the currently active application
struct AppInfoProvider: Sendable {

    // MARK: - Constants

    /// Known browser bundle identifiers for URL extraction
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi"
    ]

    // MARK: - App Info Retrieval

    /// Get information about the frontmost application
    /// - Returns: FrameMetadata with app info, or minimal metadata if unavailable
    @MainActor
    func getFrontmostAppInfo() -> FrameMetadata {
        // Get frontmost app from NSWorkspace
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return FrameMetadata(displayID: CGMainDisplayID())
        }

        let bundleID = frontApp.bundleIdentifier
        let appName = frontApp.localizedName

        // Get window title via Accessibility API
        let windowTitle = getWindowTitle(for: frontApp.processIdentifier)

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
            windowTitle: windowTitle,
            browserURL: browserURL,
            displayID: CGMainDisplayID()
        )
    }

    // MARK: - Private Helpers

    /// Get the title of the focused window using Accessibility API
    /// - Parameter pid: Process ID of the application
    /// - Returns: Window title if available
    private func getWindowTitle(for pid: pid_t) -> String? {
        // Create app reference
        let appRef = AXUIElementCreateApplication(pid)

        // Get focused window
        var windowValue: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            appRef,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        )

        guard windowResult == .success,
              let window = windowValue else {
            return nil
        }

        // Get window title
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )

        guard titleResult == .success,
              let title = titleValue as? String else {
            return nil
        }

        return title
    }

    /// Check if accessibility permissions are granted
    static func hasAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Request accessibility permission (shows system dialog)
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
