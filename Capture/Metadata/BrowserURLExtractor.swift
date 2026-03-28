import Foundation
import ApplicationServices
import Darwin
import Shared

// MARK: - AppleScript Coordination

struct BrowserURLAppleScriptResult: Sendable {
    let output: String?
    let didTimeOut: Bool
    let permissionDenied: Bool
    let completedWithoutTimeout: Bool
    let skippedByCooldown: Bool
    let returnedFromCache: Bool
    let scriptSyntaxError: Bool
    let failureCode: Int?
    let elapsedMs: Double?

    init(
        output: String? = nil,
        didTimeOut: Bool = false,
        permissionDenied: Bool = false,
        completedWithoutTimeout: Bool = false,
        skippedByCooldown: Bool = false,
        returnedFromCache: Bool = false,
        scriptSyntaxError: Bool = false,
        failureCode: Int? = nil,
        elapsedMs: Double? = nil
    ) {
        self.output = output
        self.didTimeOut = didTimeOut
        self.permissionDenied = permissionDenied
        self.completedWithoutTimeout = completedWithoutTimeout
        self.skippedByCooldown = skippedByCooldown
        self.returnedFromCache = returnedFromCache
        self.scriptSyntaxError = scriptSyntaxError
        self.failureCode = failureCode
        self.elapsedMs = elapsedMs
    }
}

struct BrowserURLAppleScriptKey: Hashable, Sendable {
    let bundleID: String
    let pid: pid_t
    let windowIdentity: String
}

struct BrowserURLAppleScriptBenchmarkSnapshot: Sendable {
    let periodStart: Date
    let periodEnd: Date
    let periodDurationSeconds: TimeInterval
    let attempts: Int
    let subprocessLaunches: Int
    let cacheHits: Int
    let inFlightJoins: Int
    let cooldownSkips: Int
    let successes: Int
    let failures: Int
    let timeouts: Int
    let permissionDenied: Int
    let syntaxErrors: Int
    let emptyOutputs: Int
    let launchesByBundle: [String: Int]
}

actor BrowserURLAppleScriptCoordinator {
    typealias Runner = @Sendable (
        _ source: String,
        _ browserBundleID: String,
        _ pid: pid_t,
        _ timeoutSeconds: TimeInterval,
        _ isBootstrapTimeout: Bool,
        _ scriptLabel: String
    ) async -> BrowserURLAppleScriptResult

    private enum PermissionState: Sendable {
        case unknown
        case settled
    }

    private struct CacheEntry: Sendable {
        let url: String
        let expiresAt: Date
    }

    private struct BackoffState: Sendable {
        var timeoutFailures: Int = 0
        var deniedFailures: Int = 0
        var syntaxFailures: Int = 0
        var nextAllowedAt: Date?
    }

    private struct BenchmarkCounters: Sendable {
        var periodStart: Date = Date()
        var attempts: Int = 0
        var subprocessLaunches: Int = 0
        var cacheHits: Int = 0
        var inFlightJoins: Int = 0
        var cooldownSkips: Int = 0
        var successes: Int = 0
        var failures: Int = 0
        var timeouts: Int = 0
        var permissionDenied: Int = 0
        var syntaxErrors: Int = 0
        var emptyOutputs: Int = 0
        var launchesByBundle: [String: Int] = [:]
    }

    private let runner: Runner
    private let bootstrapTimeoutSeconds: TimeInterval
    private let normalTimeoutSeconds: TimeInterval
    private let cacheTTLSeconds: TimeInterval
    private let timeoutBaseBackoffSeconds: TimeInterval
    private let deniedBaseBackoffSeconds: TimeInterval
    private let syntaxBaseBackoffSeconds: TimeInterval
    private let maxTimeoutBackoffSeconds: TimeInterval
    private let maxDeniedBackoffSeconds: TimeInterval
    private let maxSyntaxBackoffSeconds: TimeInterval
    private let benchmarkLogIntervalSeconds: TimeInterval

    private var permissionStateByBrowser: [String: PermissionState] = [:]
    private var inFlight: [BrowserURLAppleScriptKey: Task<BrowserURLAppleScriptResult, Never>] = [:]
    private var cache: [BrowserURLAppleScriptKey: CacheEntry] = [:]
    private var backoffByKey: [BrowserURLAppleScriptKey: BackoffState] = [:]
    private var benchmark = BenchmarkCounters()

    init(
        bootstrapTimeoutSeconds: TimeInterval = 45.0,
        normalTimeoutSeconds: TimeInterval = 2.0,
        cacheTTLSeconds: TimeInterval = 3.0,
        timeoutBaseBackoffSeconds: TimeInterval = 2.0,
        deniedBaseBackoffSeconds: TimeInterval = 15.0,
        syntaxBaseBackoffSeconds: TimeInterval = 15.0,
        maxTimeoutBackoffSeconds: TimeInterval = 30.0,
        maxDeniedBackoffSeconds: TimeInterval = 120.0,
        maxSyntaxBackoffSeconds: TimeInterval = 300.0,
        benchmarkLogIntervalSeconds: TimeInterval = 30.0,
        runner: @escaping Runner
    ) {
        self.bootstrapTimeoutSeconds = bootstrapTimeoutSeconds
        self.normalTimeoutSeconds = normalTimeoutSeconds
        self.cacheTTLSeconds = cacheTTLSeconds
        self.timeoutBaseBackoffSeconds = timeoutBaseBackoffSeconds
        self.deniedBaseBackoffSeconds = deniedBaseBackoffSeconds
        self.syntaxBaseBackoffSeconds = syntaxBaseBackoffSeconds
        self.maxTimeoutBackoffSeconds = maxTimeoutBackoffSeconds
        self.maxDeniedBackoffSeconds = maxDeniedBackoffSeconds
        self.maxSyntaxBackoffSeconds = maxSyntaxBackoffSeconds
        self.benchmarkLogIntervalSeconds = benchmarkLogIntervalSeconds
        self.runner = runner
    }

    func execute(
        source: String,
        browserBundleID: String,
        pid: pid_t,
        windowCacheKey: String? = nil,
        scriptLabel: String = "unspecified",
        cacheTTLOverrideSeconds: TimeInterval? = nil,
        outputValidator: @Sendable (String) -> Bool = { _ in true }
    ) async -> BrowserURLAppleScriptResult {
        let normalizedWindowIdentity = windowCacheKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let key = BrowserURLAppleScriptKey(
            bundleID: browserBundleID,
            pid: pid,
            windowIdentity: normalizedWindowIdentity
        )
        let now = Date()
        maybeEmitBenchmarkLogIfNeeded(now: now)
        benchmark.attempts += 1
        pruneExpiredEntries(now: now)
        let effectiveCacheTTL = max(0, cacheTTLOverrideSeconds ?? cacheTTLSeconds)

        if let task = inFlight[key] {
            benchmark.inFlightJoins += 1
            return await task.value
        }

        if let cached = cache[key], cached.expiresAt > now {
            benchmark.cacheHits += 1
            return BrowserURLAppleScriptResult(
                output: cached.url,
                completedWithoutTimeout: true,
                returnedFromCache: true
            )
        }

        if let nextAllowedAt = backoffByKey[key]?.nextAllowedAt, nextAllowedAt > now {
            benchmark.cooldownSkips += 1
            return BrowserURLAppleScriptResult(skippedByCooldown: true)
        }

        let permissionState = permissionStateByBrowser[browserBundleID] ?? .unknown
        let isBootstrapTimeout = permissionState == .unknown
        let timeoutSeconds = isBootstrapTimeout ? bootstrapTimeoutSeconds : normalTimeoutSeconds
        benchmark.subprocessLaunches += 1
        benchmark.launchesByBundle[browserBundleID, default: 0] += 1

        let task = Task<BrowserURLAppleScriptResult, Never> {
            await runner(
                source,
                browserBundleID,
                pid,
                timeoutSeconds,
                isBootstrapTimeout,
                scriptLabel
            )
        }
        inFlight[key] = task
        defer {
            inFlight.removeValue(forKey: key)
        }

        let result = await task.value

        if result.completedWithoutTimeout {
            permissionStateByBrowser[browserBundleID] = .settled
        }

        if let rawOutput = result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawOutput.isEmpty,
           outputValidator(rawOutput) {
            benchmark.successes += 1
            cache[key] = CacheEntry(
                url: rawOutput,
                expiresAt: now.addingTimeInterval(effectiveCacheTTL)
            )
            backoffByKey.removeValue(forKey: key)
            return BrowserURLAppleScriptResult(
                output: rawOutput,
                didTimeOut: result.didTimeOut,
                permissionDenied: result.permissionDenied,
                completedWithoutTimeout: result.completedWithoutTimeout,
                skippedByCooldown: result.skippedByCooldown,
                returnedFromCache: result.returnedFromCache,
                scriptSyntaxError: result.scriptSyntaxError,
                failureCode: result.failureCode,
                elapsedMs: result.elapsedMs
            )
        }

        benchmark.failures += 1
        if result.didTimeOut {
            benchmark.timeouts += 1
        }
        if result.permissionDenied {
            benchmark.permissionDenied += 1
        }
        if result.scriptSyntaxError {
            benchmark.syntaxErrors += 1
        }
        if !result.didTimeOut && !result.permissionDenied && !result.scriptSyntaxError {
            benchmark.emptyOutputs += 1
        }

        if result.didTimeOut || result.permissionDenied || result.scriptSyntaxError {
            var backoff = backoffByKey[key] ?? BackoffState()

            if result.didTimeOut {
                backoff.timeoutFailures += 1
                backoff.deniedFailures = 0
                backoff.syntaxFailures = 0
                let delay = min(
                    maxTimeoutBackoffSeconds,
                    timeoutBaseBackoffSeconds * pow(2.0, Double(max(0, backoff.timeoutFailures - 1)))
                )
                backoff.nextAllowedAt = now.addingTimeInterval(delay)
            } else if result.permissionDenied {
                backoff.deniedFailures += 1
                backoff.timeoutFailures = 0
                backoff.syntaxFailures = 0
                let delay = min(
                    maxDeniedBackoffSeconds,
                    deniedBaseBackoffSeconds * pow(2.0, Double(max(0, backoff.deniedFailures - 1)))
                )
                backoff.nextAllowedAt = now.addingTimeInterval(delay)
            } else if result.scriptSyntaxError {
                backoff.syntaxFailures += 1
                backoff.timeoutFailures = 0
                backoff.deniedFailures = 0
                let delay = min(
                    maxSyntaxBackoffSeconds,
                    syntaxBaseBackoffSeconds * pow(2.0, Double(max(0, backoff.syntaxFailures - 1)))
                )
                backoff.nextAllowedAt = now.addingTimeInterval(delay)
            }
            backoffByKey[key] = backoff
        }

        return result
    }

    func benchmarkSnapshot(reset: Bool = false) -> BrowserURLAppleScriptBenchmarkSnapshot {
        let now = Date()
        let snapshot = BrowserURLAppleScriptBenchmarkSnapshot(
            periodStart: benchmark.periodStart,
            periodEnd: now,
            periodDurationSeconds: max(0, now.timeIntervalSince(benchmark.periodStart)),
            attempts: benchmark.attempts,
            subprocessLaunches: benchmark.subprocessLaunches,
            cacheHits: benchmark.cacheHits,
            inFlightJoins: benchmark.inFlightJoins,
            cooldownSkips: benchmark.cooldownSkips,
            successes: benchmark.successes,
            failures: benchmark.failures,
            timeouts: benchmark.timeouts,
            permissionDenied: benchmark.permissionDenied,
            syntaxErrors: benchmark.syntaxErrors,
            emptyOutputs: benchmark.emptyOutputs,
            launchesByBundle: benchmark.launchesByBundle
        )
        if reset {
            benchmark = BenchmarkCounters(periodStart: now)
        }
        return snapshot
    }

    private func maybeEmitBenchmarkLogIfNeeded(now: Date) {
        guard benchmarkLogIntervalSeconds > 0 else { return }
        let elapsed = now.timeIntervalSince(benchmark.periodStart)
        guard elapsed >= benchmarkLogIntervalSeconds else { return }

        if benchmark.attempts > 0 || benchmark.subprocessLaunches > 0 {
            let launchRate = benchmark.subprocessLaunches > 0 ? Double(benchmark.subprocessLaunches) / max(elapsed, 0.001) : 0
            let cacheHitRate = benchmark.attempts > 0 ? (Double(benchmark.cacheHits) / Double(benchmark.attempts)) * 100.0 : 0
            let topBundles = benchmark.launchesByBundle
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key < rhs.key }
                    return lhs.value > rhs.value
                }
                .prefix(3)
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")

            Log.info(
                "[AppleScriptBench] window=\(String(format: "%.1f", elapsed))s attempts=\(benchmark.attempts) launches=\(benchmark.subprocessLaunches) cacheHits=\(benchmark.cacheHits) inFlightJoins=\(benchmark.inFlightJoins) cooldownSkips=\(benchmark.cooldownSkips) success=\(benchmark.successes) failures=\(benchmark.failures) timeouts=\(benchmark.timeouts) denied=\(benchmark.permissionDenied) syntax=\(benchmark.syntaxErrors) empty=\(benchmark.emptyOutputs) launchRate=\(String(format: "%.2f", launchRate))/s cacheHitRate=\(String(format: "%.1f", cacheHitRate))% topBundles=[\(topBundles)]",
                category: .capture
            )
        }

        benchmark = BenchmarkCounters(periodStart: now)
    }

    private func pruneExpiredEntries(now: Date) {
        cache = cache.filter { _, entry in
            entry.expiresAt > now
        }
        backoffByKey = backoffByKey.filter { _, state in
            guard let nextAllowedAt = state.nextAllowedAt else { return false }
            return nextAllowedAt > now
        }
    }
}

/// Extracts the current URL from recognized web browsers.
/// Requires Accessibility permission
///
/// Support tiers:
/// - Explicit extraction paths: Safari, Arc, and Chromium-family URL extraction logic (coverage varies by browser)
/// - Recognized but untested (best effort): Orion, iCab, OmniWeb, Opera, WebKit MiniBrowser, Waterfox, LibreWolf, Thorium, Zen, Floorp, GNOME Web
///
/// Strategy by browser:
/// - Safari: AXToolbar → AXTextField (address bar value)
/// - Chromium browsers (Chrome/Edge/Brave/Dia/etc.): AXDocument attribute on window, with AXManualAccessibility fallback
/// - Arc: AppleScript (Chromium-based but AX tree often incomplete)
/// - Firefox: Disabled (URL extraction intentionally skipped)
/// - Generic fallback: Find AXWebArea element and read AXURL attribute
struct BrowserURLExtractor: Sendable {

    // MARK: - Known Browser Bundle IDs

    /// Browser bundle IDs with explicit extraction coverage.
    private static let explicitlyRecognizedBrowsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",  // Arc
        "company.thebrowser.dia",      // Dia
        "org.mozilla.firefox",
        "org.mozilla.firefoxbeta",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.vivaldi.Vivaldi",
        "com.openai.chat",             // ChatGPT desktop app
        "ai.perplexity.comet",         // Comet Browser
        "org.chromium.Chromium",       // Chromium
        "com.sigmaos.sigmaos.macos",   // SigmaOS
        "com.nicklockwood.Duckduckgo", // DuckDuckGo
        "com.duckduckgo.macos.browser", // DuckDuckGo (alternate)
    ]

    /// Recognized but untested browser bundle IDs.
    /// Extraction for these is best-effort via generic paths and not part of the explicit test matrix.
    private static let untestedBestEffortBrowsers: Set<String> = [
        "com.operasoftware.Opera",
        "com.nickvision.browser",      // GNOME Web
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

    /// Browser bundle IDs matched exactly.
    private static let knownBrowsers: Set<String> =
        explicitlyRecognizedBrowsers.union(untestedBestEffortBrowsers)

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
        "ai.perplexity.comet.app.",
        "company.thebrowser.dia.app.",
        "com.sigmaos.sigmaos.macos.app.",
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
        "com.sigmaos.sigmaos.macos",
        "ai.perplexity.comet",
        "company.thebrowser.dia",
        "com.openai.chat",
        "com.nicklockwood.Thorium",
    ]
    private static let appleScriptCoordinator = BrowserURLAppleScriptCoordinator(
        runner: { source, browserBundleID, pid, timeoutSeconds, isBootstrapTimeout, scriptLabel in
            await runAppleScriptViaProcess(
                source,
                browserBundleID: browserBundleID,
                pid: pid,
                timeoutSeconds: timeoutSeconds,
                isBootstrapTimeout: isBootstrapTimeout,
                scriptLabel: scriptLabel
            )
        }
    )
    private static let privateModeAppleScriptCoordinator = BrowserURLAppleScriptCoordinator(
        bootstrapTimeoutSeconds: 1.25,
        normalTimeoutSeconds: 0.8,
        timeoutBaseBackoffSeconds: 1.0,
        maxTimeoutBackoffSeconds: 8.0,
        runner: { source, browserBundleID, pid, timeoutSeconds, isBootstrapTimeout, scriptLabel in
            await runAppleScriptViaProcess(
                source,
                browserBundleID: browserBundleID,
                pid: pid,
                timeoutSeconds: timeoutSeconds,
                isBootstrapTimeout: isBootstrapTimeout,
                scriptLabel: scriptLabel
            )
        }
    )
    private static let webAppAppleScriptCacheTTLSeconds: TimeInterval = 8.0
    private static let webAppTitleMatchRetryDelayMilliseconds: Int = 120
    private static let hostMatchNoWindowTitleToken = "__NO_WINDOW_TITLE__"
    private static let hostMatchNoHostWindowsToken = "__NO_HOST_WINDOWS__"
    private static let hostMatchStrictMismatchToken = "__STRICT_TITLE_MISMATCH__"
    private static let lowSignalWebAppTitles: Set<String> = [
        "chatgpt web - chatgpt",
        "chatgpt"
    ]
    private static let appleScriptModeFallbackBundleIDs: Set<String> = [
        "com.vivaldi.Vivaldi",
        "com.sigmaos.sigmaos.macos",
    ]
    private static let firefoxBundleIDs: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxbeta",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]

    private enum HostBrowserTitleMatchMissReason: String, Sendable {
        case noWindowTitle = "no_window_title"
        case noHostWindows = "no_host_windows"
        case strictTitleMismatch = "strict_title_mismatch"
        case emptyOutput = "empty_output"
        case unknown = "unknown"
    }

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

    private static func isChromiumAppShim(_ bundleID: String) -> Bool {
        chromiumAppShimPrefixes.contains(where: { bundleID.hasPrefix($0) })
    }

    /// Map a Chromium app-shim bundle id (com.vendor.Browser.app.<id>)
    /// to its host browser bundle id (com.vendor.Browser).
    private static func hostBrowserBundleID(forChromiumAppShim bundleID: String) -> String? {
        for prefix in chromiumAppShimPrefixes where bundleID.hasPrefix(prefix) {
            guard prefix.hasSuffix(".app.") else { continue }
            return String(prefix.dropLast(5))
        }
        return nil
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
    static func getURL(bundleID: String, pid: pid_t, windowCacheKey: String? = nil) async -> String? {
        if bundleID == "com.apple.finder" {
            return await getFinderTargetURL(pid: pid, windowCacheKey: windowCacheKey)
        }

        // Firefox family URL extraction is intentionally disabled.
        if firefoxBundleIDs.contains(bundleID) {
            return nil
        }

        guard isBrowser(bundleID) else {
            return nil
        }

        // Try browser-specific method first
        let url: String?
        if bundleID == "com.apple.Safari" {
            url = getSafariURL(pid: pid)
        } else if isChromiumBrowser(bundleID) {
            url = await getChromiumURL(
                bundleID: bundleID,
                pid: pid,
                windowCacheKey: windowCacheKey
            )
        } else if bundleID == "company.thebrowser.Browser" { // Arc
            url = await getArcURL(pid: pid, windowCacheKey: windowCacheKey)
        } else {
            url = nil
        }

        if let url = sanitizedBrowserURLCandidate(url, for: bundleID) {
            return url
        }

        // Fallback: Try generic AX-based URL extraction for any browser.
        return sanitizedBrowserURLCandidate(
            getURLViaWebArea(bundleID: bundleID, pid: pid),
            for: bundleID
        )
    }

    /// Best-effort private/incognito signal from AppleScript `mode`.
    /// This is intentionally limited to browsers with weak AX private markers
    /// to reduce Automation permission prompts and subprocess overhead.
    static func isPrivateModeViaAppleScript(
        bundleID: String,
        pid: pid_t,
        windowCacheKey: String? = nil
    ) async -> Bool? {
        guard appleScriptModeFallbackBundleIDs.contains(bundleID) else {
            return nil
        }

        let outputValidator: @Sendable (String) -> Bool = { output in
            !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let method1Result = await privateModeAppleScriptCoordinator.execute(
            source:
            """
            tell application id "\(bundleID)"
                get mode of front window as text
            end tell
            """,
            browserBundleID: bundleID,
            pid: pid,
            windowCacheKey: windowCacheKey,
            scriptLabel: "private-mode-front-window",
            outputValidator: outputValidator
        )

        if let decision = privateModeDecision(fromAppleScriptOutput: method1Result.output) {
            let source = method1Result.returnedFromCache ? "cache" : "AppleScript method 1"
            Log.info("[PrivateMode] [\(bundleID)] mode decision via \(source): \(decision ? "private" : "normal")", category: .capture)
            return decision
        }

        if method1Result.skippedByCooldown {
            Log.debug("[PrivateMode] [\(bundleID)] AppleScript in cooldown; skipping mode fallback", category: .capture)
            return nil
        }
        if method1Result.didTimeOut {
            Log.warning("[PrivateMode] [\(bundleID)] AppleScript timed out for mode lookup", category: .capture)
            return nil
        }

        let method2Result = await privateModeAppleScriptCoordinator.execute(
            source:
            """
            tell application id "\(bundleID)"
                get mode of window 1 as text
            end tell
            """,
            browserBundleID: bundleID,
            pid: pid,
            windowCacheKey: windowCacheKey,
            scriptLabel: "private-mode-window-1",
            outputValidator: outputValidator
        )

        if let decision = privateModeDecision(fromAppleScriptOutput: method2Result.output) {
            let source = method2Result.returnedFromCache ? "cache" : "AppleScript method 2"
            Log.info("[PrivateMode] [\(bundleID)] mode decision via \(source): \(decision ? "private" : "normal")", category: .capture)
            return decision
        }

        return nil
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
    private static func getChromiumURL(
        bundleID: String,
        pid: pid_t,
        windowCacheKey: String?
    ) async -> String? {
        let axURL = getChromiumURLViaAX(pid: pid)
        if let url = sanitizedBrowserURLCandidate(axURL, for: bundleID) {
            return url
        }

        if bundleID == "com.vivaldi.Vivaldi" {
            if let rawAXURL = axURL,
               isBrowserInternalURL(rawAXURL, for: bundleID) {
                Log.debug(
                    "[BrowserURL] [\(bundleID)] AX returned browser-internal URL; trying AppleScript active-tab fallback",
                    category: .capture
                )
            }

            if let url = await getVivaldiURLViaAppleScript(
                pid: pid,
                windowCacheKey: windowCacheKey
            ) {
                return url
            }
        }

        // Chromium app shims (PWAs) often hide URL attributes in AX.
        if isChromiumAppShim(bundleID) {
            if let url = await getWebAppURLViaAppleScript(
                bundleID: bundleID,
                pid: pid,
                windowCacheKey: windowCacheKey
            ) {
                return url
            }
        }

        return nil
    }

    private static func privateModeDecision(fromAppleScriptOutput output: String?) -> Bool? {
        guard let normalized = output?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return nil
        }

        if normalized.contains("incognito") ||
            normalized.contains("inprivate") ||
            normalized == "private" ||
            normalized.contains("private browsing") {
            return true
        }

        if normalized == "normal" ||
            normalized == "regular" ||
            normalized == "standard" {
            return false
        }

        return nil
    }

    private static func getVivaldiURLViaAppleScript(
        pid: pid_t,
        windowCacheKey: String?
    ) async -> String? {
        let vivaldiBundleID = "com.vivaldi.Vivaldi"
        let outputValidator: @Sendable (String) -> Bool = { output in
            sanitizedBrowserURLCandidate(output, for: vivaldiBundleID) != nil
        }

        let method1Result = await appleScriptCoordinator.execute(
            source:
            """
            tell application id "\(vivaldiBundleID)"
                if (count of windows) > 0 then
                    get URL of active tab of front window
                end if
            end tell
            """,
            browserBundleID: vivaldiBundleID,
            pid: pid,
            windowCacheKey: windowCacheKey,
            scriptLabel: "vivaldi-active-tab-front-window",
            outputValidator: outputValidator
        )
        if let url = extractValidatedURL(from: method1Result) {
            let source = method1Result.returnedFromCache ? "cache" : "AppleScript method 1"
            Log.info("[BrowserURL] [\(vivaldiBundleID)] ✅ URL extracted via \(source)", category: .capture)
            return url
        }

        if method1Result.skippedByCooldown {
            Log.debug("[BrowserURL] [\(vivaldiBundleID)] AppleScript in cooldown; skipping additional fallback", category: .capture)
            return nil
        }
        if method1Result.didTimeOut {
            Log.warning("[BrowserURL] [\(vivaldiBundleID)] AppleScript timed out; skipping additional fallback", category: .capture)
            return nil
        }

        let method2Result = await appleScriptCoordinator.execute(
            source:
            """
            tell application id "\(vivaldiBundleID)"
                if (count of windows) > 0 then
                    get URL of active tab of window 1
                end if
            end tell
            """,
            browserBundleID: vivaldiBundleID,
            pid: pid,
            windowCacheKey: windowCacheKey,
            scriptLabel: "vivaldi-active-tab-window-1",
            outputValidator: outputValidator
        )
        if let url = extractValidatedURL(from: method2Result) {
            let source = method2Result.returnedFromCache ? "cache" : "AppleScript method 2"
            Log.info("[BrowserURL] [\(vivaldiBundleID)] ✅ URL extracted via \(source)", category: .capture)
            return url
        }

        return nil
    }

    private static func getChromiumURLViaAX(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)

        // Try to enable accessibility on Chromium/Electron apps
        // This sets AXManualAccessibility = true which forces the AX tree to be exposed
        enableAccessibilityIfNeeded(appRef)

        // Get focused window
        guard let window: AXUIElement = getAXAttribute(appRef, kAXFocusedWindowAttribute) else {
            return nil
        }

        // Method 1: AXDocument attribute on window (most reliable for Chrome)
        if let url = getAXURLString(window, kAXDocumentAttribute) {
            return url
        }

        // Method 2: Try AXWebArea → AXURL
        if let url = findURLInWebArea(window) {
            return url
        }

        // Method 3: Try focused element's URL attribute
        if let focused: AXUIElement = getAXAttribute(appRef, kAXFocusedUIElementAttribute) {
            if let url = getAXURLString(focused, kAXURLAttribute) {
                return url
            }
            if let url = getAXURLString(focused, kAXDocumentAttribute) {
                return url
            }
        }

        // Method 4: Deep search for address bar
        return findURLInElement(window, depth: 0, maxDepth: 8)
    }

    private static func getWebAppURLViaAppleScript(
        bundleID: String,
        pid: pid_t,
        windowCacheKey: String?
    ) async -> String? {
        guard let hostBrowserBundleID = hostBrowserBundleID(forChromiumAppShim: bundleID) else {
            return nil
        }

        // Chrome-style app shims do not reliably expose tab URL terms directly.
        // Use host-browser tab matching as the only AppleScript path.
        return await getChromiumAppShimURLViaHostBrowserAppleScript(
            appShimBundleID: bundleID,
            hostBrowserBundleID: hostBrowserBundleID,
            pid: pid,
            windowCacheKey: windowCacheKey
        )
    }

    /// Chromium app-shim windows often do not expose `active tab` in their own
    /// AppleScript dictionary. Query the host browser instead, then match by title.
    private static func getChromiumAppShimURLViaHostBrowserAppleScript(
        appShimBundleID: String,
        hostBrowserBundleID: String,
        pid: pid_t,
        windowCacheKey: String?
    ) async -> String? {
        let firstAttempt = await runChromiumAppShimHostBrowserTitleMatch(
            appShimBundleID: appShimBundleID,
            hostBrowserBundleID: hostBrowserBundleID,
            pid: pid,
            windowCacheKey: windowCacheKey,
            scriptLabel: "app-shim-host-browser-title-match"
        )

        if let url = extractValidatedURL(from: firstAttempt) {
            let source = firstAttempt.returnedFromCache ? "host browser cache" : "host browser"
            if firstAttempt.returnedFromCache {
                Log.debug("[BrowserURL] [\(appShimBundleID)] URL extracted via \(source) (\(hostBrowserBundleID) strict title match)", category: .capture)
            } else {
                Log.info("[BrowserURL] [\(appShimBundleID)] ✅ URL extracted via \(source) \(hostBrowserBundleID) strict title match", category: .capture)
            }
            return url
        }

        if firstAttempt.skippedByCooldown {
            Log.debug("[BrowserURL] [\(appShimBundleID)] host-browser AppleScript in cooldown; skipping for this capture cycle", category: .capture)
            return nil
        }
        if firstAttempt.didTimeOut {
            Log.warning("[BrowserURL] [\(appShimBundleID)] host-browser AppleScript timed out for \(hostBrowserBundleID)", category: .capture)
            return nil
        }

        let firstReason = hostBrowserMissReason(from: firstAttempt.output)
        Log.debug(
            "[BrowserURL] [\(appShimBundleID)] host-browser strict title miss reason=\(firstReason.rawValue)",
            category: .capture
        )

        guard shouldRetryHostBrowserMatch(windowCacheKey: windowCacheKey, missReason: firstReason) else {
            return nil
        }

        try? await Task.sleep(for: .milliseconds(webAppTitleMatchRetryDelayMilliseconds), clock: .continuous)

        let retryAttempt = await runChromiumAppShimHostBrowserTitleMatch(
            appShimBundleID: appShimBundleID,
            hostBrowserBundleID: hostBrowserBundleID,
            pid: pid,
            windowCacheKey: windowCacheKey,
            scriptLabel: "app-shim-host-browser-title-match-retry"
        )

        if let url = extractValidatedURL(from: retryAttempt) {
            let source = retryAttempt.returnedFromCache ? "host browser cache" : "host browser retry"
            Log.info(
                "[BrowserURL] [\(appShimBundleID)] ✅ URL extracted via \(source) \(hostBrowserBundleID) strict title match (reason=retry_success, delayMs=\(webAppTitleMatchRetryDelayMilliseconds))",
                category: .capture
            )
            return url
        }

        let retryReason = hostBrowserMissReason(from: retryAttempt.output)
        Log.debug(
            "[BrowserURL] [\(appShimBundleID)] host-browser strict title miss reason=retry_empty initial=\(firstReason.rawValue) final=\(retryReason.rawValue)",
            category: .capture
        )
        return nil
    }

    private static func runChromiumAppShimHostBrowserTitleMatch(
        appShimBundleID: String,
        hostBrowserBundleID: String,
        pid: pid_t,
        windowCacheKey: String?,
        scriptLabel: String
    ) async -> BrowserURLAppleScriptResult {
        guard let matchWindowTitle = normalizedWindowTitleForHostMatch(windowCacheKey) else {
            return BrowserURLAppleScriptResult(
                output: hostMatchNoWindowTitleToken,
                completedWithoutTimeout: true
            )
        }

        return await appleScriptCoordinator.execute(
            source: chromiumAppShimHostBrowserTitleMatchScript(
                hostBrowserBundleID: hostBrowserBundleID,
                matchWindowTitle: matchWindowTitle
            ),
            browserBundleID: appShimBundleID,
            pid: pid,
            windowCacheKey: windowCacheKey,
            scriptLabel: scriptLabel,
            cacheTTLOverrideSeconds: webAppAppleScriptCacheTTLSeconds,
            outputValidator: { output in
                looksLikeURL(output) && !isHostBrowserDiagnosticToken(output)
            }
        )
    }

    private static func chromiumAppShimHostBrowserTitleMatchScript(
        hostBrowserBundleID: String,
        matchWindowTitle: String
    ) -> String {
        let escapedMatchTitle = appleScriptEscaped(matchWindowTitle)
        return """
        set matchTitle to "\(escapedMatchTitle)"
        if matchTitle is missing value then set matchTitle to ""
        if matchTitle is "" then return "\(hostMatchNoWindowTitleToken)"

        tell application id "\(hostBrowserBundleID)"
            if (count of windows) = 0 then return "\(hostMatchNoHostWindowsToken)"

            repeat with w in windows
                set tabTitle to ""
                set tabURL to ""
                try
                    set tabTitle to title of active tab of w
                    set tabURL to URL of active tab of w
                end try

                if tabURL is not "" and tabTitle is not "" then
                    if matchTitle is equal to tabTitle then
                        return tabURL
                    end if
                    if matchTitle ends with (" - " & tabTitle) then
                        return tabURL
                    end if
                end if
            end repeat
        end tell

        return "\(hostMatchStrictMismatchToken)"
        """
    }

    private static func extractValidatedURL(from result: BrowserURLAppleScriptResult) -> String? {
        guard let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              looksLikeURL(output),
              !isHostBrowserDiagnosticToken(output) else {
            return nil
        }
        return output
    }

    private static func hostBrowserMissReason(from output: String?) -> HostBrowserTitleMatchMissReason {
        let token = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch token {
        case hostMatchNoWindowTitleToken:
            return .noWindowTitle
        case hostMatchNoHostWindowsToken:
            return .noHostWindows
        case hostMatchStrictMismatchToken:
            return .strictTitleMismatch
        case "":
            return .emptyOutput
        default:
            return .unknown
        }
    }

    private static func shouldRetryHostBrowserMatch(
        windowCacheKey: String?,
        missReason: HostBrowserTitleMatchMissReason
    ) -> Bool {
        let normalizedTitle = normalizedTitleForStrictMatch(windowCacheKey)
        guard !normalizedTitle.isEmpty, lowSignalWebAppTitles.contains(normalizedTitle) else {
            return false
        }

        switch missReason {
        case .noWindowTitle, .strictTitleMismatch, .emptyOutput, .unknown:
            return true
        case .noHostWindows:
            return false
        }
    }

    private static func normalizedWindowTitleForHostMatch(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let collapsed = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func normalizedTitleForStrictMatch(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .lowercased()
    }

    private static func isHostBrowserDiagnosticToken(_ output: String) -> Bool {
        switch output {
        case hostMatchNoWindowTitleToken, hostMatchNoHostWindowsToken, hostMatchStrictMismatchToken:
            return true
        default:
            return false
        }
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Arc Browser

    /// Extract URL from Arc browser
    /// Arc is Chromium-based but often has an incomplete AX tree.
    /// AppleScript is the most reliable method.
    private static func getArcURL(pid: pid_t, windowCacheKey: String?) async -> String? {
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
            pid: pid,
            windowCacheKey: windowCacheKey,
            scriptLabel: "arc-method-1"
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
                        get URL of active tab of window 1
                    end if
                end tell
                """,
                browserBundleID: arcBundleID,
                pid: pid,
                windowCacheKey: windowCacheKey,
                scriptLabel: "arc-method-2"
            )
            if let url = method2Result.output {
                let source = method2Result.returnedFromCache ? "cache" : "AppleScript method 2"
                Log.info("[BrowserURL] ✅ Arc URL extracted via \(source)", category: .capture)
                return url
            }
        }

        Log.debug("[BrowserURL] Arc AppleScript methods failed, falling back to Chromium AX approach", category: .capture)

        // Method 3: Fall back to Chromium AX approach
        let chromiumResult = getChromiumURLViaAX(pid: pid)
        if chromiumResult != nil {
            Log.info("[BrowserURL] ✅ Arc URL extracted via Chromium AX fallback", category: .capture)
        } else {
            Log.warning("[BrowserURL] ❌ All Arc URL extraction methods failed", category: .capture)
        }
        return chromiumResult
    }

    private static func getFinderTargetURL(pid: pid_t, windowCacheKey: String?) async -> String? {
        let finderBundleID = "com.apple.finder"
        let finderResult = await appleScriptCoordinator.execute(
            source:
            """
            tell application id "com.apple.finder"
                if (count of Finder windows) > 0 then
                    set u to URL of target of front Finder window
                    if u is not missing value and u is not "" then
                        return u
                    end if
                end if
                return URL of desktop
            end tell
            """,
            browserBundleID: finderBundleID,
            pid: pid,
            windowCacheKey: windowCacheKey,
            scriptLabel: "finder-target-url"
        )

        guard let rawURL = finderResult.output?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            return nil
        }

        return rawURL
    }

    // MARK: - Generic AXWebArea Approach

    /// Find URL using generic AX traversal for browsers.
    /// This fallback is intentionally browser-scoped.
    private static func getURLViaWebArea(bundleID: String, pid: pid_t) -> String? {
        guard isBrowser(bundleID) else {
            return nil
        }
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
            if let url = getAXURLString(focused, kAXURLAttribute) {
                return url
            }
            if let url = getAXURLString(focused, kAXDocumentAttribute) {
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
            if let url = getAXURLString(element, kAXURLAttribute) {
                return url
            }
            // Also try AXDocument as fallback
            if let url = getAXURLString(element, kAXDocumentAttribute) {
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
        if let url = getAXURLString(element, kAXURLAttribute) {
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

    static func normalizedAXURLValue(from value: Any?) -> String? {
        let rawValue: String?

        switch value {
        case let string as String:
            rawValue = string
        case let url as URL:
            rawValue = url.absoluteString
        case let nsURL as NSURL:
            rawValue = nsURL.absoluteString
        default:
            rawValue = nil
        }

        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sanitizedBrowserURLCandidate(_ url: String?, for bundleID: String) -> String? {
        guard let url = normalizedAXURLValue(from: url),
              looksLikeURL(url),
              !isBrowserInternalURL(url, for: bundleID) else {
            return nil
        }
        return url
    }

    private static func isBrowserInternalURL(_ url: String, for bundleID: String) -> Bool {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedURL.isEmpty else {
            return false
        }

        if normalizedURL.hasPrefix("chrome-extension://") ||
            normalizedURL.hasPrefix("chrome://") ||
            normalizedURL.hasPrefix("devtools://") {
            return true
        }

        if bundleID == "com.vivaldi.Vivaldi", normalizedURL.hasPrefix("vivaldi://") {
            return true
        }

        return false
    }

    private static func getAXURLString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return normalizedAXURLValue(from: value)
    }

    private static func getAXURLString(_ element: AXUIElement, _ attribute: String) -> String? {
        return getAXURLString(element, attribute as CFString)
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
        isBootstrapTimeout: Bool,
        scriptLabel: String
    ) async -> BrowserURLAppleScriptResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let elapsedMs: () -> Double = {
            (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        }

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
            Log.error("[AppleScript] [\(browserBundleID)] [\(scriptLabel)] Failed to launch osascript subprocess", category: .capture, error: error)
            return BrowserURLAppleScriptResult(elapsedMs: elapsedMs())
        }

        let didTimeout = await waitForProcessExitOrTimeout(
            process: process,
            timeoutSeconds: timeoutSeconds
        )
        if didTimeout {
            let mode = isBootstrapTimeout ? "bootstrap timeout" : "normal timeout"
            let elapsed = elapsedMs()
            Log.warning("[AppleScript] [\(browserBundleID):\(pid)] [\(scriptLabel)] osascript timed out after \(timeoutSeconds)s (\(mode), elapsed=\(String(format: "%.1f", elapsed))ms) - terminating subprocess", category: .capture)
            process.terminate()
            await waitForProcessExit(process)
            return BrowserURLAppleScriptResult(didTimeOut: true, elapsedMs: elapsed)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationReason == .uncaughtSignal {
            Log.error("[AppleScript] [\(browserBundleID)] [\(scriptLabel)] osascript crashed with signal \(process.terminationStatus)", category: .capture)
            if !stderr.isEmpty {
                Log.error("[AppleScript] [\(browserBundleID)] [\(scriptLabel)] osascript stderr: \(stderr)", category: .capture)
            }
            return BrowserURLAppleScriptResult(completedWithoutTimeout: true, elapsedMs: elapsedMs())
        }

        guard process.terminationStatus == 0 else {
            let normalizedStderr = stderr.isEmpty ? "Unknown error" : stderr.replacingOccurrences(of: "\n", with: " ")
            let failureCode = parseAppleScriptFailureCode(from: normalizedStderr)
            let scriptSyntaxError = failureCode == -2741
            let codeSuffix = failureCode.map { ", applescriptCode=\($0)" } ?? ""

            Log.error(
                "[AppleScript] [\(browserBundleID)] [\(scriptLabel)] osascript failed (exitCode=\(process.terminationStatus)\(codeSuffix), elapsed=\(String(format: "%.1f", elapsedMs()))ms): \(normalizedStderr)",
                category: .capture
            )

            let permissionDenied = stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized")
            if permissionDenied {
                Log.error("[AppleScript] ⚠️ Automation permission denied - user needs to grant permission in System Settings → Privacy & Security → Automation", category: .capture)
            }

            if scriptSyntaxError {
                Log.warning(
                    "[AppleScript] [\(browserBundleID)] [\(scriptLabel)] syntax error detected (code -2741); applying syntax-error cooldown to reduce subprocess churn",
                    category: .capture
                )
            }

            return BrowserURLAppleScriptResult(
                permissionDenied: permissionDenied,
                completedWithoutTimeout: true,
                scriptSyntaxError: scriptSyntaxError,
                failureCode: failureCode,
                elapsedMs: elapsedMs()
            )
        }

        guard !output.isEmpty else {
            Log.warning(
                "[AppleScript] [\(browserBundleID)] [\(scriptLabel)] Script executed but returned empty output (elapsed=\(String(format: "%.1f", elapsedMs()))ms)",
                category: .capture
            )
            return BrowserURLAppleScriptResult(completedWithoutTimeout: true, elapsedMs: elapsedMs())
        }

        if isHostBrowserDiagnosticToken(output) {
            Log.debug(
                "[AppleScript] [\(browserBundleID)] [\(scriptLabel)] Completed with diagnostic token \(output) in \(String(format: "%.1f", elapsedMs()))ms",
                category: .capture
            )
            return BrowserURLAppleScriptResult(
                output: output,
                completedWithoutTimeout: true,
                elapsedMs: elapsedMs()
            )
        }

        Log.debug(
            "[AppleScript] [\(browserBundleID)] [\(scriptLabel)] Successfully got URL in \(String(format: "%.1f", elapsedMs()))ms: \(output.prefix(50))...",
            category: .capture
        )
        return BrowserURLAppleScriptResult(
            output: output,
            completedWithoutTimeout: true,
            elapsedMs: elapsedMs()
        )
    }

    private static func parseAppleScriptFailureCode(from stderr: String) -> Int? {
        guard let openParen = stderr.lastIndex(of: "("),
              let closeParen = stderr[openParen...].firstIndex(of: ")"),
              openParen < closeParen else {
            return nil
        }

        let codeText = stderr[stderr.index(after: openParen)..<closeParen]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(codeText)
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
