import XCTest
import AppKit
import ApplicationServices
import Shared
@testable import Capture

/// Interactive test to inspect accessibility data from the active window
/// Shows what metadata Retrace can capture for segments and FTS indexing
///
/// Browser URL Extraction Strategy:
/// 1. Safari: AXToolbar → AXTextField (address bar)
/// 2. Chrome/Edge/Brave/Vivaldi: AXDocument on window + AXManualAccessibility toggle
/// 3. Arc: AppleScript (Chromium but AX tree often incomplete)
/// 4. Firefox: Disabled (URL extraction intentionally skipped)
/// 5. Generic fallback: Find AXWebArea and read AXURL attribute
final class AccessibilityInspectorTest: XCTestCase {

    // File handle for logging - make it an instance variable so other methods can access it
    private var logFileHandle: FileHandle?
    private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private let appInfoProvider = AppInfoProvider()

    // Interactive inspector should only run when explicitly opted in.
    private let interactiveInspectorEnabled = ProcessInfo.processInfo.environment["RUN_INTERACTIVE_ACCESSIBILITY_INSPECTOR"] == "1"

    // Set AX_VERBOSE=1 to see detailed extraction attempts (noisy)
    private let verboseLogging = ProcessInfo.processInfo.environment["AX_VERBOSE"] == "1"
    private let defaultKeywordNeedles = ["private", "incognito", "inprivate", "private browsing", "guest", "secret"]
    private let keywordCandidateAttributes: [CFString] = [
        kAXTitleAttribute as CFString,
        kAXValueAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXRoleDescriptionAttribute as CFString,
        kAXDocumentAttribute as CFString,
        "AXHelp" as CFString,
        "AXIdentifier" as CFString,
        "AXLabel" as CFString,
        "AXDOMClassList" as CFString,
        "AXDOMIdentifier" as CFString,
        "AXDOMRole" as CFString,
        "AXDOMTag" as CFString,
    ]

    private lazy var keywordNeedles: [String] = {
        let env = ProcessInfo.processInfo.environment
        let rawNeedles = env["AX_KEYWORD_NEEDLES"] ?? env["AX_TREE_KEYWORDS"] ?? ""
        let parsedNeedles = rawNeedles
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        var deduped = Set<String>()
        let finalNeedles = (parsedNeedles.isEmpty ? defaultKeywordNeedles : parsedNeedles)
            .filter { deduped.insert($0).inserted }
        return finalNeedles
    }()

    func testIsBrowserAppDelegatesToProductionBrowserRecognizer() {
        XCTAssertTrue(isBrowserApp("com.duckduckgo.macos.browser"))
        XCTAssertTrue(isBrowserApp("ai.perplexity.comet"))
        XCTAssertTrue(isBrowserApp("com.google.Chrome.app.cadlkienfkclaiaibeoongdcgmdikeeg"))
        XCTAssertFalse(isBrowserApp("com.apple.finder"))
        XCTAssertFalse(isBrowserApp("com.example.notabrowser"))
    }

    private let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.chromium.Chromium",
        "com.sigmaos.sigmaos.macos",
        "ai.perplexity.comet",
        "company.thebrowser.dia",
        "com.openai.chat",
        "com.nicklockwood.Thorium",
    ]

    private let chromiumAppShimPrefixes: [String] = [
        "com.google.Chrome.app.",
        "com.google.Chrome.canary.app.",
        "com.microsoft.edgemac.app.",
        "com.brave.Browser.app.",
        "com.vivaldi.Vivaldi.app.",
        "com.operasoftware.Opera.app.",
        "org.chromium.Chromium.app.",
        "ai.perplexity.comet.app.",
        "company.thebrowser.dia.app.",
        "com.sigmaos.sigmaos.macos.app.",
        "com.openai.chat.app.",
        "com.nicklockwood.Thorium.app.",
    ]

    /// Run this test and switch between different apps/windows to see what data is captured
    func testShowAccessibilityDataDialog() async throws {
        guard interactiveInspectorEnabled else {
            throw XCTSkip("Interactive-only test. Set RUN_INTERACTIVE_ACCESSIBILITY_INSPECTOR=1 to run manually.")
        }

        // Write to a file in /tmp so you can tail it
        let outputPath = "/tmp/accessibility_test_output.txt"
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: outputPath)!
        defer {
            logFileHandle?.closeFile()
            logFileHandle = nil
        }

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
        log("║  Supported browsers: Safari, Chrome, Edge, Brave, Arc, Dia, Vivaldi         ║")
        log("║                                                                              ║")
        log("║  Output file: \(outputPath)                                 ║")
        log("║  Run: tail -f \(outputPath)                                 ║")
        log("╚══════════════════════════════════════════════════════════════════════════════╝\n")
        log("🔎 AX keyword needles: \(keywordNeedles.joined(separator: ", "))\n")

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
        var lastAXDocument = ""
        var lastAppleScriptModeProbe: AppleScriptModeProbe?
        var lastBodyLinkObservations: [AXLinkObservation] = []
        var lastKeywordObservations: [AXKeywordObservation] = []
        var lastWindowSnapshots: [AXWindowSnapshot] = []

        // Monitor indefinitely until Ctrl+C
        let startTime = Date()
        while !Task.isCancelled {
            if let data = await captureActiveWindowData() {
                // Only print when something changes
                let currentURL = data.browserURL ?? ""
                let currentAXDocument = data.focusedWindowAXDocument ?? ""
                if data.appBundleID != lastAppBundleID ||
                    data.windowTitle != lastWindowTitle ||
                    currentURL != lastBrowserURL ||
                    currentAXDocument != lastAXDocument ||
                    data.appleScriptModeProbe != lastAppleScriptModeProbe ||
                    data.bodyLinkObservations != lastBodyLinkObservations ||
                    data.keywordObservations != lastKeywordObservations ||
                    data.windowSnapshots != lastWindowSnapshots {
                    log("\n⏱  \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
                    log("📱 App Bundle ID:  \(data.appBundleID)")
                    log("📝 App Name:       \(data.appName)")
                    log("🪟 Window Title:   \(data.windowTitle ?? "(none)")")
                    log("🌐 URL:            \(data.browserURL ?? "(URL not found)")")
                    log("🧪 AXDocument:     \(data.focusedWindowAXDocument ?? "(none)")")
                    if let appleScriptModeProbe = data.appleScriptModeProbe {
                        log("🍎 AppleScript Mode: \(appleScriptModeProbe.summary)")
                    } else {
                        log("🍎 AppleScript Mode: (not attempted)")
                    }
                    log("🔗 AX Links:       \(data.uniqueBodyLinks.count) unique URLs (\(data.bodyLinkObservations.count) observations)")
//                    if data.bodyLinkObservations.isEmpty {
//                        log("   (none)")
//                    } else {
//                        for (index, observation) in data.bodyLinkObservations.enumerated() {
//                            log("   [\(index + 1)] \(observation.url)")
//                            log("       attr=\(observation.attribute) role=\(observation.role)\(observation.subrole.map { " subrole=\($0)" } ?? "") inWebArea=\(observation.isWithinWebArea ? "yes" : "no") depth=\(observation.depth)")
//                            log("       path=\(observation.path)")
//                            if let title = observation.titlePreview {
//                                log("       title=\(title)")
//                            }
//                            if let source = observation.sourceTextPreview {
//                                log("       source=\(source)")
//                            }
//                        }
//                    }
                    log("🔎 Keyword Hits:   \(data.keywordObservations.count) observations (\(data.keywordHitsByNeedle.count) needles)")
                    if data.keywordObservations.isEmpty {
                        log("   (none)")
                    } else {
                        for needle in data.keywordHitsByNeedle.keys.sorted() {
                            guard let matches = data.keywordHitsByNeedle[needle] else { continue }
                            log("   \"\(needle)\": \(matches.count) match(es)")
                            for (index, match) in matches.prefix(8).enumerated() {
                                log("       [\(index + 1)] attr=\(match.attribute) role=\(match.role)\(match.subrole.map { " subrole=\($0)" } ?? "") source=\(match.source.rawValue) inWebArea=\(match.isWithinWebArea ? "yes" : "no") depth=\(match.depth)")
                                log("           path=\(match.path)")
                                if let valuePreview = match.valuePreview {
                                    log("           value=\(valuePreview)")
                                }
                            }
                            if matches.count > 8 {
                                log("       ... \(matches.count - 8) additional match(es)")
                            }
                        }
                    }
                    log("🪟 AX Window Snapshots: \(data.windowSnapshots.count)")
                    if data.windowSnapshots.isEmpty {
                        log("   (none)")
                    } else {
                        for (index, snapshot) in data.windowSnapshots.prefix(8).enumerated() {
                            log("   [\(index + 1)] role=\(snapshot.role)\(snapshot.subrole.map { " subrole=\($0)" } ?? "") depth=\(snapshot.depth)")
                            log("       path=\(snapshot.path)")
                            if let title = snapshot.titlePreview {
                                log("       title=\(title)")
                            }
                            if let identifier = snapshot.identifierPreview {
                                log("       identifier=\(identifier)")
                            }
                        }
                        if data.windowSnapshots.count > 8 {
                            log("   ... \(data.windowSnapshots.count - 8) additional window snapshot(s)")
                        }
                    }
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
                    lastAXDocument = currentAXDocument
                    lastAppleScriptModeProbe = data.appleScriptModeProbe
                    lastBodyLinkObservations = data.bodyLinkObservations
                    lastKeywordObservations = data.keywordObservations
                    lastWindowSnapshots = data.windowSnapshots
                }
            }

            try await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous) // Check every 0.5s
        }

        // Note: This code won't be reached, but kept for completeness
        // fileHandle.closeFile()
    }

    // MARK: - Accessibility Data Capture

    private func captureActiveWindowData() async -> AccessibilityData? {
        // Get the frontmost application
        guard let frontApp = await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication
        }) else {
            return nil
        }

        // Mirror production capture so inspector output reflects the same title and URL logic.
        let frontmostAppInfo = await appInfoProvider.getFrontmostAppInfo(includeBrowserURL: true)
        let appBundleID = frontmostAppInfo.appBundleID ?? frontApp.bundleIdentifier ?? "unknown"
        let appName = frontmostAppInfo.appName ?? frontApp.localizedName ?? "Unknown App"

        // Get accessibility element for the app
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var windowTitle = frontmostAppInfo.windowName
        var browserURL = frontmostAppInfo.browserURL
        var urlMethod: String?
        if browserURL != nil {
            urlMethod = productionURLExtractionMethodDescription(for: appBundleID)
        }
        var chromeText: String?
        var focusedWindowAXDocument: String?
        let appleScriptModeProbe = probeAppleScriptMode(for: appBundleID)
        var bodyLinkObservations: [AXLinkObservation] = []
        var keywordObservations: [AXKeywordObservation] = []
        var windowSnapshots: [AXWindowSnapshot] = []

        // Get focused window
        if let focusedWindow: AXUIElement = getAttributeValue(appElement, attribute: kAXFocusedWindowAttribute as CFString) {
            // Direct probe requested for Finder/debugging: raw AXDocument on focused window.
            focusedWindowAXDocument = getAttributeValue(focusedWindow, attribute: kAXDocumentAttribute as CFString)
            if focusedWindowAXDocument?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                focusedWindowAXDocument = nil
            }

            // Mirror production capture for title + browser URL.
            windowTitle = frontmostAppInfo.windowName
            browserURL = frontmostAppInfo.browserURL
            if browserURL != nil {
                urlMethod = productionURLExtractionMethodDescription(for: appBundleID)
            }

            // Keep raw AX probes as a fallback diagnostic only.
            if windowTitle == nil {
                windowTitle = getAttributeValue(focusedWindow, attribute: kAXTitleAttribute as CFString)
            }
            if windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                windowTitle = getWindowTitleFromWindowList(for: frontApp.processIdentifier) ?? appName
            }
            // Chrome text is only meaningful for browser chrome areas
            if isBrowserApp(appBundleID) {
                // Try to get status bar / menu bar text (chrome text)
                chromeText = getChromeText(windowElement: focusedWindow)
            }

            if isBrowserApp(appBundleID) || browserURL != nil {
                let observations = collectAXTreeObservations(
                    focusedWindow,
                    keywordNeedles: keywordNeedles
                )
                bodyLinkObservations = observations.links
                keywordObservations = observations.keywordHits
                windowSnapshots = observations.windowSnapshots
            }
        }

        return AccessibilityData(
            appBundleID: appBundleID,
            appName: appName,
            windowTitle: windowTitle,
            browserURL: browserURL,
            urlExtractionMethod: urlMethod,
            chromeText: chromeText,
            focusedWindowAXDocument: focusedWindowAXDocument,
            appleScriptModeProbe: appleScriptModeProbe,
            bodyLinkObservations: bodyLinkObservations,
            keywordObservations: keywordObservations,
            windowSnapshots: windowSnapshots
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
        BrowserURLExtractor.isBrowser(bundleID)
    }

    private func productionURLExtractionMethodDescription(for bundleID: String) -> String? {
        if bundleID == "com.apple.finder" {
            return "AppInfoProvider -> BrowserURLExtractor.getURL (production Finder path)"
        }
        guard BrowserURLExtractor.isBrowser(bundleID) else {
            return nil
        }
        return "AppInfoProvider -> BrowserURLExtractor.getURL (production capture path)"
    }

    private func isChromiumBundleID(_ bundleID: String) -> Bool {
        if chromiumBundleIDs.contains(bundleID) {
            return true
        }

        return chromiumAppShimPrefixes.contains(where: { bundleID.hasPrefix($0) })
    }

    private func isChromiumAppShim(_ bundleID: String) -> Bool {
        chromiumAppShimPrefixes.contains(where: { bundleID.hasPrefix($0) })
    }

    private func hostBrowserBundleID(forChromiumAppShim bundleID: String) -> String? {
        for prefix in chromiumAppShimPrefixes where bundleID.hasPrefix(prefix) {
            guard prefix.hasSuffix(".app.") else { continue }
            return String(prefix.dropLast(5))
        }
        return nil
    }

    // MARK: - Browser URL Extraction

    private func getBrowserURL(appElement: AXUIElement, window: AXUIElement, bundleID: String) -> (url: String?, method: String?) {
        // Strategy varies by browser type

        if bundleID == "com.apple.finder" {
            return getFinderTargetURL()
        }

        if bundleID == "com.apple.Safari" {
            return getSafariURL(appElement: appElement, window: window)
        }

        if isChromiumBundleID(bundleID) {
            return getChromiumURL(appElement: appElement, window: window, bundleID: bundleID)
        }

        if bundleID == "company.thebrowser.Browser" { // Arc
            return getArcURL(appElement: appElement, window: window)
        }

        if bundleID == "org.mozilla.firefox" {
            return (nil, nil)
        }

        // Generic fallback for unknown browsers
        return getGenericBrowserURL(appElement: appElement, window: window)
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

        // Method 5: AppleScript fallback for Chromium PWA app-shims
        if isChromiumAppShim(bundleID),
           let url = getWebAppURLViaAppleScript(bundleID: bundleID) {
            verboseLog("[\(browserName)] ✅ Got URL via AppleScript app-shim fallback")
            return (url, "\(browserName): AppleScript app-shim")
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

    private func getFinderTargetURL() -> (url: String?, method: String?) {
        verboseLog("[Finder] Attempting URL extraction via target URL...")

        if let url = runAppleScript("""
            tell application id "com.apple.finder"
                if (count of Finder windows) > 0 then
                    set u to URL of target of front Finder window
                    if u is not missing value and u is not "" then
                        return u
                    end if
                end if
                return URL of desktop
            end tell
            """),
           !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            verboseLog("[Finder] ✅ Got URL via target URL")
            return (url, "Finder: AppleScript target URL")
        }

        verboseLog("[Finder] ❌ Target URL extraction failed")
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

    private func getWebAppURLViaAppleScript(bundleID: String) -> String? {
        if let hostBrowserBundleID = hostBrowserBundleID(forChromiumAppShim: bundleID) {
            if let url = runAppleScript("""
                set shimTitle to ""
                tell application id "\(bundleID)"
                    if (count of windows) > 0 then
                        set shimTitle to name of front window
                    end if
                end tell

                if shimTitle is missing value then set shimTitle to ""

                tell application id "\(hostBrowserBundleID)"
                    if (count of windows) = 0 then return ""

                    repeat with w in windows
                        set tabTitle to ""
                        set tabURL to ""
                        try
                            set tabTitle to title of active tab of w
                            set tabURL to URL of active tab of w
                        end try

                        if tabURL is not "" and shimTitle is not "" and tabTitle is not "" then
                            if shimTitle contains tabTitle or tabTitle contains shimTitle then
                                return tabURL
                            end if
                        end if
                    end repeat
                end tell
                """), !url.isEmpty {
                return url
            }
        }

        if let url = runAppleScript("""
            tell application id "\(bundleID)"
                if (count of windows) > 0 then
                    try
                        get URL of active tab of front window
                    on error
                        get URL of current tab of front window
                    end try
                end if
            end tell
            """), !url.isEmpty {
            return url
        }

        return runAppleScript("""
            tell application id "\(bundleID)"
                if (count of windows) > 0 then
                    try
                        get URL of active tab of window 1
                    on error
                        get URL of current tab of window 1
                    end try
                end if
            end tell
            """)
    }

    private func bundleIDForElement(_ appElement: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        return app.bundleIdentifier
    }

    private func runAppleScript(_ source: String) -> String? {
        runAppleScriptDetailed(source).output
    }

    private func runAppleScriptDetailed(_ source: String) -> AppleScriptExecutionResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return AppleScriptExecutionResult(
                output: nil,
                errorCode: nil,
                errorMessage: "Failed to compile AppleScript source"
            )
        }
        let result = script.executeAndReturnError(&error)
        let output = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error {
            return AppleScriptExecutionResult(
                output: nil,
                errorCode: error[NSAppleScript.errorNumber] as? Int,
                errorMessage: makePreview(error[NSAppleScript.errorMessage] as? String, limit: 160)
            )
        }
        return AppleScriptExecutionResult(
            output: output,
            errorCode: nil,
            errorMessage: nil
        )
    }

    private func probeAppleScriptMode(for bundleID: String) -> AppleScriptModeProbe? {
        guard isBrowserApp(bundleID) else { return nil }

        let script = """
            tell application id "\(bundleID)"
                try
                    return (mode of front window) as text
                on error errMsg number errNum
                    if errNum is -1728 then return "__NO_WINDOWS__"
                    return "__MODE_ERROR__:" & (errNum as text) & ":" & errMsg
                end try
            end tell
            """

        let execution = runAppleScriptDetailed(script)

        if let errorCode = execution.errorCode {
            return classifyAppleScriptModeFailure(errorCode: errorCode, errorMessage: execution.errorMessage)
        }

        guard let rawOutput = execution.output, !rawOutput.isEmpty else {
            return AppleScriptModeProbe(status: .emptyResult, mode: nil, errorCode: nil, detail: nil)
        }

        if rawOutput == "__NO_WINDOWS__" {
            return AppleScriptModeProbe(status: .noWindows, mode: nil, errorCode: nil, detail: nil)
        }

        let modeErrorPrefix = "__MODE_ERROR__:"
        if rawOutput.hasPrefix(modeErrorPrefix) {
            let payload = String(rawOutput.dropFirst(modeErrorPrefix.count))
            let components = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let errorCode = components.isEmpty ? nil : Int(components[0])
            let detail = components.count > 1 ? makePreview(String(components[1]), limit: 120) : nil
            return classifyAppleScriptModeFailure(errorCode: errorCode, errorMessage: detail)
        }

        return AppleScriptModeProbe(
            status: .works,
            mode: makePreview(rawOutput, limit: 80),
            errorCode: nil,
            detail: nil
        )
    }

    private func classifyAppleScriptModeFailure(errorCode: Int?, errorMessage: String?) -> AppleScriptModeProbe {
        let detail = makePreview(errorMessage, limit: 120)
        switch errorCode {
        case -1743:
            return AppleScriptModeProbe(
                status: .permissionDenied,
                mode: nil,
                errorCode: errorCode,
                detail: detail
            )
        case -600:
            return AppleScriptModeProbe(
                status: .appUnavailable,
                mode: nil,
                errorCode: errorCode,
                detail: detail
            )
        case -1700, -1708, -1728, -10000:
            return AppleScriptModeProbe(
                status: .unsupported,
                mode: nil,
                errorCode: errorCode,
                detail: detail
            )
        default:
            return AppleScriptModeProbe(
                status: .error,
                mode: nil,
                errorCode: errorCode,
                detail: detail
            )
        }
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

    // MARK: - Full Tree Inspection

    private func collectAXTreeObservations(_ root: AXUIElement, keywordNeedles: [String]) -> AXTreeObservations {
        var linkObservations: [AXLinkObservation] = []
        var seenLinkObservations = Set<AXLinkObservationKey>()
        var keywordObservations: [AXKeywordObservation] = []
        var seenKeywordObservations = Set<AXKeywordObservationKey>()
        var windowSnapshots: [AXWindowSnapshot] = []
        var seenWindowSnapshots = Set<AXWindowSnapshotKey>()
        var visited = Set<UnsafeRawPointer>()
        var visitedCount = 0

        collectTreeObservations(
            in: root,
            depth: 0,
            maxDepth: 40,
            maxNodes: 20_000,
            path: [],
            childIndex: nil,
            isWithinWebArea: false,
            keywordNeedles: keywordNeedles,
            visited: &visited,
            visitedCount: &visitedCount,
            linkObservations: &linkObservations,
            seenLinkObservations: &seenLinkObservations,
            keywordObservations: &keywordObservations,
            seenKeywordObservations: &seenKeywordObservations,
            windowSnapshots: &windowSnapshots,
            seenWindowSnapshots: &seenWindowSnapshots
        )

        return AXTreeObservations(
            links: linkObservations,
            keywordHits: keywordObservations,
            windowSnapshots: windowSnapshots
        )
    }

    private func collectTreeObservations(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        path: [String],
        childIndex: Int?,
        isWithinWebArea: Bool,
        keywordNeedles: [String],
        visited: inout Set<UnsafeRawPointer>,
        visitedCount: inout Int,
        linkObservations: inout [AXLinkObservation],
        seenLinkObservations: inout Set<AXLinkObservationKey>,
        keywordObservations: inout [AXKeywordObservation],
        seenKeywordObservations: inout Set<AXKeywordObservationKey>,
        windowSnapshots: inout [AXWindowSnapshot],
        seenWindowSnapshots: inout Set<AXWindowSnapshotKey>
    ) {
        guard depth <= maxDepth, visitedCount < maxNodes else { return }

        let identity = Unmanaged.passUnretained(element).toOpaque()
        guard !visited.contains(identity) else { return }
        visited.insert(identity)
        visitedCount += 1

        let role: String = getAttributeValue(element, attribute: kAXRoleAttribute as CFString) ?? "unknown"
        let subrole: String? = getAttributeValue(element, attribute: kAXSubroleAttribute as CFString)
        let titlePreview = makePreview(getAttributeValue(element, attribute: kAXTitleAttribute as CFString) as String?)
        let currentPathComponent = makePathComponent(role: role, subrole: subrole, childIndex: childIndex)
        let currentPath = path.isEmpty ? [currentPathComponent] : path + [currentPathComponent]
        let currentWithinWebArea = isWithinWebArea || role == "AXWebArea"
        let identifierPreview = makePreview(getAttributeValue(element, attribute: "AXIdentifier" as CFString) as String?)

        let context = AXLinkObservationContext(
            role: role,
            subrole: subrole,
            titlePreview: titlePreview,
            identifierPreview: identifierPreview,
            path: currentPath.joined(separator: " > "),
            depth: depth,
            isWithinWebArea: currentWithinWebArea
        )

        if role == "AXWindow" {
            let snapshot = AXWindowSnapshot(
                role: role,
                subrole: subrole,
                titlePreview: titlePreview,
                identifierPreview: identifierPreview,
                path: context.path,
                depth: depth
            )
            if seenWindowSnapshots.insert(snapshot.key).inserted {
                windowSnapshots.append(snapshot)
            }
        }

        appendLinkAttribute(kAXURLAttribute as CFString, from: element, context: context, to: &linkObservations, seenObservations: &seenLinkObservations)
        appendLinkAttribute(kAXDocumentAttribute as CFString, from: element, context: context, to: &linkObservations, seenObservations: &seenLinkObservations)
        appendLinkAttribute(kAXValueAttribute as CFString, from: element, context: context, to: &linkObservations, seenObservations: &seenLinkObservations)
        appendLinkAttribute(kAXTitleAttribute as CFString, from: element, context: context, to: &linkObservations, seenObservations: &seenLinkObservations)
        appendLinkAttribute(kAXDescriptionAttribute as CFString, from: element, context: context, to: &linkObservations, seenObservations: &seenLinkObservations)
        appendLinkAttribute("AXHelp" as CFString, from: element, context: context, to: &linkObservations, seenObservations: &seenLinkObservations)

        appendKeywordMatches(
            in: role,
            attribute: kAXRoleAttribute as String,
            source: .attributeValue,
            context: context,
            keywordNeedles: keywordNeedles,
            to: &keywordObservations,
            seenObservations: &seenKeywordObservations
        )
        if let subrole, !subrole.isEmpty {
            appendKeywordMatches(
                in: subrole,
                attribute: kAXSubroleAttribute as String,
                source: .attributeValue,
                context: context,
                keywordNeedles: keywordNeedles,
                to: &keywordObservations,
                seenObservations: &seenKeywordObservations
            )
        }

        for attribute in keywordCandidateAttributes {
            appendKeywordAttribute(
                attribute,
                from: element,
                context: context,
                keywordNeedles: keywordNeedles,
                to: &keywordObservations,
                seenObservations: &seenKeywordObservations
            )
        }
        appendKeywordAttributeNames(
            from: element,
            context: context,
            keywordNeedles: keywordNeedles,
            to: &keywordObservations,
            seenObservations: &seenKeywordObservations
        )

        guard let children: [AXUIElement] = getAttributeValue(element, attribute: kAXChildrenAttribute as CFString) else {
            return
        }

        for (childIndex, child) in children.enumerated() {
            collectTreeObservations(
                in: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                maxNodes: maxNodes,
                path: currentPath,
                childIndex: childIndex,
                isWithinWebArea: currentWithinWebArea,
                keywordNeedles: keywordNeedles,
                visited: &visited,
                visitedCount: &visitedCount,
                linkObservations: &linkObservations,
                seenLinkObservations: &seenLinkObservations,
                keywordObservations: &keywordObservations,
                seenKeywordObservations: &seenKeywordObservations,
                windowSnapshots: &windowSnapshots,
                seenWindowSnapshots: &seenWindowSnapshots
            )
        }
    }

    private func appendLinkAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        context: AXLinkObservationContext,
        to observations: inout [AXLinkObservation],
        seenObservations: inout Set<AXLinkObservationKey>
    ) {
        if let value: String = getAttributeValue(element, attribute: attribute) {
            for candidate in extractURLCandidates(from: value) {
                let observation = AXLinkObservation(
                    url: candidate,
                    attribute: attribute as String,
                    role: context.role,
                    subrole: context.subrole,
                    titlePreview: context.titlePreview,
                    sourceTextPreview: makeSourcePreview(value, extractedURL: candidate),
                    path: context.path,
                    depth: context.depth,
                    isWithinWebArea: context.isWithinWebArea
                )
                guard seenObservations.insert(observation.key).inserted else { continue }
                observations.append(observation)
            }
            return
        }

        if let value: URL = getAttributeValue(element, attribute: attribute) {
            let candidate = value.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return }
            let observation = AXLinkObservation(
                url: candidate,
                attribute: attribute as String,
                role: context.role,
                subrole: context.subrole,
                titlePreview: context.titlePreview,
                sourceTextPreview: nil,
                path: context.path,
                depth: context.depth,
                isWithinWebArea: context.isWithinWebArea
            )
            guard seenObservations.insert(observation.key).inserted else { return }
            observations.append(observation)
            return
        }

        if let value: NSAttributedString = getAttributeValue(element, attribute: attribute) {
            for candidate in extractURLCandidates(from: value.string) {
                let observation = AXLinkObservation(
                    url: candidate,
                    attribute: attribute as String,
                    role: context.role,
                    subrole: context.subrole,
                    titlePreview: context.titlePreview,
                    sourceTextPreview: makeSourcePreview(value.string, extractedURL: candidate),
                    path: context.path,
                    depth: context.depth,
                    isWithinWebArea: context.isWithinWebArea
                )
                guard seenObservations.insert(observation.key).inserted else { continue }
                observations.append(observation)
            }
        }
    }

    private func appendKeywordAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        context: AXLinkObservationContext,
        keywordNeedles: [String],
        to observations: inout [AXKeywordObservation],
        seenObservations: inout Set<AXKeywordObservationKey>
    ) {
        if let value: String = getAttributeValue(element, attribute: attribute) {
            appendKeywordMatches(
                in: value,
                attribute: attribute as String,
                source: .attributeValue,
                context: context,
                keywordNeedles: keywordNeedles,
                to: &observations,
                seenObservations: &seenObservations
            )
            return
        }

        if let value: URL = getAttributeValue(element, attribute: attribute) {
            appendKeywordMatches(
                in: value.absoluteString,
                attribute: attribute as String,
                source: .attributeValue,
                context: context,
                keywordNeedles: keywordNeedles,
                to: &observations,
                seenObservations: &seenObservations
            )
            return
        }

        if let value: NSAttributedString = getAttributeValue(element, attribute: attribute) {
            appendKeywordMatches(
                in: value.string,
                attribute: attribute as String,
                source: .attributeValue,
                context: context,
                keywordNeedles: keywordNeedles,
                to: &observations,
                seenObservations: &seenObservations
            )
            return
        }

        if let value: NSNumber = getAttributeValue(element, attribute: attribute) {
            appendKeywordMatches(
                in: value.stringValue,
                attribute: attribute as String,
                source: .attributeValue,
                context: context,
                keywordNeedles: keywordNeedles,
                to: &observations,
                seenObservations: &seenObservations
            )
        }
    }

    private func appendKeywordAttributeNames(
        from element: AXUIElement,
        context: AXLinkObservationContext,
        keywordNeedles: [String],
        to observations: inout [AXKeywordObservation],
        seenObservations: inout Set<AXKeywordObservationKey>
    ) {
        var attributeNamesRef: CFArray?
        guard AXUIElementCopyAttributeNames(element, &attributeNamesRef) == .success,
              let attributeNames = attributeNamesRef as? [String] else {
            return
        }

        for attributeName in attributeNames {
            let matchedNeedles = matchedNeedles(in: attributeName, keywordNeedles: keywordNeedles)
            guard !matchedNeedles.isEmpty else { continue }

            let valuePreview = getKeywordAttributeNameValuePreview(element: element, attributeName: attributeName)
            for needle in matchedNeedles {
                let observation = AXKeywordObservation(
                    needle: needle,
                    attribute: attributeName,
                    role: context.role,
                    subrole: context.subrole,
                    valuePreview: valuePreview,
                    source: .attributeName,
                    path: context.path,
                    depth: context.depth,
                    isWithinWebArea: context.isWithinWebArea
                )

                guard seenObservations.insert(observation.key).inserted else { continue }
                observations.append(observation)
            }
        }
    }

    private func getKeywordAttributeNameValuePreview(element: AXUIElement, attributeName: String) -> String? {
        var rawValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &rawValue) == .success else {
            return nil
        }

        guard let rawValue else { return nil }

        if let value = rawValue as? String {
            return makePreview(value, limit: 120)
        }
        if let value = rawValue as? URL {
            return makePreview(value.absoluteString, limit: 120)
        }
        if let value = rawValue as? NSAttributedString {
            return makePreview(value.string, limit: 120)
        }
        if let value = rawValue as? NSNumber {
            return value.stringValue
        }

        return makePreview(String(describing: rawValue), limit: 120)
    }

    private func appendKeywordMatches(
        in rawText: String,
        attribute: String,
        source: AXKeywordMatchSource,
        context: AXLinkObservationContext,
        keywordNeedles: [String],
        to observations: inout [AXKeywordObservation],
        seenObservations: inout Set<AXKeywordObservationKey>
    ) {
        let matches = matchedNeedles(in: rawText, keywordNeedles: keywordNeedles)
        guard !matches.isEmpty else { return }

        let valuePreview = makePreview(rawText, limit: 120)
        for needle in matches {
            let observation = AXKeywordObservation(
                needle: needle,
                attribute: attribute,
                role: context.role,
                subrole: context.subrole,
                valuePreview: valuePreview,
                source: source,
                path: context.path,
                depth: context.depth,
                isWithinWebArea: context.isWithinWebArea
            )
            guard seenObservations.insert(observation.key).inserted else { continue }
            observations.append(observation)
        }
    }

    private func matchedNeedles(in rawText: String, keywordNeedles: [String]) -> [String] {
        let normalized = rawText.lowercased()
        guard !normalized.isEmpty else { return [] }

        var matches: [String] = []
        for needle in keywordNeedles where normalized.contains(needle) {
            matches.append(needle)
        }
        return matches
    }

    private func makePathComponent(role: String, subrole: String?, childIndex: Int?) -> String {
        var component = role
        if let subrole, !subrole.isEmpty {
            component += "{\(subrole)}"
        }
        if let childIndex {
            component += "[\(childIndex)]"
        }
        return component
    }

    private func makePreview(_ value: String?, limit: Int = 80) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= limit {
            return collapsed
        }
        return String(collapsed.prefix(limit)) + "..."
    }

    private func makeSourcePreview(_ value: String, extractedURL: String) -> String? {
        let preview = makePreview(value, limit: 120)
        guard let preview, preview != extractedURL else {
            return nil
        }
        return preview
    }

    private func extractURLCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [String] = []
        var seen = Set<String>()

        if let detector = linkDetector {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            for match in detector.matches(in: trimmed, range: range) {
                guard let link = match.url?.absoluteString, !link.isEmpty else { continue }
                if seen.insert(link).inserted {
                    results.append(link)
                }
            }
        }

        let punctuationToTrim = CharacterSet(charactersIn: "[](){}<>,;\"'")
        for rawToken in trimmed.components(separatedBy: .whitespacesAndNewlines) {
            let token = rawToken.trimmingCharacters(in: punctuationToTrim)
            guard !token.isEmpty, looksLikeURL(token) else { continue }
            if seen.insert(token).inserted {
                results.append(token)
            }
        }

        return results
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

    private func getWindowTitleFromWindowList(for pid: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else {
                continue
            }

            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 {
                continue
            }

            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !isOnScreen {
                continue
            }

            if let title = windowInfo[kCGWindowName as String] as? String {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
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
    let focusedWindowAXDocument: String?
    let appleScriptModeProbe: AppleScriptModeProbe?
    let bodyLinkObservations: [AXLinkObservation]
    let keywordObservations: [AXKeywordObservation]
    let windowSnapshots: [AXWindowSnapshot]

    var uniqueBodyLinks: [String] {
        var seen = Set<String>()
        var urls: [String] = []
        for observation in bodyLinkObservations where seen.insert(observation.url).inserted {
            urls.append(observation.url)
        }
        return urls
    }

    var keywordHitsByNeedle: [String: [AXKeywordObservation]] {
        Dictionary(grouping: keywordObservations, by: \.needle)
    }
}

private struct AppleScriptExecutionResult: Hashable {
    let output: String?
    let errorCode: Int?
    let errorMessage: String?
}

private enum AppleScriptModeProbeStatus: String, Hashable {
    case works
    case unsupported
    case permissionDenied
    case appUnavailable
    case noWindows
    case emptyResult
    case error
}

private struct AppleScriptModeProbe: Hashable {
    let status: AppleScriptModeProbeStatus
    let mode: String?
    let errorCode: Int?
    let detail: String?

    var summary: String {
        switch status {
        case .works:
            let normalizedMode = mode?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "works (\(normalizedMode ?? "unknown"))"
        case .unsupported:
            return "unsupported\(errorSuffix)"
        case .permissionDenied:
            return "permission denied\(errorSuffix)"
        case .appUnavailable:
            return "app unavailable\(errorSuffix)"
        case .noWindows:
            return "no windows"
        case .emptyResult:
            return "no result"
        case .error:
            return "error\(errorSuffix)"
        }
    }

    private var errorSuffix: String {
        let codePart = errorCode.map { " [\($0)]" } ?? ""
        let detailPart = detail.map { ": \($0)" } ?? ""
        return codePart + detailPart
    }
}

private struct AXLinkObservationContext {
    let role: String
    let subrole: String?
    let titlePreview: String?
    let identifierPreview: String?
    let path: String
    let depth: Int
    let isWithinWebArea: Bool
}

private struct AXLinkObservationKey: Hashable {
    let url: String
    let attribute: String
    let path: String
}

private struct AXLinkObservation: Hashable {
    let url: String
    let attribute: String
    let role: String
    let subrole: String?
    let titlePreview: String?
    let sourceTextPreview: String?
    let path: String
    let depth: Int
    let isWithinWebArea: Bool

    var key: AXLinkObservationKey {
        AXLinkObservationKey(
            url: url,
            attribute: attribute,
            path: path
        )
    }
}

private struct AXTreeObservations {
    let links: [AXLinkObservation]
    let keywordHits: [AXKeywordObservation]
    let windowSnapshots: [AXWindowSnapshot]
}

private struct AXWindowSnapshotKey: Hashable {
    let path: String
    let titlePreview: String?
    let identifierPreview: String?
}

private struct AXWindowSnapshot: Hashable {
    let role: String
    let subrole: String?
    let titlePreview: String?
    let identifierPreview: String?
    let path: String
    let depth: Int

    var key: AXWindowSnapshotKey {
        AXWindowSnapshotKey(
            path: path,
            titlePreview: titlePreview,
            identifierPreview: identifierPreview
        )
    }
}

private enum AXKeywordMatchSource: String, Hashable {
    case attributeValue
    case attributeName
}

private struct AXKeywordObservationKey: Hashable {
    let needle: String
    let attribute: String
    let source: AXKeywordMatchSource
    let path: String
    let valuePreview: String?
}

private struct AXKeywordObservation: Hashable {
    let needle: String
    let attribute: String
    let role: String
    let subrole: String?
    let valuePreview: String?
    let source: AXKeywordMatchSource
    let path: String
    let depth: Int
    let isWithinWebArea: Bool

    var key: AXKeywordObservationKey {
        AXKeywordObservationKey(
            needle: needle,
            attribute: attribute,
            source: source,
            path: path,
            valuePreview: valuePreview
        )
    }
}
