import XCTest
import AppKit
import ApplicationServices
import Shared

/// Interactive test to inspect accessibility data from the active window
/// Shows what metadata Retrace can capture for segments and FTS indexing
final class AccessibilityInspectorTest: XCTestCase {

    // File handle for logging - make it an instance variable so other methods can access it
    private var logFileHandle: FileHandle?

    /// Run this test and switch between different apps/windows to see what data is captured
    func testShowAccessibilityDataDialog() async throws {
        // Write to a file in /tmp so you can tail it
        let outputPath = "/tmp/accessibility_test_output.txt"
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: outputPath)!

        func log(_ message: String) {
            let line = message + "\n"
            logFileHandle?.write(line.data(using: .utf8)!)
            print(message) // Also print to stdout
        }

        log("\n╔══════════════════════════════════════════════════════════════════════════════╗")
        log("║                    ACCESSIBILITY INSPECTOR TEST                              ║")
        log("║                                                                              ║")
        log("║  This test will monitor the active window for 30 seconds.                   ║")
        log("║  Switch between different apps to see what data is captured:                ║")
        log("║    - App Bundle ID (for segment tracking)                                   ║")
        log("║    - App Name                                                               ║")
        log("║    - Window Title (FTS c2)                                                  ║")
        log("║    - Browser URL (if applicable)                                            ║")
        log("║                                                                              ║")
        log("║  Output file: \(outputPath)                                 ║")
        log("║  Run: tail -f \(outputPath)                                 ║")
        log("╚══════════════════════════════════════════════════════════════════════════════╝\n")

        // Check for accessibility permissions
        let trusted = AXIsProcessTrusted()
        if !trusted {
            log("⚠️  ACCESSIBILITY PERMISSION REQUIRED")
            log("   Go to: System Settings → Privacy & Security → Accessibility")
            log("   Enable access for your test runner or Xcode\n")

            // Try to prompt for permission
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let prompted = AXIsProcessTrustedWithOptions(options)

            if !prompted {
                XCTFail("Accessibility permission denied. Enable it in System Settings.")
                return
            }

            log("   Waiting for permission grant...")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        log("✅ Accessibility permission granted\n")
        log("Monitoring active window indefinitely (press Ctrl+C to stop)...\n")
        log(String(repeating: "─", count: 80))

        var lastAppBundleID = ""
        var lastWindowTitle = ""

        // Monitor indefinitely until Ctrl+C
        let startTime = Date()
        while true {
            if let data = captureActiveWindowData() {
                // Only print when something changes
                if data.appBundleID != lastAppBundleID || data.windowTitle != lastWindowTitle {
                    log("\n⏱  \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
                    log("📱 App Bundle ID:  \(data.appBundleID)")
                    log("📝 App Name:       \(data.appName)")
                    log("🪟 Window Title:   \(data.windowTitle ?? "(none)")")
                    log("🌐 Browser URL:    \(data.browserURL ?? "(none)")")
                    log("")
                    log("FTS Mapping:")
                    log("  c0 (main text):   [OCR text would go here]")
                    log("  c1 (chrome text): \(data.chromeText ?? "(none)")")
                    log("  c2 (window title):\(data.windowTitle ?? "(none)")")
                    log(String(repeating: "─", count: 80))

                    lastAppBundleID = data.appBundleID
                    lastWindowTitle = data.windowTitle ?? ""
                }
            }

            try await Task.sleep(nanoseconds: 500_000_000) // Check every 0.5s
        }

        // Note: This code won't be reached, but kept for completeness
        // fileHandle.closeFile()
    }

    // MARK: - Accessibility Data Capture

    private func captureActiveWindowData() -> AccessibilityData? {
        // Get the frontmost application
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appBundleID = frontApp.bundleIdentifier ?? "unknown"
        let appName = frontApp.localizedName ?? "Unknown App"

        // Get accessibility element for the app
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var windowTitle: String?
        var browserURL: String?
        var chromeText: String?

        // Get focused window
        if let focusedWindow: AXUIElement = getAttributeValue(appElement, attribute: kAXFocusedWindowAttribute as CFString) {
            // Get window title
            windowTitle = getAttributeValue(focusedWindow, attribute: kAXTitleAttribute as CFString)

            // Try to get browser URL (Chrome, Safari, Firefox patterns)
            if isBrowserApp(appBundleID) {
                browserURL = getBrowserURL(appElement: appElement, bundleID: appBundleID)
                // Debug: log if we failed to get URL for a browser
                if browserURL == nil {
                    print("[DEBUG] Failed to get URL for browser: \(appBundleID)")
                }
            }

            // Try to get status bar / menu bar text (chrome text)
            chromeText = getChromeText(windowElement: focusedWindow)
        }

        return AccessibilityData(
            appBundleID: appBundleID,
            appName: appName,
            windowTitle: windowTitle,
            browserURL: browserURL,
            chromeText: chromeText
        )
    }

    private func getAttributeValue<T>(_ element: AXUIElement, attribute: CFString) -> T? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard result == .success else {
            return nil
        }

        return value as? T
    }

    private func isBrowserApp(_ bundleID: String) -> Bool {
        let browsers = [
            "com.google.Chrome",
            "com.apple.Safari",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "com.vivaldi.Vivaldi",
            "company.thebrowser.Browser"  // Arc
        ]
        return browsers.contains(bundleID)
    }

    private func getBrowserURL(appElement: AXUIElement, bundleID: String) -> String? {
        // Strategy: Use accessibility API for Chrome/Safari, AppleScript for Firefox/Arc

        // For Firefox and Arc, use AppleScript (requires automation permission during onboarding)
        if bundleID == "org.mozilla.firefox" {
            debugLog("[DEBUG] Firefox detected - trying AppleScript")
            if let url = getFirefoxURLViaAppleScript() {
                debugLog("[DEBUG] ✅ Got URL via AppleScript for Firefox")
                return url
            }
        }

        if bundleID == "company.thebrowser.Browser" {
            debugLog("[DEBUG] Arc detected - trying AppleScript")
            if let url = getArcURLViaAppleScript() {
                debugLog("[DEBUG] ✅ Got URL via AppleScript for Arc")
                return url
            }
        }

        // For Chrome and Safari, use accessibility API (no extra permissions needed)
        // Method 1: Try accessibility API first (works for Safari, Chrome)
        if let focusedElement: AXUIElement = getAttributeValue(appElement, attribute: kAXFocusedUIElementAttribute as CFString) {
            if let url: String = getAttributeValue(focusedElement, attribute: kAXURLAttribute as CFString) {
                debugLog("[DEBUG] ✅ Got URL via kAXURLAttribute on focused element")
                return url
            }

            // Also try AXDocument attribute on focused element
            if let url: String = getAttributeValue(focusedElement, attribute: "AXDocument" as CFString) {
                debugLog("[DEBUG] ✅ Got URL via AXDocument on focused element")
                return url
            }
        }

        // Method 2: Try to get URL from window (works for Chrome)
        if let focusedWindow: AXUIElement = getAttributeValue(appElement, attribute: kAXFocusedWindowAttribute as CFString) {
            // Try AXDocument on window (works for Chrome)
            if let url: String = getAttributeValue(focusedWindow, attribute: "AXDocument" as CFString) {
                debugLog("[DEBUG] ✅ Got URL via AXDocument on window")
                return url
            }

            // Try kAXURLAttribute on window
            if let url: String = getAttributeValue(focusedWindow, attribute: kAXURLAttribute as CFString) {
                debugLog("[DEBUG] ✅ Got URL via kAXURLAttribute on window")
                return url
            }

            // Method 3: Deep search through UI hierarchy as fallback (works for Safari)
            debugLog("[DEBUG] URL not found via simple attributes for \(bundleID), trying deep search:")

            if let url = findURLInElement(focusedWindow, depth: 0, maxDepth: 8) {
                debugLog("[DEBUG] ✅ Got URL via deep UI hierarchy search")
                return url
            }

            // Debug: inspect attributes when all methods fail
            debugLog("[DEBUG] All methods failed, inspecting window attributes:")
            inspectAllAttributes(focusedWindow)
        }

        return nil
    }

    private func findURLInWindowHierarchy(_ window: AXUIElement) -> String? {
        // First, inspect ALL available attributes on the window
        debugLog("[DEBUG] Inspecting all attributes on window:")
        inspectAllAttributes(window)

        // Search more thoroughly through the window's UI hierarchy
        // Chrome and Arc store the URL in a text field somewhere deep in the toolbar
        return findURLInElement(window, depth: 0, maxDepth: 8)
    }

    private func inspectAllAttributes(_ element: AXUIElement) {
        var attributeNames: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &attributeNames)

        guard result == .success, let attributes = attributeNames as? [String] else {
            debugLog("  Failed to get attribute names")
            return
        }

        debugLog("  Available attributes (\(attributes.count)):")
        for attr in attributes {
            var value: AnyObject?
            let valueResult = AXUIElementCopyAttributeValue(element, attr as CFString, &value)

            if valueResult == .success, let val = value {
                let valueStr = String(describing: val)
                let truncated = valueStr.prefix(100)
                debugLog("    \(attr) = \(truncated)")
            } else {
                debugLog("    \(attr) = <unavailable>")
            }
        }
    }

    private func getFirefoxURLViaAppleScript() -> String? {
        let script = """
        tell application "Firefox"
            if (count of windows) > 0 then
                get URL of active tab of front window
            end if
        end tell
        """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&error)

        if let error = error {
            debugLog("[DEBUG] Firefox AppleScript error: \(error)")
            return nil
        }

        return result?.stringValue
    }

    private func getChromeURLViaAppleScript() -> String? {
        let script = """
        tell application "Google Chrome"
            if (count of windows) > 0 then
                get URL of active tab of front window
            end if
        end tell
        """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&error)

        if let error = error {
            debugLog("[DEBUG] AppleScript error: \(error)")
            return nil
        }

        return result?.stringValue
    }

    private func getArcURLViaAppleScript() -> String? {
        // Try method 1: Standard AppleScript
        let script1 = """
        tell application "Arc"
            if (count of windows) > 0 then
                get URL of active tab of front window
            end if
        end tell
        """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script1)
        let result = appleScript?.executeAndReturnError(&error)

        if let error = error {
            debugLog("[DEBUG] Arc AppleScript method 1 error: \(error)")

            // Try method 2: Alternative syntax (some browsers use different terminology)
            let script2 = """
            tell application "Arc"
                if (count of windows) > 0 then
                    get URL of current tab of window 1
                end if
            end tell
            """

            var error2: NSDictionary?
            let appleScript2 = NSAppleScript(source: script2)
            let result2 = appleScript2?.executeAndReturnError(&error2)

            if let error2 = error2 {
                debugLog("[DEBUG] Arc AppleScript method 2 error: \(error2)")
                return nil
            }

            return result2?.stringValue
        }

        return result?.stringValue
    }

    private func getSafariURLViaAppleScript() -> String? {
        let script = """
        tell application "Safari"
            if (count of windows) > 0 then
                get URL of current tab of front window
            end if
        end tell
        """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&error)

        if let error = error {
            debugLog("[DEBUG] Safari AppleScript error: \(error)")
            return nil
        }

        return result?.stringValue
    }

    private func getChromeURLFromWindow(_ window: AXUIElement) -> String? {
        // Chrome's URL is typically in a text field with role "AXTextField" in the toolbar
        // We need to recursively search the window's UI hierarchy

        // Debug: Print the window's accessibility tree to the log file
        debugLog("[DEBUG] Chrome window accessibility tree:")
        debugPrintElement(window, depth: 0, maxDepth: 3)

        if let url = findURLInElement(window, depth: 0, maxDepth: 5) {
            return url
        }
        return nil
    }

    private func debugLog(_ message: String) {
        let line = message + "\n"
        logFileHandle?.write(line.data(using: .utf8)!)
    }

    private func debugPrintElement(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }

        let indent = String(repeating: "  ", count: depth)
        let role: String = getAttributeValue(element, attribute: kAXRoleAttribute as CFString) ?? "unknown"
        let title: String? = getAttributeValue(element, attribute: kAXTitleAttribute as CFString)
        let value: String? = getAttributeValue(element, attribute: kAXValueAttribute as CFString)
        let description: String? = getAttributeValue(element, attribute: kAXDescriptionAttribute as CFString)

        var output = "\(indent)[\(role)]"
        if let title = title {
            output += " title=\"\(title.prefix(30))\""
        }
        if let value = value {
            output += " value=\"\(value.prefix(50))\""
        }
        if let description = description {
            output += " desc=\"\(description.prefix(30))\""
        }
        debugLog(output)

        // Recursively print children
        if let children: [AXUIElement] = getAttributeValue(element, attribute: kAXChildrenAttribute as CFString) {
            for child in children.prefix(15).enumerated() {
                debugPrintElement(child.element, depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }

    private func findURLInElement(_ element: AXUIElement, depth: Int, maxDepth: Int) -> String? {
        guard depth < maxDepth else { return nil }

        // Check if this element has a URL
        if let url: String = getAttributeValue(element, attribute: kAXURLAttribute as CFString) {
            return url
        }

        // Check if this is a text field that might contain the URL
        if let role: String = getAttributeValue(element, attribute: kAXRoleAttribute as CFString) {
            if role == kAXTextFieldRole as String {
                // Check for value which might be the URL
                if let value: String = getAttributeValue(element, attribute: kAXValueAttribute as CFString) {
                    // Basic check if it looks like a URL
                    if value.hasPrefix("http://") || value.hasPrefix("https://") {
                        return value
                    }
                }
            }
        }

        // Recursively check children
        if let children: [AXUIElement] = getAttributeValue(element, attribute: kAXChildrenAttribute as CFString) {
            for child in children.prefix(20) {  // Check first 20 children at each level
                if let url = findURLInElement(child, depth: depth + 1, maxDepth: maxDepth) {
                    return url
                }
            }
        }

        return nil
    }

    private func getChromeText(windowElement: AXUIElement) -> String? {
        // Try to get status bar or toolbar text
        // This is a simplified version - real implementation would walk the UI tree

        if let children: [AXUIElement] = getAttributeValue(windowElement, attribute: kAXChildrenAttribute as CFString) {
            for child in children.prefix(10) { // Only check first 10 children
                if let role: String = getAttributeValue(child, attribute: kAXRoleAttribute as CFString) {
                    if role == kAXStaticTextRole as String || role == kAXTextAreaRole as String {
                        if let text: String = getAttributeValue(child, attribute: kAXValueAttribute as CFString) {
                            if !text.isEmpty && text.count < 100 {
                                return text
                            }
                        }
                    }
                }
            }
        }

        return nil
    }
}

// MARK: - Data Structure

private struct AccessibilityData {
    let appBundleID: String
    let appName: String
    let windowTitle: String?
    let browserURL: String?
    let chromeText: String?
}
