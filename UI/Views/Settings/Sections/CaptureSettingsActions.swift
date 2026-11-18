import SwiftUI
import Shared
import AppKit
import App
import Database
import Carbon.HIToolbox
import ScreenCaptureKit
import SQLCipher
import ServiceManagement
import Darwin
import Carbon
import UniformTypeIdentifiers

extension SettingsView {
    func checkPermissions() async {
        hasScreenRecordingPermission = checkScreenRecordingPermission()
        hasAccessibilityPermission = checkAccessibilityPermission()
        hasListenEventAccess = checkListenEventAccess()
        browserExtractionPermissionStatus = await checkBrowserExtractionPermissionStatus()
    }

    func checkScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func checkAccessibilityPermission() -> Bool {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ]
        return AXIsProcessTrustedWithOptions(options) as Bool
    }

    func checkListenEventAccess() -> Bool {
        CGPreflightListenEventAccess()
    }

    func requestScreenRecordingPermission() {
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                await MainActor.run {
                    hasScreenRecordingPermission = checkScreenRecordingPermission()
                }
            } catch {
                Log.warning("[SettingsView] Screen recording permission request error: \(error)", category: .ui)
            }
        }
    }

    func requestAccessibilityPermission() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)

        Task {
            for _ in 0..<30 {
                try? await Task.sleep(for: .nanoseconds(Int64(1_000_000_000)), clock: .continuous)
                let granted = checkAccessibilityPermission()
                if granted {
                    await MainActor.run {
                        hasAccessibilityPermission = true
                    }
                    break
                }
            }
        }
    }

    @MainActor
    func requestListenEventAccessIfNeeded() async -> Bool {
        let alreadyGranted = checkListenEventAccess()
        hasListenEventAccess = alreadyGranted
        guard !alreadyGranted else { return true }

        let requested = CGRequestListenEventAccess()
        let grantedAfterRequest = requested || checkListenEventAccess()
        hasListenEventAccess = grantedAfterRequest
        return grantedAfterRequest
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openListenEventSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    func openAutomationSettings() {
        if let automationURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
           NSWorkspace.shared.open(automationURL) {
            return
        }

        if let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(privacyURL)
        }
    }

    func checkBrowserExtractionPermissionStatus() async -> PermissionStatus {
        let probeBundleIDs = ["com.apple.Safari", "com.google.Chrome"]
        var cachedStates = inPageURLCachedPermissionStates()

        var installedBundleIDs: [String] = []
        await MainActor.run {
            installedBundleIDs = probeBundleIDs.filter {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
        }

        guard !installedBundleIDs.isEmpty else {
            return .notDetermined
        }

        var allGranted = true
        var anyDenied = false

        for bundleID in installedBundleIDs {
            let status = await inPageURLPermissionStatusAsync(
                for: bundleID,
                askUserIfNeeded: false
            )
            let resolvedState = await resolvedInPageURLPermissionState(
                from: status,
                bundleID: bundleID,
                previousState: nil,
                cachedState: cachedStates[bundleID]
            )
            if inPageURLPermissionStateForCache(resolvedState) != nil {
                cachedStates[bundleID] = resolvedState
            }

            switch resolvedState {
            case .granted:
                continue
            case .denied:
                anyDenied = true
                allGranted = false
            case .needsConsent, .unavailable:
                allGranted = false
            }
        }

        if allGranted {
            persistInPageURLCachedPermissionStates(cachedStates)
            return .granted
        }
        if anyDenied {
            persistInPageURLCachedPermissionStates(cachedStates)
            return .denied
        }
        persistInPageURLCachedPermissionStates(cachedStates)
        return .notDetermined
    }

    @MainActor
    func refreshPrivateModeAutomationTargets(force: Bool = false) async {
        if isRefreshingPrivateModeAutomationTargets && !force {
            return
        }
        isRefreshingPrivateModeAutomationTargets = true
        defer { isRefreshingPrivateModeAutomationTargets = false }

        let compatibleTargets = Self.privateModeAXCompatibleBrowserBundleIDs.compactMap { bundleID -> PrivateModeAutomationTarget? in
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            return PrivateModeAutomationTarget(
                bundleID: bundleID,
                displayName: Self.inPageURLDisplayName(for: bundleID),
                appURL: appURL
            )
        }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        let discoveredTargets = Self.privateModeAutomationFallbackBundleIDs.compactMap { bundleID -> PrivateModeAutomationTarget? in
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            return PrivateModeAutomationTarget(
                bundleID: bundleID,
                displayName: Self.inPageURLDisplayName(for: bundleID),
                appURL: appURL
            )
        }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        privateModeAXCompatibleTargets = compatibleTargets
        privateModeAutomationTargets = discoveredTargets
        refreshPrivateModeAutomationRunningBundleIDs()

        let validBundleIDs = Set(inPageURLTargets.map(\.bundleID))
            .union(unsupportedInPageURLTargets.map(\.bundleID))
            .union(compatibleTargets.map(\.bundleID))
            .union(discoveredTargets.map(\.bundleID))
        pruneInPageURLIconCaches(validBundleIDs: validBundleIDs)

        var cachedStates = inPageURLCachedPermissionStates()
        var nextPermissionStates: [String: InPageURLPermissionState] = [:]
        for target in discoveredTargets {
            let isRunning = privateModeAutomationRunningBundleIDs.contains(target.bundleID)
            let hasStableClientIdentity = Self.inPageURLHasStableAutomationClientIdentity()
            let previousState = privateModeAutomationPermissionStateByBundleID[target.bundleID]
            let cachedState = cachedStates[target.bundleID]
            let status = await inPageURLPermissionStatusAsync(
                for: target.bundleID,
                askUserIfNeeded: false
            )
            let settingsState = !isRunning
                ? await inPageURLPermissionStateFromSystemSettingsAsync(for: target.bundleID)
                : nil
            let resolvedState: InPageURLPermissionState
            let shouldTrustNeedsConsentFromSettings = hasStableClientIdentity
            let shouldUseSettingsState: Bool = {
                guard !isRunning, let settingsState else { return false }
                if settingsState == .needsConsent && !shouldTrustNeedsConsentFromSettings {
                    return false
                }
                return true
            }()

            if shouldUseSettingsState, let settingsState {
                resolvedState = settingsState
            } else if status == OSStatus(procNotFound) {
                if let previousState, isStableInPageURLPermissionState(previousState) {
                    resolvedState = previousState
                } else if let cachedState, isStableInPageURLPermissionState(cachedState) {
                    resolvedState = cachedState
                } else {
                    resolvedState = .needsConsent
                }
            } else {
                resolvedState = inPageURLPermissionState(from: status)
            }
            nextPermissionStates[target.bundleID] = resolvedState
            if inPageURLPermissionStateForCache(resolvedState) != nil {
                cachedStates[target.bundleID] = resolvedState
            }
        }

        privateModeAutomationPermissionStateByBundleID = nextPermissionStates
        persistInPageURLCachedPermissionStates(cachedStates)
    }

    @MainActor
    func refreshPrivateModeAutomationRunningBundleIDs() {
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        privateModeAutomationRunningBundleIDs = Set(
            privateModeAutomationTargets.map(\.bundleID).filter { runningBundleIDs.contains($0) }
        )
    }

    @MainActor
    func requestPrivateModeAutomationPermission(for target: PrivateModeAutomationTarget) async {
        guard !privateModeAutomationBusyBundleIDs.contains(target.bundleID) else { return }
        privateModeAutomationBusyBundleIDs.insert(target.bundleID)
        defer { privateModeAutomationBusyBundleIDs.remove(target.bundleID) }

        let status = await inPageURLPermissionStatusAsync(
            for: target.bundleID,
            askUserIfNeeded: true
        )
        var cachedStates = inPageURLCachedPermissionStates()
        let state = await resolvedInPageURLPermissionState(
            from: status,
            bundleID: target.bundleID,
            previousState: privateModeAutomationPermissionStateByBundleID[target.bundleID],
            cachedState: cachedStates[target.bundleID]
        )
        privateModeAutomationPermissionStateByBundleID[target.bundleID] = state
        if inPageURLPermissionStateForCache(state) != nil {
            cachedStates[target.bundleID] = state
            persistInPageURLCachedPermissionStates(cachedStates)
        }
        if state == .denied {
            openAutomationSettings()
            recordPrivateWindowRedactionMetric(
                action: "automation_permission_denied_open_settings",
                browserBundleID: target.bundleID,
                permissionState: state
            )
        }
        refreshPrivateModeAutomationRunningBundleIDs()
        recordPrivateWindowRedactionMetric(
            action: "automation_permission_probe",
            browserBundleID: target.bundleID,
            permissionState: state
        )
    }

    @MainActor
    func launchPrivateModeAutomationTarget(_ target: PrivateModeAutomationTarget) async {
        guard !privateModeAutomationBusyBundleIDs.contains(target.bundleID) else { return }
        privateModeAutomationBusyBundleIDs.insert(target.bundleID)
        defer { privateModeAutomationBusyBundleIDs.remove(target.bundleID) }

        if let appURL = target.appURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }

        try? await Task.sleep(for: .milliseconds(160), clock: .continuous)
        refreshPrivateModeAutomationRunningBundleIDs()

        let status = await inPageURLPermissionStatusAsync(
            for: target.bundleID,
            askUserIfNeeded: false
        )
        var cachedStates = inPageURLCachedPermissionStates()
        let state = await resolvedInPageURLPermissionState(
            from: status,
            bundleID: target.bundleID,
            previousState: privateModeAutomationPermissionStateByBundleID[target.bundleID],
            cachedState: cachedStates[target.bundleID]
        )
        privateModeAutomationPermissionStateByBundleID[target.bundleID] = state
        if inPageURLPermissionStateForCache(state) != nil {
            cachedStates[target.bundleID] = state
            persistInPageURLCachedPermissionStates(cachedStates)
        }

        recordPrivateWindowRedactionMetric(
            action: "automation_launch",
            browserBundleID: target.bundleID,
            permissionState: state
        )
    }

    func inPageURLCachedPermissionStates() -> [String: InPageURLPermissionState] {
        guard !inPageURLPermissionCacheRaw.isEmpty,
              let data = inPageURLPermissionCacheRaw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        var states: [String: InPageURLPermissionState] = [:]
        for (bundleID, rawState) in decoded {
            if let state = inPageURLPermissionStateFromCache(rawState) {
                states[bundleID] = state
            }
        }
        return states
    }

    func persistInPageURLCachedPermissionStates(_ states: [String: InPageURLPermissionState]) {
        let encodable = states.compactMapValues(inPageURLPermissionStateForCache)
        guard !encodable.isEmpty else {
            inPageURLPermissionCacheRaw = ""
            return
        }

        guard let data = try? JSONEncoder().encode(encodable),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        inPageURLPermissionCacheRaw = raw
    }

    func inPageURLPermissionStateForCache(_ state: InPageURLPermissionState) -> String? {
        switch state {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .needsConsent:
            return "needsAllow"
        case .unavailable:
            return nil
        }
    }

    func inPageURLPermissionStateFromCache(_ raw: String) -> InPageURLPermissionState? {
        switch raw {
        case "granted":
            return .granted
        case "denied":
            return .denied
        case "needsAllow":
            return .needsConsent
        default:
            return nil
        }
    }

    func isStableInPageURLPermissionState(_ state: InPageURLPermissionState) -> Bool {
        switch state {
        case .granted, .denied, .needsConsent:
            return true
        case .unavailable:
            return false
        }
    }

    nonisolated private static func inPageURLDisplayName(for bundleID: String) -> String {
        switch bundleID {
        case "com.apple.Safari":
            return "Safari"
        case "com.google.Chrome":
            return "Chrome"
        case "com.google.Chrome.canary":
            return "Chrome Canary"
        case "org.chromium.Chromium":
            return "Chromium"
        case "org.mozilla.firefox":
            return "Firefox"
        case "org.mozilla.firefoxbeta":
            return "Firefox Beta"
        case "org.mozilla.firefoxdeveloperedition":
            return "Firefox Developer Edition"
        case "org.mozilla.nightly":
            return "Firefox Nightly"
        case "com.microsoft.edgemac":
            return "Edge"
        case "com.brave.Browser":
            return "Brave"
        case "com.vivaldi.Vivaldi":
            return "Vivaldi"
        case "com.operasoftware.Opera":
            return "Opera"
        case "company.thebrowser.Browser":
            return "Arc"
        case "ai.perplexity.comet":
            return "Comet"
        case "company.thebrowser.dia":
            return "Dia"
        case "com.duckduckgo.macos.browser":
            return "DuckDuckGo"
        case "com.openai.atlas":
            return "ChatGPT Atlas"
        case "com.sigmaos.sigmaos.macos":
            return "SigmaOS"
        case "com.nicklockwood.Thorium":
            return "Thorium"
        default:
            return bundleID
        }
    }

    nonisolated static func inPageURLUnsupportedReason(for bundleID: String) -> String {
        switch bundleID {
        case "org.mozilla.firefox",
            "org.mozilla.firefoxbeta",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly":
            return "Firefox does not support in-page URL extraction."
        case "com.duckduckgo.macos.browser":
            return "DuckDuckGo does not support in-page URL extraction."
        case "com.sigmaos.sigmaos.macos":
            return "SigmaOS does not support in-page URL extraction."
        case "com.openai.atlas":
            return "ChatGPT Atlas does not support in-page URL extraction."
        case "app.zen-browser.zen":
            return "Zen does not support in-page URL extraction."
        default:
            return "This browser does not support in-page URL extraction."
        }
    }

    static func isSupportedDirectInPageURLBrowserBundleID(_ bundleID: String) -> Bool {
        inPageURLKnownBrowserBundleIDs.contains(bundleID)
    }

    func inPageURLJavaScriptFromAppleEventsReminder(for bundleID: String) -> String {
        let automationBundleID = Self.resolvedInPageURLAutomationBundleID(for: bundleID)
        guard automationBundleID != bundleID else {
            return "Enable 'Allow JavaScript from Apple Events' (see Step 2)"
        }

        let hostDisplayName = Self.inPageURLDisplayName(for: automationBundleID)
        return "Enable 'Allow JavaScript from Apple Events' for \(hostDisplayName) (see Step 2)"
    }
}
