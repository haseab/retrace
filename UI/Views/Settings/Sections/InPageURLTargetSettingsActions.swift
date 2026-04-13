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

private struct InPageURLIconBox: @unchecked Sendable {
    let image: NSImage?
}

extension SettingsView {
    @MainActor
    func refreshInPageURLTargets(force: Bool = false) async {
        if isRefreshingInPageURLTargets && !force {
            return
        }
        isRefreshingInPageURLTargets = true
        defer { isRefreshingInPageURLTargets = false }

        let discoverySnapshot = await Task.detached(priority: .userInitiated) {
            Self.inPageURLDiscoverySnapshotSync()
        }.value

        let targets = discoverySnapshot.supportedTargets
        unsupportedInPageURLTargets = discoverySnapshot.unsupportedTargets
        inPageURLTargets = targets
        refreshInPageURLRunningBundleIDs()

        pruneInPageURLIconCaches(
            validBundleIDs: Set(targets.map(\.bundleID)).union(unsupportedInPageURLTargets.map(\.bundleID))
        )

        var cachedStates = inPageURLCachedPermissionStates()
        var nextPermissionStates: [String: InPageURLPermissionState] = [:]
        for target in targets {
            let status = await inPageURLPermissionStatusAsync(
                for: target.bundleID,
                askUserIfNeeded: false
            )
            let state = await resolvedInPageURLPermissionState(
                from: status,
                bundleID: target.bundleID,
                previousState: inPageURLPermissionStateByBundleID[target.bundleID],
                cachedState: cachedStates[target.bundleID]
            )
            nextPermissionStates[target.bundleID] = state
            if inPageURLPermissionStateForCache(state) != nil {
                cachedStates[target.bundleID] = state
            }
        }
        inPageURLPermissionStateByBundleID = nextPermissionStates
        persistInPageURLCachedPermissionStates(cachedStates)
        refreshInPageURLVerificationSummary()
    }

    @MainActor
    func pruneInPageURLIconCaches(validBundleIDs: Set<String>) {
        inPageURLIconByBundleID = inPageURLIconByBundleID.filter { validBundleIDs.contains($0.key) }
        inPageURLIconLoadTasksByBundleID = inPageURLIconLoadTasksByBundleID.filter { bundleID, task in
            guard validBundleIDs.contains(bundleID) else {
                task.cancel()
                return false
            }
            return true
        }
    }

    @MainActor
    func cancelAllInPageURLIconLoads() {
        inPageURLIconLoadTasksByBundleID.values.forEach { $0.cancel() }
        inPageURLIconLoadTasksByBundleID = [:]
    }

    @MainActor
    func scheduleInPageURLIconLoad(bundleID: String, appURL: URL?) {
        guard inPageURLIconByBundleID[bundleID] == nil else { return }
        guard inPageURLIconLoadTasksByBundleID[bundleID] == nil else { return }
        guard let iconPath = appURL?.path else { return }

        inPageURLIconLoadTasksByBundleID[bundleID] = Task.detached(priority: .utility) { [bundleID, iconPath] in
            guard !Task.isCancelled else { return }
            let icon = InPageURLIconBox(image: Self.loadInPageURLIconSync(forPath: iconPath))
            await MainActor.run {
                defer { inPageURLIconLoadTasksByBundleID[bundleID] = nil }
                guard !Task.isCancelled else { return }
                guard inPageURLIconByBundleID[bundleID] == nil else { return }
                guard let icon = icon.image else { return }
                inPageURLIconByBundleID[bundleID] = icon
            }
        }
    }

    nonisolated private static func loadInPageURLIconSync(forPath iconPath: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: iconPath) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: iconPath)
        icon.size = NSSize(width: 20, height: 20)
        return icon
    }

    struct InPageURLInstalledApplication: Sendable {
        let bundleID: String
        let displayName: String
        let appURL: URL
    }

    struct InPageURLDiscoverySnapshot: Sendable {
        let supportedTargets: [InPageURLBrowserTarget]
        let unsupportedTargets: [UnsupportedInPageURLTarget]
    }

    nonisolated private static func inPageURLDiscoverySnapshotSync() -> InPageURLDiscoverySnapshot {
        let installedApplications = installedInPageURLApplicationsByBundleIDSync()

        var supportedTargetsByBundleID: [String: InPageURLBrowserTarget] = [:]
        for bundleID in inPageURLKnownBrowserBundleIDs {
            guard let installedApp = installedApplications[bundleID] else { continue }
            supportedTargetsByBundleID[bundleID] = InPageURLBrowserTarget(
                bundleID: installedApp.bundleID,
                displayName: installedApp.displayName,
                appURL: installedApp.appURL
            )
        }

        for target in discoveredInPageURLWebAppTargetsSync() {
            supportedTargetsByBundleID[target.bundleID] = target
        }

        let supportedTargets = supportedTargetsByBundleID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        let unsupportedTargets = inPageURLUnsupportedBundleIDs.compactMap { bundleID -> UnsupportedInPageURLTarget? in
            guard let installedApp = installedApplications[bundleID] else { return nil }
            return UnsupportedInPageURLTarget(
                bundleID: installedApp.bundleID,
                displayName: installedApp.displayName,
                reason: inPageURLUnsupportedReason(for: bundleID),
                appURL: installedApp.appURL
            )
        }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        return InPageURLDiscoverySnapshot(
            supportedTargets: Array(supportedTargets),
            unsupportedTargets: unsupportedTargets
        )
    }

    nonisolated private static func installedInPageURLApplicationsByBundleIDSync(
        fileManager: FileManager = .default
    ) -> [String: InPageURLInstalledApplication] {
        let applicationFolders: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Chrome Apps.localized", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized", isDirectory: true),
        ]

        var applicationsByBundleID: [String: InPageURLInstalledApplication] = [:]
        for folder in applicationFolders {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for appURL in entries where appURL.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.isEmpty,
                      applicationsByBundleID[bundleID] == nil else {
                    continue
                }

                let displayName =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                    (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                    appURL.deletingPathExtension().lastPathComponent

                applicationsByBundleID[bundleID] = InPageURLInstalledApplication(
                    bundleID: bundleID,
                    displayName: displayName,
                    appURL: appURL
                )
            }
        }

        return applicationsByBundleID
    }

    @MainActor
    func refreshInPageURLRunningBundleIDs() {
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        inPageURLRunningBundleIDs = Set(
            inPageURLTargets.map(\.bundleID).filter { runningBundleIDs.contains($0) }
        )
    }

    nonisolated private static func discoveredInPageURLWebAppTargetsSync() -> [InPageURLBrowserTarget] {
        let fileManager = FileManager.default
        let homeApplications = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)

        var searchDirectories: Set<URL> = [homeApplications, systemApplications]
        Self.inPageURLWebAppContainerDirectories(in: homeApplications).forEach { searchDirectories.insert($0) }
        Self.inPageURLWebAppContainerDirectories(in: systemApplications).forEach { searchDirectories.insert($0) }

        var webAppTargets: [InPageURLBrowserTarget] = []
        var seenBundleIDs: Set<String> = []

        for directoryURL in searchDirectories {
            let appURLs = Self.inPageURLAppBundleURLs(in: directoryURL)
            for appURL in appURLs {
                guard let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier,
                      Self.isInPageURLChromiumWebApp(bundle: bundle, bundleID: bundleID),
                      !seenBundleIDs.contains(bundleID) else {
                    continue
                }

                let displayName =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                    (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                    appURL.deletingPathExtension().lastPathComponent

                webAppTargets.append(
                    InPageURLBrowserTarget(
                        bundleID: bundleID,
                        displayName: displayName,
                        appURL: appURL
                    )
                )
                seenBundleIDs.insert(bundleID)
            }
        }

        return webAppTargets
    }

    nonisolated private static func inPageURLWebAppContainerDirectories(in rootDirectory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.filter { entry in
            let lowercased = entry.lastPathComponent.lowercased()
            return lowercased.hasSuffix(".localized") && lowercased.contains("apps")
        }
    }

    nonisolated private static func inPageURLAppBundleURLs(in directoryURL: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.filter { $0.pathExtension.lowercased() == "app" }
    }

    nonisolated private static func isInPageURLChromiumWebApp(bundle: Bundle, bundleID: String) -> Bool {
        if bundle.object(forInfoDictionaryKey: "CrAppModeShortcutID") != nil {
            return true
        }

        return Self.inPageURLChromiumHostBundleIDPrefixes.contains { prefix in
            bundleID.hasPrefix(prefix + ".app.")
        }
    }

    @MainActor
    func requestInPageURLPermission(for target: InPageURLBrowserTarget) async {
        guard !inPageURLBusyBundleIDs.contains(target.bundleID) else { return }
        inPageURLBusyBundleIDs.insert(target.bundleID)
        defer { inPageURLBusyBundleIDs.remove(target.bundleID) }

        let status = await inPageURLPermissionStatusAsync(
            for: target.bundleID,
            askUserIfNeeded: true
        )
        var cachedStates = inPageURLCachedPermissionStates()
        let state = await resolvedInPageURLPermissionState(
            from: status,
            bundleID: target.bundleID,
            previousState: inPageURLPermissionStateByBundleID[target.bundleID],
            cachedState: cachedStates[target.bundleID]
        )
        inPageURLPermissionStateByBundleID[target.bundleID] = state
        if inPageURLPermissionStateForCache(state) != nil {
            cachedStates[target.bundleID] = state
            persistInPageURLCachedPermissionStates(cachedStates)
        }
        refreshInPageURLRunningBundleIDs()

        recordInPageURLMetric(
            type: .inPageURLPermissionProbe,
            payload: [
                "bundleID": target.bundleID,
                "status": inPageURLPermissionDescription(for: state)
            ]
        )
    }

    @MainActor
    func launchInPageURLTarget(_ target: InPageURLBrowserTarget) async {
        guard !inPageURLBusyBundleIDs.contains(target.bundleID) else { return }
        inPageURLBusyBundleIDs.insert(target.bundleID)
        defer { inPageURLBusyBundleIDs.remove(target.bundleID) }

        if let appURL = target.appURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }

        try? await Task.sleep(for: .milliseconds(160), clock: .continuous)
        refreshInPageURLRunningBundleIDs()

        let status = await inPageURLPermissionStatusAsync(
            for: target.bundleID,
            askUserIfNeeded: false
        )
        var cachedStates = inPageURLCachedPermissionStates()
        let state = await resolvedInPageURLPermissionState(
            from: status,
            bundleID: target.bundleID,
            previousState: inPageURLPermissionStateByBundleID[target.bundleID],
            cachedState: cachedStates[target.bundleID]
        )
        inPageURLPermissionStateByBundleID[target.bundleID] = state
        if inPageURLPermissionStateForCache(state) != nil {
            cachedStates[target.bundleID] = state
            persistInPageURLCachedPermissionStates(cachedStates)
        }

        recordInPageURLMetric(
            type: .inPageURLPermissionProbe,
            payload: [
                "bundleID": target.bundleID,
                "action": "launch",
                "status": inPageURLPermissionDescription(for: inPageURLPermissionStateByBundleID[target.bundleID])
            ]
        )
    }

    func inPageURLPermissionStatusAsync(
        for bundleID: String,
        askUserIfNeeded: Bool
    ) async -> OSStatus {
        await withCheckedContinuation { continuation in
            Self.inPageURLPermissionProbeQueue.async {
                let status = Self.inPageURLPermissionStatus(
                    for: bundleID,
                    askUserIfNeeded: askUserIfNeeded
                )
                continuation.resume(returning: status)
            }
        }
    }

    private static func inPageURLPermissionStatus(
        for bundleID: String,
        askUserIfNeeded: Bool
    ) -> OSStatus {
        let automationBundleID = resolvedInPageURLAutomationBundleID(for: bundleID)
        var targetDesc = AEDesc()
        let bundleIDCString = automationBundleID.utf8CString
        let createStatus = bundleIDCString.withUnsafeBufferPointer { bufferPointer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                bufferPointer.baseAddress,
                max(0, bufferPointer.count - 1),
                &targetDesc
            )
        }

        guard createStatus == noErr else {
            return OSStatus(createStatus)
        }
        defer { AEDisposeDesc(&targetDesc) }

        return AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }

    func inPageURLPermissionState(from status: OSStatus) -> InPageURLPermissionState {
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .needsConsent
        default:
            return .unavailable(status)
        }
    }

    func resolvedInPageURLPermissionState(
        from status: OSStatus,
        bundleID: String,
        previousState: InPageURLPermissionState?,
        cachedState: InPageURLPermissionState?
    ) async -> InPageURLPermissionState {
        if status == OSStatus(procNotFound) {
            if let settingsState = await inPageURLPermissionStateFromSystemSettingsAsync(for: bundleID) {
                switch settingsState {
                case .granted, .denied:
                    return settingsState
                case .needsConsent, .unavailable:
                    break
                }
            }

            if previousState == .granted || previousState == .denied,
               let previousState {
                return previousState
            }

            if cachedState == .granted || cachedState == .denied,
               let cachedState {
                return cachedState
            }

            return .unavailable(status)
        }

        return inPageURLPermissionState(from: status)
    }

    func inPageURLPermissionStateFromSystemSettingsAsync(for targetBundleID: String) async -> InPageURLPermissionState? {
        await Task.detached(priority: .utility) {
            Self.inPageURLPermissionStateFromSystemSettingsSync(for: targetBundleID)
        }.value
    }

    nonisolated private static func inPageURLPermissionStateFromSystemSettingsSync(
        for targetBundleID: String
    ) -> InPageURLPermissionState? {
        let clientIdentifiers = inPageURLAutomationClientIdentifiers()
        guard !clientIdentifiers.isEmpty else {
            return nil
        }
        let automationBundleID = Self.resolvedInPageURLAutomationBundleID(for: targetBundleID)

        let tccDBPath = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(tccDBPath, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else {
            if db != nil {
                sqlite3_close(db)
            }
            return nil
        }
        defer { sqlite3_close(db) }

        let clientPlaceholders = Array(repeating: "?", count: clientIdentifiers.count).joined(separator: ", ")
        let query = """
        SELECT auth_value, client
        FROM access
        WHERE service = 'kTCCServiceAppleEvents'
          AND indirect_object_identifier = ?
          AND client IN (\(clientPlaceholders))
        ORDER BY last_modified DESC
        LIMIT 1;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindTargetResult = automationBundleID.withCString { cString in
            sqlite3_bind_text(statement, 1, cString, -1, sqliteTransient)
        }
        guard bindTargetResult == SQLITE_OK else { return nil }

        var bindFailures: [String] = []
        for (index, clientIdentifier) in clientIdentifiers.enumerated() {
            let bindResult = clientIdentifier.withCString { cString in
                sqlite3_bind_text(statement, Int32(index + 2), cString, -1, sqliteTransient)
            }
            if bindResult != SQLITE_OK {
                bindFailures.append("\(index + 2)=\(bindResult)")
            }
        }

        guard bindFailures.isEmpty else { return nil }

        let stepResult = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_ROW:
            let authValue = sqlite3_column_int(statement, 0)
            switch authValue {
            case 2:
                return .granted
            case 0:
                return .denied
            default:
                return .needsConsent
            }
        case SQLITE_DONE:
            return .needsConsent
        default:
            return nil
        }
    }

    nonisolated private static func inPageURLAutomationClientIdentifiers() -> [String] {
        var identifiers: [String] = []

        if let bundleID = Bundle.main.bundleIdentifier,
           !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            identifiers.append(bundleID)
        }

        if let executablePath = Bundle.main.executablePath,
           !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            identifiers.append(executablePath)
        }

        let commandPath = CommandLine.arguments.first ?? ""
        if !commandPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            identifiers.append(commandPath)
        }

        let bundlePath = Bundle.main.bundlePath
        if !bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            identifiers.append(bundlePath)
        }

        var seen: Set<String> = []
        return identifiers.filter { seen.insert($0).inserted }
    }

    nonisolated static func inPageURLHasStableAutomationClientIdentity() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func inPageURLPermissionDescription(for state: InPageURLPermissionState?) -> String {
        guard let state else { return "Unknown" }
        switch state {
        case .granted:
            return "Granted"
        case .denied:
            return "Denied"
        case .needsConsent:
            return "Needs Allow"
        case .unavailable(let status) where status == OSStatus(procNotFound):
            return "Launch to Verify"
        case .unavailable(let status):
            return "Unavailable (\(status))"
        }
    }

    func inPageURLPermissionColor(for state: InPageURLPermissionState?) -> Color {
        guard let state else { return .retraceSecondary }
        switch state {
        case .granted:
            return .retraceSuccess
        case .denied:
            return .retraceDanger
        case .needsConsent:
            return .retraceWarning
        case .unavailable:
            return .retraceSecondary
        }
    }
}
