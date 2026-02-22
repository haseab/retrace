import XCTest
import AppKit
import ApplicationServices
import Shared

/// Interactive test to inspect accessibility data from the active window
/// Shows what metadata Retrace can capture for segments and FTS indexing
///
/// Browser URL Extraction Strategy:
/// 1. Safari: AXToolbar → AXTextField (address bar)
/// 2. Chrome/Edge/Brave/Vivaldi: AXDocument on window + AXManualAccessibility toggle
/// 3. Arc: AppleScript (Chromium but AX tree often incomplete)
/// 4. Firefox: AppleScript (Gecko doesn't expose URL via AX)
/// 5. Generic fallback: Find AXWebArea and read AXURL attribute
final class AccessibilityInspectorTest: XCTestCase {

    // File handle for logging - make it an instance variable so other methods can access it
    private var logFileHandle: FileHandle?

    // Set to true to see detailed extraction attempts (noisy)
    private var verboseLogging = false

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
        log("║  This test will monitor the active window indefinitely.                     ║")
        log("║  Switch between different apps to see what data is captured:                ║")
        log("║    - App Bundle ID (for segment tracking)                                   ║")
        log("║    - App Name                                                               ║")
        log("║    - Window Title (FTS c2)                                                  ║")
        log("║    - Browser URL (if applicable)                                            ║")
        log("║                                                                              ║")
        log("║  Supported browsers: Safari, Chrome, Edge, Brave, Arc, Firefox, Vivaldi     ║")
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
            try await Task.sleep(for: .nanoseconds(Int64(2_000_000_000)), clock: .continuous)
        }

        log("✅ Accessibility permission granted\n")
        log("Monitoring active window indefinitely (press Ctrl+C to stop)...\n")
        log(String(repeating: "─", count: 80))

        var lastAppBundleID = ""
        var lastWindowTitle = ""
        var lastBrowserURL = ""

        // Monitor indefinitely until Ctrl+C
        let startTime = Date()
        while true {
            if let data = captureActiveWindowData() {
                // Only print when something changes
                let currentURL = data.browserURL ?? ""
                if data.appBundleID != lastAppBundleID || data.windowTitle != lastWindowTitle || currentURL != lastBrowserURL {
                    log("\n⏱  \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
                    log("📱 App Bundle ID:  \(data.appBundleID)")
                    log("📝 App Name:       \(data.appName)")
                    log("🪟 Window Title:   \(data.windowTitle ?? "(none)")")
                    log("🌐 Browser URL:    \(data.browserURL ?? "(not a browser / URL not found)")")
                    if let method = data.urlExtractionMethod {
                        log("   └─ Method:      \(method)")
                    }
                    log("")
                    log("FTS Mapping:")
                    log("  c0 (main text):   [OCR text would go here]")
                    log("  c1 (chrome text): \(data.chromeText ?? "(none)")")
                    log("  c2 (window title):\(data.windowTitle ?? "(none)")")
                    log(String(repeating: "─", count: 80))

                    lastAppBundleID = data.appBundleID
                    lastWindowTitle = data.windowTitle ?? ""
                    lastBrowserURL = currentURL
                }
            }

            try await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous) // Check every 0.5s
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
        var urlMethod: String?
        var chromeText: String?

        // Get focused window
        if let focusedWindow: AXUIElement = getAttributeValue(appElement, attribute: kAXFocusedWindowAttribute as CFString) {
            // Get window title
            windowTitle = getAttributeValue(focusedWindow, attribute: kAXTitleAttribute as CFString)

            // Try to get browser URL
            if isBrowserApp(appBundleID) {
                let result = getBrowserURL(appElement: appElement, window: focusedWindow, bundleID: appBundleID)
                browserURL = result.url
                urlMethod = result.method
            }

            // Try to get status bar / menu bar text (chrome text)
            chromeText = getChromeText(windowElement: focusedWindow)
        }

        return AccessibilityData(
            appBundleID: appBundleID,
            appName: appName,
            windowTitle: windowTitle,
            browserURL: browserURL,
            urlExtractionMethod: urlMethod,
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
            "com.operasoftware.Opera",
            "company.thebrowser.Browser"  // Arc
        ]
        return browsers.contains(bundleID)
    }

    // MARK: - Browser URL Extraction

    private func getBrowserURL(appElement: AXUIElement, window: AXUIElement, bundleID: String) -> (url: String?, method: String?) {
        // Strategy varies by browser type

        switch bundleID {
        case "com.apple.Safari":
            return getSafariURL(appElement: appElement, window: window)

        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi":
            return getChromiumURL(appElement: appElement, window: window, bundleID: bundleID)

        case "company.thebrowser.Browser":  // Arc
            return getArcURL(appElement: appElement, window: window)

        case "org.mozilla.firefox":
            return getFirefoxURL()

        default:
            // Generic fallback for unknown browsers
            return getGenericBrowserURL(appElement: appElement, window: window)
        }
    }

    // MARK: - Safari

    private func getSafariURL(appElement: AXUIElement, window: AXUIElement) -> (url: String?, method: String?) {
        verboseLog("[Safari] Attempting URL extraction...")

        // Method 1: Toolbar → TextField approach
        if let toolbar: AXUIElement = getAttributeValue(window, attribute: "AXToolbar" as CFString),
           let children: [AXUIElement] = getAttributeValue(toolbar, attribute: kAXChildrenAttribute as CFString) {
            for child in children {
                if let role: String = getAttributeValue(child, attribute: kAXRoleAttribute as CFString),
                   role == kAXTextFieldRole as String,
                   let url: String = getAttributeValue(child, attribute: kAXValueAttribute as CFString),
                   !url.isEmpty {
                    verboseLog("[Safari] ✅ Got URL via toolbar text field")
                    return (url, "Safari: AXToolbar → AXTextField")
                }
            }
        }

        // Method 2: AXWebArea → AXURL
        if let url = findURLInWebArea(window) {
            verboseLog("[Safari] ✅ Got URL via AXWebArea")
            return (url, "Safari: AXWebArea → AXURL")
        }

        // Method 3: Deep search
        if let url = findURLInElement(window, depth: 0, maxDepth: 10) {
            verboseLog("[Safari] ✅ Got URL via deep search")
            return (url, "Safari: Deep UI search")
        }

        verboseLog("[Safari] ❌ All methods failed")
        return (nil, nil)
    }

    // MARK: - Chromium Browsers (Chrome, Edge, Brave, Vivaldi)

    private func getChromiumURL(appElement: AXUIElement, window: AXUIElement, bundleID: String) -> (url: String?, method: String?) {
        let browserName = bundleID.components(separatedBy: ".").last ?? "Chromium"
        verboseLog("[\(browserName)] Attempting URL extraction...")

        // Enable accessibility on Chromium/Electron apps
        enableChromiumAccessibility(appElement)

        // Method 1: AXDocument on window (most reliable for Chrome)
        if let url: String = getAttributeValue(window, attribute: kAXDocumentAttribute as CFString), !url.isEmpty {
            verboseLog("[\(browserName)] ✅ Got URL via AXDocument on window")
            return (url, "\(browserName): AXDocument on window")
        }

        // Method 2: AXWebArea → AXURL
        if let url = findURLInWebArea(window) {
            verboseLog("[\(browserName)] ✅ Got URL via AXWebArea")
            return (url, "\(browserName): AXWebArea → AXURL")
        }

        // Method 3: Focused element attributes
        if let focused: AXUIElement = getAttributeValue(appElement, attribute: kAXFocusedUIElementAttribute as CFString) {
            if let url: String = getAttributeValue(focused, attribute: kAXURLAttribute as CFString), !url.isEmpty {
                verboseLog("[\(browserName)] ✅ Got URL via focused element AXURL")
                return (url, "\(browserName): Focused element AXURL")
            }
            if let url: String = getAttributeValue(focused, attribute: kAXDocumentAttribute as CFString), !url.isEmpty {
                verboseLog("[\(browserName)] ✅ Got URL via focused element AXDocument")
                return (url, "\(browserName): Focused element AXDocument")
            }
        }

        // Method 4: Deep search for address bar
        if let url = findURLInElement(window, depth: 0, maxDepth: 8) {
            verboseLog("[\(browserName)] ✅ Got URL via deep search")
            return (url, "\(browserName): Deep UI search")
        }

        verboseLog("[\(browserName)] ❌ All methods failed")
        inspectAllAttributes(window)
        return (nil, nil)
    }

    /// Enable accessibility on Chromium/Electron apps by setting AXManualAccessibility
    private func enableChromiumAccessibility(_ appElement: AXUIElement) {
        // Set AXManualAccessibility = true to force Chromium to expose the AX tree
        let result = AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        if result == .success {
            verboseLog("[Chromium] Set AXManualAccessibility = true")
        }
    }

    // MARK: - Arc Browser

    private func getArcURL(appElement: AXUIElement, window: AXUIElement) -> (url: String?, method: String?) {
        verboseLog("[Arc] Attempting URL extraction...")

        // Method 1: AppleScript (most reliable for Arc)
        if let url = getArcURLViaAppleScript() {
            verboseLog("[Arc] ✅ Got URL via AppleScript")
            return (url, "Arc: AppleScript")
        }

        // Method 2: Fall back to Chromium approach
        enableChromiumAccessibility(appElement)

        if let url: String = getAttributeValue(window, attribute: kAXDocumentAttribute as CFString), !url.isEmpty {
            verboseLog("[Arc] ✅ Got URL via AXDocument")
            return (url, "Arc: AXDocument on window")
        }

        if let url = findURLInWebArea(window) {
            verboseLog("[Arc] ✅ Got URL via AXWebArea")
            return (url, "Arc: AXWebArea → AXURL")
        }

        verboseLog("[Arc] ❌ All methods failed")
        return (nil, nil)
    }

    // MARK: - Firefox

    private func getFirefoxURL() -> (url: String?, method: String?) {
        verboseLog("[Firefox] Attempting URL extraction via AppleScript...")

        if let url = getFirefoxURLViaAppleScript() {
            verboseLog("[Firefox] ✅ Got URL via AppleScript")
            return (url, "Firefox: AppleScript")
        }

        verboseLog("[Firefox] ❌ AppleScript failed (check Automation permissions)")
        return (nil, nil)
    }

    // MARK: - Generic Browser Fallback

    private func getGenericBrowserURL(appElement: AXUIElement, window: AXUIElement) -> (url: String?, method: String?) {
        verboseLog("[Generic] Attempting URL extraction...")

        // Try AXWebArea approach
        if let url = findURLInWebArea(window) {
            verboseLog("[Generic] ✅ Got URL via AXWebArea")
            return (url, "Generic: AXWebArea → AXURL")
        }

        // Try AXDocument on window
        if let url: String = getAttributeValue(window, attribute: kAXDocumentAttribute as CFString), !url.isEmpty {
            verboseLog("[Generic] ✅ Got URL via AXDocument")
            return (url, "Generic: AXDocument on window")
        }

        // Deep search
        if let url = findURLInElement(window, depth: 0, maxDepth: 8) {
            verboseLog("[Generic] ✅ Got URL via deep search")
            return (url, "Generic: Deep UI search")
        }

        verboseLog("[Generic] ❌ All methods failed")
        return (nil, nil)
    }

    // MARK: - AXWebArea Approach (Generic)

    /// Find URL by locating AXWebArea element and reading AXURL
    /// This is Apple's documented approach for web content
    private func findURLInWebArea(_ element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 15 else { return nil }

        // Check if this element is a web area
        if let role: String = getAttributeValue(element, attribute: kAXRoleAttribute as CFString),
           role == "AXWebArea" {
            // Try AXURL attribute (the documented way)
            if let url: String = getAttributeValue(element, attribute: kAXURLAttribute as CFString), !url.isEmpty {
                return url
            }
            // Also try AXDocument as fallback
            if let url: String = getAttributeValue(element, attribute: kAXDocumentAttribute as CFString), !url.isEmpty {
                return url
            }
        }

        // Recurse into children
        guard let children: [AXUIElement] = getAttributeValue(element, attribute: kAXChildrenAttribute as CFString) else {
            return nil
        }

        for child in children {
            if let url = findURLInWebArea(child, depth: depth + 1) {
                return url
            }
        }

        return nil
    }

    // MARK: - AppleScript Methods

    private func getFirefoxURLViaAppleScript() -> String? {
        // Method 1: Try direct AppleScript API
        if let url = runAppleScript("""
            tell application "Firefox"
                if (count of windows) > 0 then
                    get URL of active tab of front window
                end if
            end tell
            """) {
            return url
        }

        // Method 2: Clipboard hack via System Events (Cmd+L, Cmd+C)
        return runAppleScript("""
            set theClipboard to (the clipboard as record)
            set the clipboard to ""

            tell application "System Events"
                set frontmost of application process "firefox" to true
                keystroke "l" using {command down}
                delay 0.05
                keystroke "c" using {command down}
            end tell

            delay 0.1
            set theURL to (the clipboard)
            set the clipboard to theClipboard
            return theURL
            """)
    }

    private func getArcURLViaAppleScript() -> String? {
        // Try method 1: Standard AppleScript
        if let url = runAppleScript("""
            tell application "Arc"
                if (count of windows) > 0 then
                    get URL of active tab of front window
                end if
            end tell
            """) {
            return url
        }

        // Try method 2: Alternative syntax
        return runAppleScript("""
            tell application "Arc"
                if (count of windows) > 0 then
                    get URL of current tab of window 1
                end if
            end tell
            """)
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    // MARK: - Deep Search Helpers

    private func findURLInElement(_ element: AXUIElement, depth: Int, maxDepth: Int) -> String? {
        guard depth < maxDepth else { return nil }

        // Check if this element has a URL attribute
        if let url: String = getAttributeValue(element, attribute: kAXURLAttribute as CFString), !url.isEmpty {
            return url
        }

        // Check if this is a text field that might contain the URL
        if let role: String = getAttributeValue(element, attribute: kAXRoleAttribute as CFString),
           role == kAXTextFieldRole as String,
           let value: String = getAttributeValue(element, attribute: kAXValueAttribute as CFString),
           looksLikeURL(value) {
            return value
        }

        // Recursively check children
        if let children: [AXUIElement] = getAttributeValue(element, attribute: kAXChildrenAttribute as CFString) {
            for child in children.prefix(25) {
                if let url = findURLInElement(child, depth: depth + 1, maxDepth: maxDepth) {
                    return url
                }
            }
        }

        return nil
    }

    private func looksLikeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") ||
               trimmed.hasPrefix("https://") ||
               trimmed.hasPrefix("file://") ||
               (trimmed.contains(".") && !trimmed.contains(" ") && trimmed.count > 4)
    }

    // MARK: - Debug Helpers

    private func inspectAllAttributes(_ element: AXUIElement) {
        var attributeNames: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &attributeNames)

        guard result == .success, let attributes = attributeNames as? [String] else {
            verboseLog("  Failed to get attribute names")
            return
        }

        verboseLog("  Available attributes (\(attributes.count)):")
        for attr in attributes {
            var value: AnyObject?
            let valueResult = AXUIElementCopyAttributeValue(element, attr as CFString, &value)

            if valueResult == .success, let val = value {
                let valueStr = String(describing: val)
                let truncated = valueStr.prefix(100)
                verboseLog("    \(attr) = \(truncated)")
            }
        }
    }

    private func verboseLog(_ message: String) {
        guard verboseLogging else { return }
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
        if let title = title { output += " title=\"\(title.prefix(30))\"" }
        if let value = value { output += " value=\"\(value.prefix(50))\"" }
        if let description = description { output += " desc=\"\(description.prefix(30))\"" }
        verboseLog(output)

        if let children: [AXUIElement] = getAttributeValue(element, attribute: kAXChildrenAttribute as CFString) {
            for child in children.prefix(15).enumerated() {
                debugPrintElement(child.element, depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }

    // MARK: - Chrome Text Extraction

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
    let urlExtractionMethod: String?
    let chromeText: String?
}
