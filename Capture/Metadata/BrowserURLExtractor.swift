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
    static func getURL(bundleID: String, pid: pid_t) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return getSafariURL(pid: pid)
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser":
            return getChromiumURL(pid: pid)
        case "org.mozilla.firefox":
            return getFirefoxURL(pid: pid)
        default:
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

    /// Extract URL from Chrome/Edge/Brave using Accessibility API
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

        // Chromium browsers expose URL in the address bar
        // The address bar is typically a text field with subrole "AXAddressField"
        if let url = findAddressFieldURL(in: window as! AXUIElement) {
            return url
        }

        // Fallback: try to get it from window title
        // Many browsers show URL in the title
        var titleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success,
           let title = titleValue as? String {
            // Extract URL from title if present
            return extractURLFromTitle(title)
        }

        return nil
    }

    // MARK: - Firefox

    /// Extract URL from Firefox using Accessibility API
    private static func getFirefoxURL(pid: pid_t) -> String? {
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

        // Try to find address bar
        if let url = findAddressFieldURL(in: window as! AXUIElement) {
            return url
        }

        return nil
    }

    // MARK: - Helper Methods

    /// Recursively search for address field in UI element hierarchy
    private static func findAddressFieldURL(in element: AXUIElement, depth: Int = 0) -> String? {
        // Limit recursion depth to prevent infinite loops
        guard depth < 10 else { return nil }

        // Check if this element is an address field
        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success,
           let subrole = subroleValue as? String,
           subrole.contains("Address") {

            // Get value
            var urlValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXValueAttribute as CFString,
                &urlValue
            ) == .success,
               let url = urlValue as? String,
               !url.isEmpty {
                return url
            }
        }

        // Search children
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let url = findAddressFieldURL(in: child, depth: depth + 1) {
                return url
            }
        }

        return nil
    }

    /// Extract URL from window title
    /// Some browsers include URL in the title like "Page Title - URL"
    private static func extractURLFromTitle(_ title: String) -> String? {
        // Simple heuristic: look for http:// or https:// in title
        let patterns = ["https://", "http://"]

        for pattern in patterns {
            if let range = title.range(of: pattern) {
                let urlStart = range.lowerBound
                let remainingString = String(title[urlStart...])

                // Extract until whitespace or end
                if let endIndex = remainingString.firstIndex(where: { $0.isWhitespace }) {
                    return String(remainingString[..<endIndex])
                } else {
                    return remainingString
                }
            }
        }

        return nil
    }
}
