import Foundation
import ApplicationServices
import Shared

/// Extracts the current URL from supported web browsers
/// Requires Accessibility permission
struct BrowserURLExtractor: Sendable {

    // MARK: - URL Extraction

    /// Get the current URL from a browser
    /// - Parameters:
    ///   - bundleID: Browser bundle identifier
    ///   - pid: Process ID of the browser
    /// - Returns: Current URL if available
    ///
    /// Note: Only Safari uses deep hierarchy traversal.
    /// Chrome/Chromium browsers use AXDocument attribute.
    /// All other browsers return nil (rely on OCR to extract URL).
    static func getURL(bundleID: String, pid: pid_t) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return getSafariURL(pid: pid)
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser":
            return getChromiumURL(pid: pid)
        default:
            // For all other browsers (Firefox, Opera, Vivaldi, etc.),
            // rely on OCR to extract URL from the screen
            return nil
        }
    }

    // MARK: - Safari

    /// Extract URL from Safari using Accessibility API
    private static func getSafariURL(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)

        // Get focused window
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appRef,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let window = windowValue else {
            return nil
        }

        // Navigate to toolbar
        var toolbarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            "AXToolbar" as CFString,
            &toolbarValue
        ) == .success,
              let toolbar = toolbarValue else {
            return nil
        }

        // Get toolbar children
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            toolbar as! AXUIElement,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        // Find address bar (usually has role AXTextField and contains URL)
        for child in children {
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                child,
                kAXRoleAttribute as CFString,
                &roleValue
            ) == .success,
               let role = roleValue as? String,
               role == kAXTextFieldRole as String {

                // Try to get value (URL)
                var urlValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    child,
                    kAXValueAttribute as CFString,
                    &urlValue
                ) == .success,
                   let url = urlValue as? String,
                   !url.isEmpty {
                    return url
                }
            }
        }

        return nil
    }

    // MARK: - Chromium-based Browsers

    /// Extract URL from Chrome/Edge/Brave using AXDocument attribute
    /// - Parameter pid: Process ID of the browser
    /// - Returns: Current URL if available
    ///
    /// Chrome and Chromium-based browsers expose the URL via the AXDocument attribute
    /// on the focused window. This is more reliable than hierarchy traversal.
    private static func getChromiumURL(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)

        // Get focused window
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appRef,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let window = windowValue else {
            return nil
        }

        // Try to get URL from AXDocument attribute
        var documentValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            kAXDocumentAttribute as CFString,
            &documentValue
        ) == .success,
           let url = documentValue as? String,
           !url.isEmpty {
            return url
        }

        return nil
    }

}
