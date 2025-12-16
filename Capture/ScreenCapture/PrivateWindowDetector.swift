import Foundation
import ApplicationServices
import ScreenCaptureKit
import Shared

/// Detects private/incognito browser windows using Accessibility API and fallback methods
struct PrivateWindowDetector {

    // MARK: - Detection Methods

    /// Detect if a window is a private/incognito browsing window
    /// - Parameter window: The SCWindow to check
    /// - Returns: true if the window is determined to be private
    static func isPrivateWindow(_ window: SCWindow) -> Bool {
        let (isPrivate, _) = isPrivateWindowWithPermissionStatus(window)
        return isPrivate
    }

    /// Detect if a window is private and return permission status
    /// - Parameter window: The SCWindow to check
    /// - Returns: Tuple of (isPrivate, hasAccessibilityPermission)
    static func isPrivateWindowWithPermissionStatus(_ window: SCWindow) -> (Bool, Bool) {
        // Try Accessibility API first (most reliable)
        if let (isPrivate, hasPermission) = checkViaAccessibilityAPIWithPermissionStatus(window) {
            return (isPrivate, hasPermission)
        }

        // Fallback to title-based detection (no permission required)
        return (checkViaTitlePatterns(window), true)
    }

    // MARK: - Accessibility API Detection

    /// Check if window is private using Accessibility API
    /// - Parameter window: The SCWindow to check
    /// - Returns: true/false if detection succeeds, nil if unable to determine
    private static func checkViaAccessibilityAPI(_ window: SCWindow) -> Bool? {
        if let (isPrivate, _) = checkViaAccessibilityAPIWithPermissionStatus(window) {
            return isPrivate
        }
        return nil
    }

    /// Check if window is private using Accessibility API with permission status
    /// - Parameter window: The SCWindow to check
    /// - Returns: Tuple of (isPrivate, hasPermission), or nil if unable to determine
    private static func checkViaAccessibilityAPIWithPermissionStatus(_ window: SCWindow) -> (Bool, Bool)? {
        // Get the window's owning application PID
        guard let app = window.owningApplication else { return nil }

        // Create AXUIElement for the application
        let appElement = AXUIElementCreateApplication(app.processID)

        // Get all windows for this application
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )

        // Check for permission denial
        if result == .apiDisabled || result == .cannotComplete {
            Log.warning("Accessibility permission denied for private window detection", category: .capture)
            return nil // Return nil to trigger fallback, but we've logged the issue
        }

        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        // Find the matching window by comparing window IDs or titles
        for axWindow in windows {
            // Try to match by title first
            if let windowTitle = getAXAttribute(axWindow, kAXTitleAttribute as CFString) as? String,
               windowTitle == window.title {
                let isPrivate = isPrivateWindowElement(axWindow, bundleID: app.bundleIdentifier)
                return (isPrivate, true) // Successfully checked with AX permission
            }
        }

        return nil
    }

    /// Check if an AXUIElement window is private
    /// - Parameters:
    ///   - element: The AXUIElement representing the window
    ///   - bundleID: The application's bundle identifier
    /// - Returns: true if the window is private
    private static func isPrivateWindowElement(_ element: AXUIElement, bundleID: String) -> Bool {
        // Check browser-specific attributes
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
             "com.brave.Browser", "org.chromium.Chromium", "com.vivaldi.Vivaldi":
            return checkChromiumPrivate(element)

        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return checkSafariPrivate(element)

        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly":
            return checkFirefoxPrivate(element)

        case "company.thebrowser.Browser": // Arc
            return checkArcPrivate(element)

        default:
            return false
        }
    }

    // MARK: - Browser-Specific Detection

    /// Check if a Chromium-based browser window is in incognito mode
    private static func checkChromiumPrivate(_ element: AXUIElement) -> Bool {
        // Check AXSubrole - Chromium sets different subroles for incognito windows
        if let subrole = getAXAttribute(element, kAXSubroleAttribute as CFString) as? String {
            if subrole.contains("Incognito") || subrole.contains("Private") {
                return true
            }
        }

        // Check AXRoleDescription
        if let roleDesc = getAXAttribute(element, kAXRoleDescriptionAttribute as CFString) as? String {
            if roleDesc.lowercased().contains("incognito") ||
               roleDesc.lowercased().contains("private") {
                return true
            }
        }

        // Check AXDescription
        if let description = getAXAttribute(element, kAXDescriptionAttribute as CFString) as? String {
            if description.lowercased().contains("incognito") ||
               description.lowercased().contains("private") {
                return true
            }
        }

        // Check window title (fallback)
        if let title = getAXAttribute(element, kAXTitleAttribute as CFString) as? String {
            // Chromium appends " - Incognito" or " (Incognito)" to window titles
            if title.contains(" - Incognito") ||
               title.contains("(Incognito)") ||
               title.contains(" - InPrivate") ||
               title.contains("(InPrivate)") {
                return true
            }
        }

        return false
    }

    /// Check if a Safari window is in private browsing mode
    private static func checkSafariPrivate(_ element: AXUIElement) -> Bool {
        // Safari sets specific attributes for private windows

        // Check for private browsing attribute
        if let isPrivate = getAXAttribute(element, "AXIsPrivateBrowsing" as CFString) as? Bool {
            return isPrivate
        }

        // Check window title - Safari appends " — Private"
        if let title = getAXAttribute(element, kAXTitleAttribute as CFString) as? String {
            if title.hasSuffix(" — Private") || title.hasSuffix(" - Private") {
                return true
            }
        }

        // Check AXDescription
        if let description = getAXAttribute(element, kAXDescriptionAttribute as CFString) as? String {
            if description.lowercased().contains("private") {
                return true
            }
        }

        return false
    }

    /// Check if a Firefox window is in private browsing mode
    private static func checkFirefoxPrivate(_ element: AXUIElement) -> Bool {
        // Check window title - Firefox appends " — Private Browsing" or " (Private Browsing)"
        if let title = getAXAttribute(element, kAXTitleAttribute as CFString) as? String {
            if title.contains(" — Private Browsing") ||
               title.contains(" (Private Browsing)") ||
               title.contains("Private Browsing —") {
                return true
            }
        }

        // Check AXDescription
        if let description = getAXAttribute(element, kAXDescriptionAttribute as CFString) as? String {
            if description.lowercased().contains("private browsing") {
                return true
            }
        }

        // Check AXRoleDescription
        if let roleDesc = getAXAttribute(element, kAXRoleDescriptionAttribute as CFString) as? String {
            if roleDesc.lowercased().contains("private") {
                return true
            }
        }

        return false
    }

    /// Check if an Arc browser window is in private mode
    private static func checkArcPrivate(_ element: AXUIElement) -> Bool {
        // Arc browser detection (similar to Chromium)
        if let title = getAXAttribute(element, kAXTitleAttribute as CFString) as? String {
            if title.contains("Private") || title.contains("Incognito") {
                return true
            }
        }

        return false
    }

    // MARK: - Title-Based Fallback Detection

    /// Fallback detection using title patterns (less reliable)
    /// - Parameter window: The SCWindow to check
    /// - Returns: true if title suggests private window
    private static func checkViaTitlePatterns(_ window: SCWindow) -> Bool {
        guard let title = window.title, !title.isEmpty else {
            return false
        }

        let lowercaseTitle = title.lowercased()

        // Common patterns across browsers
        let patterns = [
            "private",           // Safari: "Page Title — Private"
            "incognito",         // Chrome: "Page Title - Incognito"
            "inprivate",         // Edge: "Page Title - InPrivate"
            "private browsing",  // Firefox: "Page Title — Private Browsing"
            "private window"     // Brave: "Page Title - Private Window"
        ]

        return patterns.contains { pattern in
            lowercaseTitle.contains(pattern)
        }
    }

    // MARK: - Accessibility Helpers

    /// Safely get an Accessibility attribute value
    /// - Parameters:
    ///   - element: The AXUIElement to query
    ///   - attribute: The attribute name
    /// - Returns: The attribute value, or nil if unavailable
    private static func getAXAttribute(_ element: AXUIElement, _ attribute: CFString) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard result == .success else {
            return nil
        }

        return value
    }
}
