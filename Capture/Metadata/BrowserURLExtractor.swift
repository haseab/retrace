import Foundation
import ApplicationServices
import Shared

// MARK: - AppleScript Coordination

struct BrowserURLAppleScriptResult: Sendable {
    let output: String?
    let didTimeOut: Bool
    let permissionDenied: Bool
    let completedWithoutTimeout: Bool
    let skippedByCooldown: Bool
    let returnedFromCache: Bool

    init(
        output: String? = nil,
        didTimeOut: Bool = false,
        permissionDenied: Bool = false,
        completedWithoutTimeout: Bool = false,
        skippedByCooldown: Bool = false,
        returnedFromCache: Bool = false
    ) {
        self.output = output
        self.didTimeOut = didTimeOut
        self.permissionDenied = permissionDenied
        self.completedWithoutTimeout = completedWithoutTimeout
        self.skippedByCooldown = skippedByCooldown
        self.returnedFromCache = returnedFromCache
    }
}

struct BrowserURLAppleScriptKey: Hashable, Sendable {
    let bundleID: String
    let pid: pid_t
}

actor BrowserURLAppleScriptCoordinator {
    typealias Runner = @Sendable (
        _ source: String,
        _ browserBundleID: String,
        _ pid: pid_t,
        _ timeoutSeconds: TimeInterval,
        _ isBootstrapTimeout: Bool
    ) async -> BrowserURLAppleScriptResult

    private enum PermissionState: Sendable {
        case unknown
        case settled
    }

    private struct CacheEntry: Sendable {
        let url: String
        let timestamp: Date
    }

    private struct BackoffState: Sendable {
        var timeoutFailures: Int = 0
        var deniedFailures: Int = 0
        var nextAllowedAt: Date?
    }

    private let runner: Runner
    private let bootstrapTimeoutSeconds: TimeInterval
    private let normalTimeoutSeconds: TimeInterval
    private let cacheTTLSeconds: TimeInterval
    private let timeoutBaseBackoffSeconds: TimeInterval
    private let deniedBaseBackoffSeconds: TimeInterval
    private let maxTimeoutBackoffSeconds: TimeInterval
    private let maxDeniedBackoffSeconds: TimeInterval

    private var permissionStateByBrowser: [String: PermissionState] = [:]
    private var inFlight: [BrowserURLAppleScriptKey: Task<BrowserURLAppleScriptResult, Never>] = [:]
    private var cache: [BrowserURLAppleScriptKey: CacheEntry] = [:]
    private var backoffByKey: [BrowserURLAppleScriptKey: BackoffState] = [:]

    init(
        bootstrapTimeoutSeconds: TimeInterval = 45.0,
        normalTimeoutSeconds: TimeInterval = 2.0,
        cacheTTLSeconds: TimeInterval = 3.0,
        timeoutBaseBackoffSeconds: TimeInterval = 2.0,
        deniedBaseBackoffSeconds: TimeInterval = 15.0,
        maxTimeoutBackoffSeconds: TimeInterval = 30.0,
        maxDeniedBackoffSeconds: TimeInterval = 120.0,
        runner: @escaping Runner
    ) {
        self.bootstrapTimeoutSeconds = bootstrapTimeoutSeconds
        self.normalTimeoutSeconds = normalTimeoutSeconds
        self.cacheTTLSeconds = cacheTTLSeconds
        self.timeoutBaseBackoffSeconds = timeoutBaseBackoffSeconds
        self.deniedBaseBackoffSeconds = deniedBaseBackoffSeconds
        self.maxTimeoutBackoffSeconds = maxTimeoutBackoffSeconds
        self.maxDeniedBackoffSeconds = maxDeniedBackoffSeconds
        self.runner = runner
    }

    func execute(source: String, browserBundleID: String, pid: pid_t) async -> BrowserURLAppleScriptResult {
        let key = BrowserURLAppleScriptKey(bundleID: browserBundleID, pid: pid)
        let now = Date()

        if let task = inFlight[key] {
            return await task.value
        }

        if let cached = cache[key], now.timeIntervalSince(cached.timestamp) <= cacheTTLSeconds {
            return BrowserURLAppleScriptResult(
                output: cached.url,
                completedWithoutTimeout: true,
                returnedFromCache: true
            )
        }

        if let nextAllowedAt = backoffByKey[key]?.nextAllowedAt, nextAllowedAt > now {
            return BrowserURLAppleScriptResult(skippedByCooldown: true)
        }

        let permissionState = permissionStateByBrowser[browserBundleID] ?? .unknown
        let isBootstrapTimeout = permissionState == .unknown
        let timeoutSeconds = isBootstrapTimeout ? bootstrapTimeoutSeconds : normalTimeoutSeconds

        let task = Task<BrowserURLAppleScriptResult, Never> {
            await runner(source, browserBundleID, pid, timeoutSeconds, isBootstrapTimeout)
        }
        inFlight[key] = task
        defer {
            inFlight.removeValue(forKey: key)
        }

        let result = await task.value

        if result.completedWithoutTimeout {
            permissionStateByBrowser[browserBundleID] = .settled
        }

        if let output = result.output, !output.isEmpty {
            cache[key] = CacheEntry(url: output, timestamp: Date())
            backoffByKey.removeValue(forKey: key)
            return result
        }

        if result.didTimeOut || result.permissionDenied {
            var backoff = backoffByKey[key] ?? BackoffState()

            if result.didTimeOut {
                backoff.timeoutFailures += 1
                backoff.deniedFailures = 0
                let delay = min(
                    maxTimeoutBackoffSeconds,
                    timeoutBaseBackoffSeconds * pow(2.0, Double(max(0, backoff.timeoutFailures - 1)))
                )
                backoff.nextAllowedAt = now.addingTimeInterval(delay)
            } else if result.permissionDenied {
                backoff.deniedFailures += 1
                let delay = min(
                    maxDeniedBackoffSeconds,
                    deniedBaseBackoffSeconds * pow(2.0, Double(max(0, backoff.deniedFailures - 1)))
                )
                backoff.nextAllowedAt = now.addingTimeInterval(delay)
            }

            backoffByKey[key] = backoff
        }

        return result
    }
}

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

    /// Browser bundle IDs matched exactly.
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

    /// Chromium app-shim bundle IDs (PWAs/installed web apps).
    /// Examples: com.google.Chrome.app.<id>, com.brave.Browser.app.<id>
    private static let chromiumAppShimPrefixes: [String] = [
        "com.google.Chrome.app.",
        "com.google.Chrome.canary.app.",
        "com.microsoft.edgemac.app.",
        "com.brave.Browser.app.",
        "com.vivaldi.Vivaldi.app.",
        "com.operasoftware.Opera.app.",
        "org.chromium.Chromium.app.",
        "com.cometbrowser.Comet.app.",
        "com.aspect.browser.app.",
        "com.sigmaos.sigmaos.app.",
        "com.openai.chat.app.",
        "com.nicklockwood.Thorium.app.",
    ]

    /// Exact IDs that should use the Chromium extraction path.
    private static let chromiumExactBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.chromium.Chromium",
        "com.sigmaos.sigmaos",
        "com.cometbrowser.Comet",
        "com.aspect.browser",
        "com.openai.chat",
        "com.nicklockwood.Thorium",
    ]

    private static let appleScriptCoordinator = BrowserURLAppleScriptCoordinator(
        runner: { source, browserBundleID, pid, timeoutSeconds, isBootstrapTimeout in
            await runAppleScriptViaProcess(
                source,
                browserBundleID: browserBundleID,
                pid: pid,
                timeoutSeconds: timeoutSeconds,
                isBootstrapTimeout: isBootstrapTimeout
            )
        }
    )

    /// Check if a bundle ID is a known browser
    static func isBrowser(_ bundleID: String) -> Bool {
        if knownBrowsers.contains(bundleID) {
            return true
        }

        return chromiumAppShimPrefixes.contains(where: { bundleID.hasPrefix($0) })
    }

    /// Check whether a bundle ID should use Chromium-specific URL extraction.
    private static func isChromiumBrowser(_ bundleID: String) -> Bool {
        if chromiumExactBundleIDs.contains(bundleID) {
            return true
        }

        return chromiumAppShimPrefixes.contains(where: { bundleID.hasPrefix($0) })
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
    static func getURL(bundleID: String, pid: pid_t) async -> String? {
        // Try browser-specific method first
        let url: String?
        if bundleID == "com.apple.Safari" {
            url = getSafariURL(pid: pid)
        } else if isChromiumBrowser(bundleID) {
            url = getChromiumURL(pid: pid)
        } else if bundleID == "company.thebrowser.Browser" { // Arc
            url = await getArcURL(pid: pid)
        } else if bundleID == "org.mozilla.firefox" {
            url = await getFirefoxURL(pid: pid)
        } else {
            url = nil
        }

        if let url = url, !url.isEmpty {
            return url
        }

        // Fallback: Try generic AX-based URL extraction for any app
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
    private static func getArcURL(pid: pid_t) async -> String? {
        Log.debug("[BrowserURL] Attempting Arc URL extraction via AppleScript", category: .capture)

        // Method 1: AppleScript (most reliable)
        let arcBundleID = "company.thebrowser.Browser"
        let method1Result = await appleScriptCoordinator.execute(
            source:
            """
            tell application "Arc"
                if (count of windows) > 0 then
                    get URL of active tab of front window
                end if
            end tell
            """,
            browserBundleID: arcBundleID,
            pid: pid
        )
        if let url = method1Result.output {
            let source = method1Result.returnedFromCache ? "cache" : "AppleScript method 1"
            Log.info("[BrowserURL] ✅ Arc URL extracted via \(source)", category: .capture)
            return url
        }

        if method1Result.skippedByCooldown {
            Log.debug("[BrowserURL] Arc AppleScript in cooldown; skipping launch in this capture cycle", category: .capture)
        } else if method1Result.didTimeOut {
            Log.warning("[BrowserURL] Arc AppleScript method 1 timed out; skipping method 2 for this capture cycle", category: .capture)
        } else {
            Log.debug("[BrowserURL] Arc AppleScript method 1 failed, trying method 2", category: .capture)

            // Method 2: Alternative AppleScript syntax
            let method2Result = await appleScriptCoordinator.execute(
                source:
                """
                tell application "Arc"
                    if (count of windows) > 0 then
                        get URL of current tab of window 1
                    end if
                end tell
                """,
                browserBundleID: arcBundleID,
                pid: pid
            )
            if let url = method2Result.output {
                let source = method2Result.returnedFromCache ? "cache" : "AppleScript method 2"
                Log.info("[BrowserURL] ✅ Arc URL extracted via \(source)", category: .capture)
                return url
            }
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
    private static func getFirefoxURL(pid: pid_t) async -> String? {
        let firefoxBundleID = "org.mozilla.firefox"
        let appleScriptResult = await appleScriptCoordinator.execute(
            source:
            """
            tell application "Firefox"
                if (count of windows) > 0 then
                    get URL of active tab of front window
                end if
            end tell
            """,
            browserBundleID: firefoxBundleID,
            pid: pid
        )
        if let url = appleScriptResult.output {
            return url
        }

        if appleScriptResult.skippedByCooldown {
            Log.debug("[BrowserURL] Firefox AppleScript in cooldown; skipping launch in this capture cycle", category: .capture)
        } else if appleScriptResult.didTimeOut {
            Log.warning("[BrowserURL] Firefox AppleScript timed out; retry will use bootstrap timeout until permission settles", category: .capture)
        }

        Log.debug("[BrowserURL] Firefox AppleScript failed, trying AX text field fallback", category: .capture)

        let appRef = AXUIElementCreateApplication(pid)
        guard let window: AXUIElement = getAXAttribute(appRef, kAXFocusedWindowAttribute) else {
            return nil
        }

        return findURLInElement(window, depth: 0, maxDepth: 12)
    }

    // MARK: - Generic AXWebArea Approach

    /// Find URL using generic AX traversal.
    /// This path is intentionally app-agnostic and can return URL context from
    /// non-browser apps that embed webviews (e.g. Electron apps).
    private static func getURLViaWebArea(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        enableAccessibilityIfNeeded(appRef)

        guard let window: AXUIElement = getAXAttribute(appRef, kAXFocusedWindowAttribute) else {
            return nil
        }

        // Method 1: AXWebArea traversal
        if let url = findURLInWebArea(window) {
            return url
        }

        // Method 2: Focused element direct URL/document attributes
        if let focused: AXUIElement = getAXAttribute(appRef, kAXFocusedUIElementAttribute) {
            if let url: String = getAXAttribute(focused, kAXURLAttribute), !url.isEmpty {
                return url
            }
            if let url: String = getAXAttribute(focused, kAXDocumentAttribute), !url.isEmpty {
                return url
            }
        }

        // Method 3: Lightweight deep search for URL-like fields
        return findURLInElement(window, depth: 0, maxDepth: 6)
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

    /// Run AppleScript in an isolated subprocess and return trimmed stdout.
    /// This path is fully async and avoids blocking with semaphore waits.
    private static func runAppleScriptViaProcess(
        _ source: String,
        browserBundleID: String,
        pid: pid_t,
        timeoutSeconds: TimeInterval,
        isBootstrapTimeout: Bool
    ) async -> BrowserURLAppleScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            Log.error("[AppleScript] [\(browserBundleID)] Failed to launch osascript subprocess", category: .capture, error: error)
            return BrowserURLAppleScriptResult()
        }

        let didTimeout = await waitForProcessExitOrTimeout(
            process: process,
            timeoutSeconds: timeoutSeconds
        )
        if didTimeout {
            let mode = isBootstrapTimeout ? "bootstrap timeout" : "normal timeout"
            Log.warning("[AppleScript] [\(browserBundleID):\(pid)] osascript timed out after \(timeoutSeconds)s (\(mode)) - terminating subprocess", category: .capture)
            process.terminate()
            await waitForProcessExit(process)
            return BrowserURLAppleScriptResult(didTimeOut: true)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationReason == .uncaughtSignal {
            Log.error("[AppleScript] [\(browserBundleID)] osascript crashed with signal \(process.terminationStatus)", category: .capture)
            if !stderr.isEmpty {
                Log.error("[AppleScript] [\(browserBundleID)] osascript stderr: \(stderr)", category: .capture)
            }
            return BrowserURLAppleScriptResult(completedWithoutTimeout: true)
        }

        guard process.terminationStatus == 0 else {
            Log.error("[AppleScript] [\(browserBundleID)] osascript failed: \(stderr.isEmpty ? "Unknown error" : stderr) (code: \(process.terminationStatus))", category: .capture)
            let permissionDenied = stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized")
            if permissionDenied {
                Log.error("[AppleScript] ⚠️ Automation permission denied - user needs to grant permission in System Settings → Privacy & Security → Automation", category: .capture)
            }
            return BrowserURLAppleScriptResult(
                permissionDenied: permissionDenied,
                completedWithoutTimeout: true
            )
        }

        guard !output.isEmpty else {
            Log.warning("[AppleScript] [\(browserBundleID)] Script executed but returned empty output", category: .capture)
            return BrowserURLAppleScriptResult(completedWithoutTimeout: true)
        }

        Log.debug("[AppleScript] [\(browserBundleID)] Successfully got URL: \(output.prefix(50))...", category: .capture)
        return BrowserURLAppleScriptResult(
            output: output,
            completedWithoutTimeout: true
        )
    }

    private static func waitForProcessExit(_ process: Process) async {
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }
    }

    private static func waitForProcessExitOrTimeout(
        process: Process,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        final class ResumeState {
            private var hasResumed = false
            private let lock = NSLock()

            func resumeOnce(_ continuation: CheckedContinuation<Bool, Never>, value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: value)
            }
        }

        let state = ResumeState()

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                state.resumeOnce(continuation, value: false)
            }

            if !process.isRunning {
                state.resumeOnce(continuation, value: false)
                return
            }

            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds), clock: .continuous)
                state.resumeOnce(continuation, value: true)
            }
        }
    }

}
