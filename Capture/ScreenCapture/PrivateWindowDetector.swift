import Foundation
import ApplicationServices
import ScreenCaptureKit
import Shared

/// Detects private/incognito browser windows using Accessibility API and fallback methods
struct PrivateWindowDetector {

    private static let privateBrowsingAXTitleMarkers = [
        "incognito",
        "private browsing",
        "inprivate",
        "(private)",
        "private window",
    ]

    private static let duckDuckGoBundleIDs: Set<String> = [
        "com.duckduckgo.macos.browser",
        "com.nicklockwood.Duckduckgo",
    ]

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
            "Firefox", "Arc", "Vivaldi", "Chromium", "Opera", "Dia", "Dia Browser", "Comet", "DuckDuckGo"
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

    /// Detect private/incognito mode strictly from AXTitle for a specific window.
    /// - Parameters:
    ///   - pid: Process ID of the window owner
    ///   - windowTitle: The window title from CGWindowList
    /// - Returns: true if matching AXTitle contains private/incognito markers, false if checked and not private, nil if AX is unavailable
    static func isPrivateWindowViaAXTitle(pid: pid_t, windowTitle: String, bundleID: String? = nil) -> Bool? {
        tracePrivateRedaction("begin pid=\(pid) windowTitle='\(tracePreview(windowTitle))'")

        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )

        if result == .apiDisabled || result == .cannotComplete {
            tracePrivateRedaction("AX unavailable pid=\(pid) result=\(result.rawValue)")
            return nil
        }

        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else {
            tracePrivateRedaction("AX fetch failed pid=\(pid) result=\(result.rawValue)")
            return nil
        }

        tracePrivateRedaction("AX window count pid=\(pid): \(windows.count)")

        let resolvedBundleID = bundleID ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let normalizedWindowTitle = normalizedWindowTitleForMatching(windowTitle)
        var sawMatchingTitle = false
        var sawMatchingMarker = false
        var sawAnyPrivateMarker = false

        for (index, axWindow) in windows.enumerated() {
            guard let axTitle = getAXAttribute(axWindow, kAXTitleAttribute as CFString) as? String else {
                tracePrivateRedaction("candidate[\(index)] missing AXTitle")
                continue
            }

            let titleLikelyMatches = axTitleLikelyMatchesWindow(axTitle, normalizedWindowTitle: normalizedWindowTitle)
            let axIdentifier = getAXAttribute(axWindow, "AXIdentifier" as CFString) as? String
            let hasPrivateMarker = axTitleContainsPrivateMarker(axTitle, bundleID: resolvedBundleID) ||
                axIdentifierContainsPrivateMarker(axIdentifier)
            if hasPrivateMarker {
                sawAnyPrivateMarker = true
            }
            let identifierTrace = axIdentifier.map { tracePreview($0) } ?? "(none)"
            tracePrivateRedaction(
                "candidate[\(index)] title='\(tracePreview(axTitle))' titleMatch=\(titleLikelyMatches) markerMatch=\(hasPrivateMarker) identifier='\(identifierTrace)'"
            )

            if titleLikelyMatches {
                sawMatchingTitle = true
                if hasPrivateMarker {
                    sawMatchingMarker = true
                }
            }
        }

        if sawMatchingMarker {
            tracePrivateRedaction("decision pid=\(pid): private=true (matching AXTitle contains marker)")
            return true
        }

        if sawMatchingTitle {
            tracePrivateRedaction("decision pid=\(pid): private=false (matching AXTitle has no marker)")
            return false
        }

        if windowTitleLooksLikePrivatePlaceholder(normalizedWindowTitle), sawAnyPrivateMarker {
            tracePrivateRedaction(
                "decision pid=\(pid): private=true (fallback: private placeholder title + marker window present)"
            )
            return true
        }

        tracePrivateRedaction("decision pid=\(pid): private=false (no matching AXTitle)")
        return false
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
        case "Dia", "Dia Browser":
            return "company.thebrowser.dia"
        case "Comet":
            return "ai.perplexity.comet"
        case "DuckDuckGo":
            return "com.duckduckgo.macos.browser"
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
            "(private)",            // Brave: "Title - Brave (Private)"
            "fire window",          // DuckDuckGo private window title
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
             "com.brave.Browser", "org.chromium.Chromium", "com.vivaldi.Vivaldi",
             "ai.perplexity.comet",
             "company.thebrowser.dia":
            return checkChromiumPrivate(element)

        case "com.duckduckgo.macos.browser", "com.nicklockwood.Duckduckgo":
            return checkDuckDuckGoPrivate(element)

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

        Log.debug("[ChromiumPrivate] Checking window '\(title)' - subrole: \(subrole ?? "nil"), roleDesc: \(roleDesc ?? "nil"), desc: \(description ?? "nil")", category: .capture)

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

        // Check window title - Chrome/Edge append " - Incognito" or " — Incognito" (em-dash)
        // Using lowercased comparison to be safe
        let lowercaseTitle = title.lowercased()
        if lowercaseTitle.contains(" - incognito") ||
           lowercaseTitle.contains(" — incognito") ||
           lowercaseTitle.contains("(incognito)") ||
           lowercaseTitle.contains(" - inprivate") ||
           lowercaseTitle.contains(" — inprivate") ||
           lowercaseTitle.contains("(inprivate)") ||
           lowercaseTitle.contains("(private)") ||
           lowercaseTitle.contains("private window") {
            Log.info("[ChromiumPrivate] MATCH via title: \(title)", category: .capture)
            return true
        }

        Log.debug("[ChromiumPrivate] NO MATCH for '\(title)'", category: .capture)
        return false
    }

    /// Check if a Safari window is in private browsing mode
    private static func checkSafariPrivate(_ element: AXUIElement) -> Bool {
        let title = getAXAttribute(element, kAXTitleAttribute as CFString) as? String
        let description = getAXAttribute(element, kAXDescriptionAttribute as CFString) as? String

        Log.debug("[SafariPrivate] Checking window '\(title ?? "(no title)")' - desc: \(description ?? "nil")", category: .capture)

        // Check for private browsing attribute (Safari-specific)
        if let isPrivate = getAXAttribute(element, "AXIsPrivateBrowsing" as CFString) as? Bool {
            Log.info("[SafariPrivate] MATCH via AXIsPrivateBrowsing: \(isPrivate)", category: .capture)
            return isPrivate
        }

        // Check window title - Safari appends " — Private" or " - Private"
        if let title = title {
            let lowercaseTitle = title.lowercased()
            // Safari uses " — Private" suffix (em-dash)
            if lowercaseTitle.hasSuffix(" — private") ||
               lowercaseTitle.hasSuffix(" - private") ||
               lowercaseTitle.contains(" — private") ||
               lowercaseTitle.contains(" - private") {
                Log.info("[SafariPrivate] MATCH via title: \(title)", category: .capture)
                return true
            }
        }

        // Check AXDescription
        if let description = description {
            // Be more specific - look for "private browsing" or title-like patterns
            let lowercaseDesc = description.lowercased()
            if lowercaseDesc.contains("private browsing") ||
               lowercaseDesc.hasSuffix(" private") {
                Log.info("[SafariPrivate] MATCH via description: \(description)", category: .capture)
                return true
            }
        }

        Log.debug("[SafariPrivate] NO MATCH for '\(title ?? "(no title)")'", category: .capture)
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

        if let identifier = getAXAttribute(element, "AXIdentifier" as CFString) as? String,
           axIdentifierContainsPrivateMarker(identifier) {
            return true
        }

        return false
    }

    /// Check if DuckDuckGo browser window is in private mode.
    /// DuckDuckGo uses "Fire Window" as the private window title.
    private static func checkDuckDuckGoPrivate(_ element: AXUIElement) -> Bool {
        guard let title = getAXAttribute(element, kAXTitleAttribute as CFString) as? String else {
            return false
        }

        let normalizedTitle = normalizedWindowTitleForMatching(title)
        return normalizedTitle == "fire window"
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

    private static func normalizedWindowTitleForMatching(_ title: String) -> String {
        title
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippedPrivateMarkers(from title: String) -> String {
        var normalized = normalizedWindowTitleForMatching(title)

        let removableMarkers = [
            "(incognito)",
            " - incognito",
            " — incognito",
            "(inprivate)",
            " - inprivate",
            " — inprivate",
            "(private browsing)",
            " - private browsing",
            " — private browsing",
            ", private browsing",
            "(private)",
            " - private",
            " — private",
            " - private window",
            " — private window",
        ]

        for marker in removableMarkers {
            normalized = normalized.replacingOccurrences(of: marker, with: "")
        }

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func axTitleLikelyMatchesWindow(_ axTitle: String, normalizedWindowTitle: String) -> Bool {
        guard !normalizedWindowTitle.isEmpty else { return false }

        let normalizedAXTitle = normalizedWindowTitleForMatching(axTitle)
        if normalizedAXTitle == normalizedWindowTitle {
            return true
        }

        if strongContainmentMatch(normalizedAXTitle, normalizedWindowTitle) {
            return true
        }

        let strippedAXTitle = strippedPrivateMarkers(from: normalizedAXTitle)
        if strippedAXTitle == normalizedWindowTitle {
            return true
        }

        if strongContainmentMatch(strippedAXTitle, normalizedWindowTitle) {
            return true
        }

        let canonicalAXTitle = canonicalTitleForMatching(normalizedAXTitle)
        let canonicalWindowTitle = canonicalTitleForMatching(normalizedWindowTitle)
        guard !canonicalAXTitle.isEmpty, !canonicalWindowTitle.isEmpty else { return false }

        if canonicalAXTitle == canonicalWindowTitle {
            return true
        }

        if strongContainmentMatch(canonicalAXTitle, canonicalWindowTitle) {
            return true
        }

        return strongTokenOverlapMatch(canonicalAXTitle, canonicalWindowTitle)
    }

    private static func axTitleContainsPrivateMarker(_ axTitle: String, bundleID: String?) -> Bool {
        let normalizedTitle = normalizedWindowTitleForMatching(axTitle)
        if privateBrowsingAXTitleMarkers.contains(where: { normalizedTitle.contains($0) }) {
            return true
        }

        if let bundleID, duckDuckGoBundleIDs.contains(bundleID), normalizedTitle == "fire window" {
            return true
        }

        return false
    }

    private static func axIdentifierContainsPrivateMarker(_ axIdentifier: String?) -> Bool {
        guard let axIdentifier else { return false }
        let normalizedIdentifier = normalizedWindowTitleForMatching(axIdentifier)

        if normalizedIdentifier.contains("bigincognitobrowserwindow") {
            return true
        }

        return normalizedIdentifier.contains("incognito") ||
            normalizedIdentifier.contains("inprivate")
    }

    private static func strongContainmentMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        guard lhs.contains(rhs) || rhs.contains(lhs) else { return false }

        let shorterCount = min(lhs.count, rhs.count)
        let longerCount = max(lhs.count, rhs.count)
        guard shorterCount > 0 else { return false }

        let lengthRatio = Double(shorterCount) / Double(longerCount)
        return shorterCount >= 12 || lengthRatio >= 0.60
    }

    private static func strongTokenOverlapMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhsTokens = Set(
            lhs.split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { $0.count >= 3 }
        )
        let rhsTokens = Set(
            rhs.split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { $0.count >= 3 }
        )

        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }

        let commonCount = lhsTokens.intersection(rhsTokens).count
        if commonCount == 0 {
            return false
        }

        let shorterTokenCount = min(lhsTokens.count, rhsTokens.count)
        guard shorterTokenCount >= 3 else {
            return false
        }

        let overlapRatio = Double(commonCount) / Double(shorterTokenCount)
        return (commonCount >= 4 && overlapRatio >= 0.45) ||
            (commonCount >= 3 && overlapRatio >= 0.70)
    }

    private static func canonicalTitleForMatching(_ title: String) -> String {
        var normalized = normalizedWindowTitleForMatching(title)
        normalized = strippedPrivateMarkers(from: normalized)

        let removableSegments = [
            " - audio playing",
            " — audio playing",
            " (audio playing)",
            "🔊",
            "🔉",
            "🔈",
            "🔇",
        ]

        for segment in removableSegments {
            normalized = normalized.replacingOccurrences(of: segment, with: "")
        }

        let removableSuffixes = [
            " - google chrome canary",
            " — google chrome canary",
            " - google chrome",
            " — google chrome",
            " - microsoft edge",
            " — microsoft edge",
            " - brave browser",
            " — brave browser",
            " - chromium",
            " — chromium",
            " - safari",
            " — safari",
            " - firefox",
            " — firefox",
        ]

        var trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        var removedSuffix = true
        while removedSuffix {
            removedSuffix = false
            for suffix in removableSuffixes {
                if trimmed.hasSuffix(suffix) {
                    trimmed.removeLast(suffix.count)
                    trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
                    removedSuffix = true
                    break
                }
            }
        }

        let folded = trimmed.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let sanitized = folded.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined()

        return sanitized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .lowercased()
    }

    private static func windowTitleLooksLikePrivatePlaceholder(_ normalizedWindowTitle: String) -> Bool {
        guard !normalizedWindowTitle.isEmpty else { return false }

        return normalizedWindowTitle.contains("incognito tab") ||
            normalizedWindowTitle.contains("new incognito") ||
            normalizedWindowTitle.contains("private browsing") ||
            normalizedWindowTitle.contains("inprivate") ||
            normalizedWindowTitle.contains("private window") ||
            normalizedWindowTitle == "fire window"
    }

    private static func tracePrivateRedaction(_ message: String) {
        Log.info("[PrivateAXTrace] \(message)", category: .capture)
    }

    private static func tracePreview(_ value: String, limit: Int = 180) -> String {
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if collapsed.count <= limit {
            return collapsed
        }

        return String(collapsed.prefix(limit)) + "..."
    }
}
