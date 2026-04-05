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
    /// Perform quick delete for the specified time range
    func performQuickDelete(option: QuickDeleteOption) {
        isDeleting = true
        deletingOption = option

        Task {
            do {
                // Use deleteRecentData to delete frames NEWER than the cutoff date
                let result = try await coordinatorWrapper.coordinator.deleteRecentData(
                    newerThan: option.cutoffDate,
                    metricSource: "quick_delete"
                )

                await MainActor.run {
                    isDeleting = false
                    deletingOption = nil
                    if result.affectedFrames > 0 {
                        showSettingsToast(quickDeleteToastMessage(for: result, option: option))
                        // Notify timeline to reload so deleted frames don't appear
                        NotificationCenter.default.post(name: .dataSourceDidChange, object: nil)
                    } else {
                        showSettingsToast("No recordings found in the \(option.displayName)")
                    }
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    deletingOption = nil
                    showSettingsToast("Delete failed: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func quickDeleteToastMessage(for result: FrameDeletionResult, option: QuickDeleteOption) -> String {
        if result.queuedFrames == 0 {
            return "Deleted \(result.completedFrames) frames from the \(option.displayName)"
        }
        if result.completedFrames == 0 {
            return "Queued deletion for \(result.queuedFrames) frames from the \(option.displayName)."
        }
        return "Deleted \(result.completedFrames) frames and queued \(result.queuedFrames) more from the \(option.displayName)"
    }
}

// MARK: - Excluded Apps Management

extension SettingsView {
    func loadExcludedAppsForRedaction() {
        Task {
            let installed = await Task.detached(priority: .utility) {
                AppNameResolver.shared.getInstalledApps()
                    .map { (bundleID: $0.bundleID, name: $0.name) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }.value

            let installedBundleIDs = Set(installed.map(\.bundleID))
            await MainActor.run {
                installedAppsForExcludedRedaction = installed
            }

            do {
                let historyBundleIDs = try await coordinatorWrapper.coordinator.getDistinctAppBundleIDs()
                let otherBundleIDs = historyBundleIDs.filter { !installedBundleIDs.contains($0) }
                let resolvedApps = await Task.detached(priority: .utility) {
                    AppNameResolver.shared.resolveAll(bundleIDs: otherBundleIDs)
                        .map { (bundleID: $0.bundleID, name: $0.name) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }.value

                await MainActor.run {
                    otherAppsForExcludedRedaction = resolvedApps
                }
            } catch {
                Log.error("[SettingsView] Failed to load additional apps for app-level redaction: \(error)", category: .ui)
            }
        }
    }

    func toggleExcludedRedactionApp(_ bundleID: String?) {
        guard let bundleID else { return }

        var apps = excludedApps
        if let index = apps.firstIndex(where: { $0.bundleID == bundleID }) {
            apps.remove(at: index)
        } else {
            let name =
                installedAppsForExcludedRedaction.first(where: { $0.bundleID == bundleID })?.name ??
                otherAppsForExcludedRedaction.first(where: { $0.bundleID == bundleID })?.name ??
                bundleID
            apps.append(
                ExcludedAppInfo(
                    bundleID: bundleID,
                    name: name,
                    iconPath: nil
                )
            )
        }

        saveExcludedApps(apps)
    }

    func saveExcludedApps(_ apps: [ExcludedAppInfo]) {
        if let data = try? JSONEncoder().encode(apps),
           let string = String(data: data, encoding: .utf8) {
            excludedAppsString = string
        } else {
            excludedAppsString = ""
        }
        updateExcludedAppsConfig()
    }

    /// Add multiple apps to the exclusion list
    func addExcludedApps(_ newApps: [ExcludedAppInfo]) {
        guard !newApps.isEmpty else { return }

        var currentApps: [ExcludedAppInfo] = []
        if !excludedAppsString.isEmpty,
           let data = excludedAppsString.data(using: .utf8),
           let apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) {
            currentApps = apps
        }

        // Filter out duplicates
        var addedCount = 0
        for app in newApps {
            if !currentApps.contains(where: { $0.bundleID == app.bundleID }) {
                currentApps.append(app)
                addedCount += 1
            }
        }

        guard addedCount > 0 else { return }

        saveExcludedApps(currentApps)

        // Show feedback
        showExcludedAppsUpdateFeedback(added: addedCount)
    }

    /// Add an app to the exclusion list (single app - kept for compatibility)
    func addExcludedApp(_ app: ExcludedAppInfo) {
        addExcludedApps([app])
    }

    /// Remove an app from the exclusion list
    func removeExcludedApp(_ app: ExcludedAppInfo) {
        guard let data = excludedAppsString.data(using: .utf8),
              var apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) else {
            return
        }

        apps.removeAll { $0.bundleID == app.bundleID }

        saveExcludedApps(apps)

        // Show feedback
        showExcludedAppsUpdateFeedback(removed: app.name)
    }

    func excludedAppBundleIDsForCaptureConfig() -> Set<String> {
        var excludedBundleIDs: Set<String> = ["com.apple.loginwindow"]
        for app in excludedApps {
            excludedBundleIDs.insert(app.bundleID)
        }
        return excludedBundleIDs
    }

    func updateExcludedAppsConfig() {
        Task {
            let excludedBundleIDs = excludedAppBundleIDsForCaptureConfig()

            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Excluded apps updated: \(excludedBundleIDs.count - 1) apps excluded",
                failureLog: "[SettingsView] Failed to update excluded apps config",
                transform: { $0.updating(excludedAppBundleIDs: excludedBundleIDs) }
            )
        }
    }

    func parseRedactionPatterns(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func updatePrivateWindowRedactionSetting() {
        let excludePrivateWindowsEnabled = excludePrivateWindows
        Task {
            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Private window redaction updated to: \(excludePrivateWindowsEnabled)",
                failureLog: "[SettingsView] Failed to update private window redaction setting",
                transform: { $0.updating(excludePrivateWindows: excludePrivateWindowsEnabled) },
                onSuccess: { coordinator in
                    DashboardViewModel.recordPrivateWindowRedactionToggle(
                        coordinator: coordinator,
                        enabled: excludePrivateWindowsEnabled,
                        source: "settings_privacy"
                    )
                    await MainActor.run {
                        showSettingsToast(
                            excludePrivateWindowsEnabled
                                ? "Incognito/private redaction enabled"
                                : "Incognito/private redaction disabled"
                        )
                    }
                }
            )
        }
    }

    func updateRedactionRulesConfig() {
        Task {
            let windowPatterns = enableCustomPatternWindowRedaction ? parseRedactionPatterns(redactWindowTitlePatternsRaw) : []
            let urlPatterns = enableCustomPatternWindowRedaction ? parseRedactionPatterns(redactBrowserURLPatternsRaw) : []

            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Updated redaction rules: windowPatterns=\(windowPatterns.count), urlPatterns=\(urlPatterns.count)",
                failureLog: "[SettingsView] Failed to update redaction rules",
                transform: {
                    $0.updating(
                        redactWindowTitlePatterns: windowPatterns,
                        redactBrowserURLPatterns: urlPatterns
                    )
                },
                onSuccess: { coordinator in
                    showRedactionRulesUpdateFeedback()
                    DashboardViewModel.recordRedactionRulesUpdated(
                        coordinator: coordinator,
                        windowPatternCount: windowPatterns.count,
                        urlPatternCount: urlPatterns.count
                    )
                }
            )
        }
    }

    func showRedactionRulesUpdateFeedback() {
        Task { @MainActor in
            showSettingsToast("Redaction rules updated")
        }
    }

    /// Show brief feedback for excluded apps changes
    func showExcludedAppsUpdateFeedback(added: Int) {
        let message = added == 1 ? "App excluded" : "\(added) apps excluded"
        Task { @MainActor in
            showSettingsToast(message)
        }
    }

    /// Show brief feedback for app removal
    func showExcludedAppsUpdateFeedback(removed appName: String) {
        Task { @MainActor in
            showSettingsToast("\(appName) removed")
        }
    }

    /// Show the app picker panel with multiple selection support
    func showAppPickerMultiple(completion: @escaping ([ExcludedAppInfo]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Apps to Exclude"
        panel.message = "Choose applications that should not be recorded (Cmd+Click to select multiple)"
        panel.prompt = "Exclude Apps"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.begin { response in
            guard response == .OK else {
                completion([])
                return
            }

            let apps = panel.urls.compactMap { ExcludedAppInfo.from(appURL: $0) }
            completion(apps)
        }
    }

    /// Show the app picker panel (single selection - kept for compatibility)
    func showAppPicker(completion: @escaping (ExcludedAppInfo?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select an App to Exclude"
        panel.message = "Choose an application that should not be recorded"
        panel.prompt = "Exclude App"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }

            let appInfo = ExcludedAppInfo.from(appURL: url)
            completion(appInfo)
        }
    }
}

// MARK: - Permission Checking
