import Foundation
import ApplicationServices
import ScreenCaptureKit
import Shared

/// Detects private/incognito browser windows using Accessibility API and fallback methods
struct PrivateWindowDetector {

    // MARK: - Detection Methods (SCWindow)

    /// Detect if a window is a private/incognito browsing window
    /// - Parameter window: The SCWindow to check
    /// - Returns: true if the window is determined to be private
    static func isPrivateWindow(_ window: SCWindow) -> Bool {
        let (isPrivate, _) = isPrivateWindowWithPermissionStatus(window)
        return isPrivate
    }

    // MARK: - Detection Methods (CGWindowList)

    /// Detect if a window from CGWindowList is a private/incognito browsing window
    /// - Parameters:
    ///   - windowInfo: The window dictionary from CGWindowListCopyWindowInfo
    ///   - patterns: Additional patterns to check for private windows
    /// - Returns: true if the window is determined to be private
    static func isPrivateWindow(windowInfo: [String: Any], patterns: [String] = []) -> Bool {
        guard let ownerName = windowInfo[kCGWindowOwnerName as String] as? String else {
            return false
        }

        // Check if this is a browser that could have private windows
        let browserOwnerNames = [
            "Safari", "Google Chrome", "Chrome", "Brave Browser", "Microsoft Edge",
            "Firefox", "Arc", "Vivaldi", "Chromium", "Opera"
        ]

        let isBrowser = browserOwnerNames.contains { ownerName.contains($0) }
        guard isBrowser else { return false }

        // Get window title for pattern matching
        guard let windowName = windowInfo[kCGWindowName as String] as? String,
              !windowName.isEmpty else {
            return false
        }

        // Try Accessibility API first for more reliable detection
        if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t {
            if let isPrivate = checkViaAccessibilityAPI(pid: ownerPID, windowTitle: windowName, ownerName: ownerName) {
                return isPrivate
            }
        }

        // Fallback to title-based detection
        return checkViaTitlePatterns(title: windowName, additionalPatterns: patterns)
    }

    /// Check if a window is private using Accessibility API (for CGWindowList)
    /// - Parameters:
    ///   - pid: Process ID of the window owner
    ///   - windowTitle: The window title to match
    ///   - ownerName: The application name
    /// - Returns: true/false if detection succeeds, nil if unable to determine
    private static func checkViaAccessibilityAPI(pid: pid_t, windowTitle: String, ownerName: String) -> Bool? {
        let appElement = AXUIElementCreateApplication(pid)

        // Get all windows for this application
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )

        // Check for permission denial
        if result == .apiDisabled || result == .cannotComplete {
            return nil // Trigger fallback
        }

        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        // Determine bundle ID from owner name for browser-specific detection
        let bundleID = bundleIDFromOwnerName(ownerName)

        // Find the matching window by comparing titles
        for axWindow in windows {
            if let axTitle = getAXAttribute(axWindow, kAXTitleAttribute as CFString) as? String,
               axTitle == windowTitle {
                return isPrivateWindowElement(axWindow, bundleID: bundleID)
            }
        }

        return nil
    }

    /// Map owner name to bundle ID for browser-specific detection
    private static func bundleIDFromOwnerName(_ ownerName: String) -> String {
        switch ownerName {
        case "Safari":
            return "com.apple.Safari"
        case "Google Chrome", "Chrome":
            return "com.google.Chrome"
        case "Brave Browser":
            return "com.brave.Browser"
        case "Microsoft Edge":
            return "com.microsoft.edgemac"
        case "Firefox":
            return "org.mozilla.firefox"
        case "Arc":
            return "company.thebrowser.Browser"
        case "Vivaldi":
            return "com.vivaldi.Vivaldi"
        case "Chromium":
            return "org.chromium.Chromium"
        case "Opera":
            return "com.operasoftware.Opera"
        default:
            return ownerName
        }
    }

    /// Fallback detection using title patterns
    /// - Parameters:
    ///   - title: The window title to check
    ///   - additionalPatterns: Additional patterns to check beyond defaults
    /// - Returns: true if title suggests private window
    private static func checkViaTitlePatterns(title: String, additionalPatterns: [String]) -> Bool {
        let lowercaseTitle = title.lowercased()

        // Browser-specific suffix patterns (more precise to avoid false positives)
        // These patterns match the actual suffixes browsers add to window titles
        let suffixPatterns = [
            " — private",           // Safari: "Page Title — Private"
            " - private",           // Safari alternate
            " - incognito",         // Chrome: "Page Title - Incognito"
            " — incognito",         // Chrome alternate
            "(incognito)",          // Chrome alternate format
            " - inprivate",         // Edge: "Page Title - InPrivate"
            " — inprivate",         // Edge alternate
            "(inprivate)",          // Edge alternate format
            " — private browsing",  // Firefox: "Page Title — Private Browsing"
            " - private browsing",  // Firefox alternate
            "(private browsing)",   // Firefox alternate format
            " - private window",    // Brave: "Page Title - Private Window"
            " — private window",    // Brave alternate
        ]

        // Check browser-specific suffix patterns
        for pattern in suffixPatterns {
            if lowercaseTitle.contains(pattern) {
                return true
            }
        }

        // Check additional custom patterns (these use contains for flexibility)
        for pattern in additionalPatterns {
            if lowercaseTitle.contains(pattern.lowercased()) {
                return true
            }
        }

        return false
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
        let title = getAXAttribute(element, kAXTitleAttribute as CFString) as? String ?? "(no title)"
        let subrole = getAXAttribute(element, kAXSubroleAttribute as CFString) as? String
        let roleDesc = getAXAttribute(element, kAXRoleDescriptionAttribute as CFString) as? String
        let description = getAXAttribute(element, kAXDescriptionAttribute as CFString) as? String

        Log.info("[ChromiumPrivate] Checking window '\(title)' - subrole: \(subrole ?? "nil"), roleDesc: \(roleDesc ?? "nil"), desc: \(description ?? "nil")", category: .capture)

        // Check AXSubrole - Chromium sets different subroles for incognito windows
        if let subrole = subrole {
            if subrole.contains("Incognito") || subrole.contains("Private") {
                Log.info("[ChromiumPrivate] MATCH via subrole: \(subrole)", category: .capture)
                return true
            }
        }

        // Check AXRoleDescription
        if let roleDesc = roleDesc {
            if roleDesc.lowercased().contains("incognito") ||
               roleDesc.lowercased().contains("private") {
                Log.info("[ChromiumPrivate] MATCH via roleDesc: \(roleDesc)", category: .capture)
                return true
            }
        }

        // Check AXDescription
        if let description = description {
            if description.lowercased().contains("incognito") ||
               description.lowercased().contains("private") {
                Log.info("[ChromiumPrivate] MATCH via description: \(description)", category: .capture)
                return true
            }
        }

        // Check window title (fallback)
        if title.contains(" - Incognito") ||
           title.contains("(Incognito)") ||
           title.contains(" - InPrivate") ||
           title.contains("(InPrivate)") {
            Log.info("[ChromiumPrivate] MATCH via title: \(title)", category: .capture)
            return true
        }

        Log.info("[ChromiumPrivate] NO MATCH for '\(title)'", category: .capture)
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

        // Reuse the same pattern matching logic
        return checkViaTitlePatterns(title: title, additionalPatterns: [])
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
