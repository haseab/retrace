import Foundation
import ApplicationServices
import Shared

/// Extracts the current URL from supported web browsers
/// Requires Accessibility permission
///
/// Strategy by browser:
/// - Safari: AXToolbar → AXTextField (address bar value)
/// - Chrome/Edge/Brave: AXDocument attribute on window, with AXManualAccessibility fallback
/// - Arc: AppleScript (Chromium-based but AX tree often incomplete)
/// - Firefox: AppleScript (Gecko doesn't expose URL via AX)
/// - Generic fallback: Find AXWebArea element and read AXURL attribute
struct BrowserURLExtractor: Sendable {

    // MARK: - Known Browser Bundle IDs

    private static let knownBrowsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",  // Arc
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.nickvision.browser",      // GNOME Web
        "com.openai.chat",             // ChatGPT desktop app
        "com.cometbrowser.Comet",      // Comet Browser
        "com.aspect.browser",          // Dia Browser
        "org.chromium.Chromium",       // Chromium
        "com.sigmaos.sigmaos",         // SigmaOS
        "com.nicklockwood.Duckduckgo", // DuckDuckGo
        "com.duckduckgo.macos.browser", // DuckDuckGo (alternate)
        "com.nicklockwood.iCab",       // iCab
        "de.icab.iCab",                // iCab (alternate)
        "com.nicklockwood.OmniWeb",    // OmniWeb
        "org.webkit.MiniBrowser",      // WebKit MiniBrowser
        "com.nicklockwood.Orion",      // Orion
        "com.nicklockwood.Waterfox",   // Waterfox
        "net.nicklockwood.Waterfox",   // Waterfox (alternate)
        "org.nicklockwood.LibreWolf",  // LibreWolf
        "io.nicklockwood.librewolf",   // LibreWolf (alternate)
        "com.nicklockwood.Thorium",    // Thorium
        "com.nicklockwood.Zen",        // Zen Browser
        "com.nicklockwood.Floorp",     // Floorp
    ]

    /// Check if a bundle ID is a known browser
    static func isBrowser(_ bundleID: String) -> Bool {
        knownBrowsers.contains(bundleID)
    }

    // MARK: - URL Extraction

    /// Get the current URL from a browser
    /// - Parameters:
    ///   - bundleID: Browser bundle identifier
    ///   - pid: Process ID of the browser
    /// - Returns: Current URL if available
    ///
    /// Uses browser-specific strategies with fallbacks:
    /// 1. Browser-specific method (AX attributes or AppleScript)
    /// 2. Generic AXWebArea → AXURL traversal
    /// 3. Address bar text field search
    static func getURL(bundleID: String, pid: pid_t) -> String? {
        // Try browser-specific method first
        let url: String? = switch bundleID {
        case "com.apple.Safari":
            getSafariURL(pid: pid)
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
             "org.chromium.Chromium", "com.sigmaos.sigmaos", "com.cometbrowser.Comet", "com.aspect.browser",
             "com.openai.chat", "com.nicklockwood.Thorium":
            getChromiumURL(pid: pid)
        case "company.thebrowser.Browser":  // Arc
            getArcURL(pid: pid)
        case "org.mozilla.firefox":
            getFirefoxURL(pid: pid)
        default:
            nil
        }

        if let url = url, !url.isEmpty {
            return url
        }

        // Fallback: Try generic AXWebArea approach for any browser
        return getURLViaWebArea(pid: pid)
    }

    // MARK: - Safari

    /// Extract URL from Safari using Accessibility API
    /// Safari exposes the URL in the address bar text field within the toolbar
    private static func getSafariURL(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)

        // Get focused window
        guard let window: AXUIElement = getAXAttribute(appRef, kAXFocusedWindowAttribute) else {
            return nil
        }

        // Method 1: Try toolbar → text field approach
        if let toolbar: AXUIElement = getAXAttribute(window, "AXToolbar" as CFString),
           let children: [AXUIElement] = getAXAttribute(toolbar, kAXChildrenAttribute) {

            for child in children {
                if let role: String = getAXAttribute(child, kAXRoleAttribute),
                   role == kAXTextFieldRole as String,
                   let url: String = getAXAttribute(child, kAXValueAttribute),
                   !url.isEmpty {
                    return url
                }
            }
        }

        // Method 2: Try AXWebArea → AXURL
        if let url = findURLInWebArea(window) {
            return url
        }

        // Method 3: Deep search for text field with URL
        return findURLInElement(window, depth: 0, maxDepth: 10)
    }

    // MARK: - Chromium-based Browsers (Chrome, Edge, Brave, Vivaldi)

    /// Extract URL from Chromium browsers using AXDocument attribute
    ///
    /// Important: Chromium browsers may not expose the AX tree unless accessibility is enabled.
    /// This can be forced via:
    /// - Command line: --force-renderer-accessibility
    /// - Programmatically: Set AXManualAccessibility = true on the app element
    private static func getChromiumURL(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)

        // Try to enable accessibility on Chromium/Electron apps
        // This sets AXManualAccessibility = true which forces the AX tree to be exposed
        enableAccessibilityIfNeeded(appRef)

        // Get focused window
        guard let window: AXUIElement = getAXAttribute(appRef, kAXFocusedWindowAttribute) else {
            return nil
        }

        // Method 1: AXDocument attribute on window (most reliable for Chrome)
        if let url: String = getAXAttribute(window, kAXDocumentAttribute), !url.isEmpty {
            return url
        }

        // Method 2: Try AXWebArea → AXURL
        if let url = findURLInWebArea(window) {
            return url
        }

        // Method 3: Try focused element's URL attribute
        if let focused: AXUIElement = getAXAttribute(appRef, kAXFocusedUIElementAttribute) {
            if let url: String = getAXAttribute(focused, kAXURLAttribute), !url.isEmpty {
                return url
            }
            if let url: String = getAXAttribute(focused, kAXDocumentAttribute), !url.isEmpty {
                return url
            }
        }

        // Method 4: Deep search for address bar
        return findURLInElement(window, depth: 0, maxDepth: 8)
    }

    // MARK: - Arc Browser

    /// Extract URL from Arc browser
    /// Arc is Chromium-based but often has an incomplete AX tree.
    /// AppleScript is the most reliable method.
    private static func getArcURL(pid: pid_t) -> String? {
        Log.debug("[BrowserURL] Attempting Arc URL extraction via AppleScript", category: .capture)

        // Method 1: AppleScript (most reliable)
        if let url = runAppleScriptViaProcess("""
            tell application "Arc"
                if (count of windows) > 0 then
                    get URL of active tab of front window
                end if
            end tell
            """) {
            Log.info("[BrowserURL] ✅ Arc URL extracted via AppleScript method 1", category: .capture)
            return url
        }

        Log.debug("[BrowserURL] Arc AppleScript method 1 failed, trying method 2", category: .capture)

        // Method 2: Alternative AppleScript syntax
        if let url = runAppleScriptViaProcess("""
            tell application "Arc"
                if (count of windows) > 0 then
                    get URL of current tab of window 1
                end if
            end tell
            """) {
            Log.info("[BrowserURL] ✅ Arc URL extracted via AppleScript method 2", category: .capture)
            return url
        }

        Log.debug("[BrowserURL] Arc AppleScript methods failed, falling back to Chromium AX approach", category: .capture)

        // Method 3: Fall back to Chromium AX approach
        let chromiumResult = getChromiumURL(pid: pid)
        if chromiumResult != nil {
            Log.info("[BrowserURL] ✅ Arc URL extracted via Chromium AX fallback", category: .capture)
        } else {
            Log.warning("[BrowserURL] ❌ All Arc URL extraction methods failed", category: .capture)
        }
        return chromiumResult
    }

    // MARK: - Firefox

    /// Extract URL from Firefox using AppleScript
    /// Firefox (Gecko) doesn't expose the URL via standard AX attributes.
    ///
    /// Note: Firefox's AppleScript support is limited. If this doesn't work,
    /// we fall back to AX text field search in the focused window.
    private static func getFirefoxURL(pid: pid_t) -> String? {
        if let url = runAppleScriptViaProcess("""
            tell application "Firefox"
                if (count of windows) > 0 then
                    get URL of active tab of front window
                end if
            end tell
            """) {
            return url
        }

        Log.debug("[BrowserURL] Firefox AppleScript failed, trying AX text field fallback", category: .capture)

        let appRef = AXUIElementCreateApplication(pid)
        guard let window: AXUIElement = getAXAttribute(appRef, kAXFocusedWindowAttribute) else {
            return nil
        }

        return findURLInElement(window, depth: 0, maxDepth: 12)
    }

    // MARK: - Generic AXWebArea Approach

    /// Find URL by locating AXWebArea element and reading its AXURL attribute
    /// This is the generic approach documented by Apple for web content.
    /// Works when the browser properly exposes its accessibility tree.
    private static func getURLViaWebArea(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)

        guard let window: AXUIElement = getAXAttribute(appRef, kAXFocusedWindowAttribute) else {
            return nil
        }

        return findURLInWebArea(window)
    }

    /// Recursively search for AXWebArea element and extract its AXURL
    private static func findURLInWebArea(_ element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 15 else { return nil }

        // Check if this element is a web area
        if let role: String = getAXAttribute(element, kAXRoleAttribute),
           role == "AXWebArea" {
            // Try AXURL attribute (the documented way)
            if let url: String = getAXAttribute(element, kAXURLAttribute), !url.isEmpty {
                return url
            }
            // Also try AXDocument as fallback
            if let url: String = getAXAttribute(element, kAXDocumentAttribute), !url.isEmpty {
                return url
            }
        }

        // Recurse into children
        guard let children: [AXUIElement] = getAXAttribute(element, kAXChildrenAttribute) else {
            return nil
        }

        for child in children {
            if let url = findURLInWebArea(child, depth: depth + 1) {
                return url
            }
        }

        return nil
    }

    /// Deep search for URL in any text field that looks like a URL
    private static func findURLInElement(_ element: AXUIElement, depth: Int, maxDepth: Int) -> String? {
        guard depth < maxDepth else { return nil }

        // Check for AXURL attribute
        if let url: String = getAXAttribute(element, kAXURLAttribute), !url.isEmpty {
            return url
        }

        // Check if this is a text field with a URL value
        if let role: String = getAXAttribute(element, kAXRoleAttribute),
           role == kAXTextFieldRole as String,
           let value: String = getAXAttribute(element, kAXValueAttribute),
           looksLikeURL(value) {
            return value
        }

        // Recurse into children
        guard let children: [AXUIElement] = getAXAttribute(element, kAXChildrenAttribute) else {
            return nil
        }

        for child in children.prefix(25) {
            if let url = findURLInElement(child, depth: depth + 1, maxDepth: maxDepth) {
                return url
            }
        }

        return nil
    }

    // MARK: - Chromium Accessibility Toggle

    /// Enable accessibility on Chromium/Electron apps by setting AXManualAccessibility
    ///
    /// Chromium and Electron apps don't fully expose their AX tree by default for performance.
    /// Setting AXManualAccessibility = true forces them to build the accessibility tree.
    /// This is the programmatic equivalent of enabling VoiceOver or using Accessibility Inspector.
    private static func enableAccessibilityIfNeeded(_ appElement: AXUIElement) {
        // Check if already accessible by trying to get enhanced user interface
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            &value
        )

        // If we can't read AXEnhancedUserInterface or it's false, try to enable
        if result != .success {
            // Set AXManualAccessibility to true
            // This tells Chromium/Electron to expose the full AX tree
            AXUIElementSetAttributeValue(
                appElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
        }
    }

    // MARK: - Helper Methods

    /// Generic helper to get an AX attribute value (CFString version)
    private static func getAXAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? T
    }

    /// Generic helper to get an AX attribute value (String version)
    private static func getAXAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        return getAXAttribute(element, attribute as CFString)
    }

    /// Check if a string looks like a URL
    private static func looksLikeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") ||
               trimmed.hasPrefix("https://") ||
               trimmed.hasPrefix("file://") ||
               (trimmed.contains(".") && !trimmed.contains(" ") && trimmed.count > 4)
    }

    /// Run an AppleScript in an isolated subprocess and return trimmed stdout.
    /// Note: Requires Automation permission for the target app.
    private static func runAppleScriptViaProcess(_ source: String, timeoutSeconds: TimeInterval = 2.0) -> String? {
        // Never block the main thread on a subprocess wait.
        if Thread.isMainThread {
            Log.warning("[AppleScript] Skipping URL extraction on main thread to avoid UI stalls", category: .capture)
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            Log.error("[AppleScript] Failed to launch osascript subprocess", category: .capture, error: error)
            return nil
        }

        if terminationSemaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            Log.warning("[AppleScript] osascript timed out after \(timeoutSeconds)s - terminating subprocess", category: .capture)
            process.terminate()
            _ = terminationSemaphore.wait(timeout: .now() + 0.2)
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationReason == .uncaughtSignal {
            Log.error("[AppleScript] osascript crashed with signal \(process.terminationStatus)", category: .capture)
            if !stderr.isEmpty {
                Log.error("[AppleScript] osascript stderr: \(stderr)", category: .capture)
            }
            return nil
        }

        guard process.terminationStatus == 0 else {
            Log.error("[AppleScript] osascript failed: \(stderr.isEmpty ? "Unknown error" : stderr) (code: \(process.terminationStatus))", category: .capture)
            if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") {
                Log.error("[AppleScript] ⚠️ Automation permission denied - user needs to grant permission in System Settings → Privacy & Security → Automation", category: .capture)
            }
            return nil
        }

        guard !output.isEmpty else {
            Log.warning("[AppleScript] Script executed but returned empty output", category: .capture)
            return nil
        }

        Log.debug("[AppleScript] Successfully got URL: \(output.prefix(50))...", category: .capture)
        return output
    }

}
