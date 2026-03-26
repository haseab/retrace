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
    func retentionDisplayTextFor(_ days: Int) -> String {
        switch days {
        case 0: return "Forever"
        case 3: return "3 days"
        case 7: return "1 week"
        case 14: return "2 weeks"
        case 30: return "1 month"
        case 60: return "2 months"
        case 90: return "3 months"
        case 180: return "6 months"
        case 365: return "1 year"
        default: return "\(days) days"
        }
    }

    // MARK: - Retention Change Notification Timer

    func startRetentionChangeTimer() {
        // Reset progress
        retentionChangeProgress = 0

        // Cancel any existing timer
        retentionChangeTimer?.invalidate()

        let duration: Double = 10.0  // 10 seconds
        let updateInterval: Double = 0.05  // 50ms updates for smooth animation
        let totalSteps = duration / updateInterval

        retentionChangeTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [self] timer in
            withAnimation(.linear(duration: updateInterval)) {
                retentionChangeProgress += 1.0 / totalSteps
            }

            if retentionChangeProgress >= 1.0 {
                timer.invalidate()
                dismissRetentionChangeNotification()
            }
        }
    }

    func dismissRetentionChangeNotification() {
        withAnimation(.easeOut(duration: 0.3)) {
            retentionSettingChanged = false
        }
        retentionChangeProgress = 0
        retentionChangeTimer?.invalidate()
        retentionChangeTimer = nil
    }

    // MARK: - Retention Exclusion Data Loading

    func loadRetentionExclusionData() {
        // Load installed apps
        let installed = AppNameResolver.shared.getInstalledApps()
        let installedBundleIDs = Set(installed.map { $0.bundleID })
        installedAppsForRetention = installed.map { (bundleID: $0.bundleID, name: $0.name) }

        // Load other apps from database (apps that were recorded but aren't currently installed)
        Task {
            do {
                let historyBundleIDs = try await coordinatorWrapper.coordinator.getDistinctAppBundleIDs()
                let otherBundleIDs = historyBundleIDs.filter { !installedBundleIDs.contains($0) }
                let resolvedApps = AppNameResolver.shared.resolveAll(bundleIDs: otherBundleIDs)
                let other = resolvedApps.map { appInfo in
                    (bundleID: appInfo.bundleID, name: appInfo.name)
                }

                await MainActor.run {
                    otherAppsForRetention = other
                }
            } catch {
                Log.error("[Settings] Failed to load history apps for retention: \(error)", category: .ui)
            }

            // Load tags
            do {
                let tags = try await coordinatorWrapper.coordinator.getAllTags()
                await MainActor.run {
                    availableTagsForRetention = tags
                }
            } catch {
                Log.error("[Settings] Failed to load tags for retention: \(error)", category: .ui)
            }
        }
    }

    /// Toggle an app in/out of retention exclusions
    func toggleRetentionExcludedApp(_ bundleID: String?) {
        if let bundleID = bundleID {
            var current = retentionExcludedApps
            if current.contains(bundleID) {
                current.remove(bundleID)
            } else {
                current.insert(bundleID)
            }
            retentionExcludedAppsString = current.sorted().joined(separator: ",")
        } else {
            // nil passed - clear exclusions
            retentionExcludedAppsString = ""
        }
    }

    /// Toggle a tag in/out of retention exclusions
    func toggleRetentionExcludedTag(_ tagID: TagID?) {
        if let tagID = tagID {
            var current = retentionExcludedTagIds
            if current.contains(tagID.value) {
                current.remove(tagID.value)
            } else {
                current.insert(tagID.value)
            }
            retentionExcludedTagIdsString = current.sorted().map { String($0) }.joined(separator: ",")
        } else {
            // nil passed - clear exclusions
            retentionExcludedTagIdsString = ""
        }
    }

    /// Clear all retention exclusions
    func clearRetentionExclusions() {
        retentionExcludedAppsString = ""
        retentionExcludedTagIdsString = ""
    }

    // MARK: - Advanced Settings Actions

    func loadDatabaseSchema() {
        Task {
            do {
                let schema = try await coordinatorWrapper.coordinator.getDatabaseSchemaDescription()
                await MainActor.run {
                    databaseSchemaText = schema
                }
            } catch {
                await MainActor.run {
                    databaseSchemaText = "Error loading schema: \(error.localizedDescription)"
                }
            }
        }
    }

    func restartApp() {
        AppRelaunch.relaunch()
    }

    func restartAndResumeRecording() {
        // Set flag in UserDefaults to auto-start recording on next launch
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        defaults.set(true, forKey: "shouldAutoStartRecording")
        defaults.synchronize()
        Log.info("Set shouldAutoStartRecording flag for restart", category: .ui)

        // Restart the app
        AppRelaunch.relaunch()
    }

    nonisolated static func normalizeRewindFolderPath(_ path: String) -> String {
        StorageSettingsViewModel.normalizeRewindFolderPath(path)
    }

    func selectRetraceDBLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a location for the Retrace database"
        panel.prompt = "Select"

        // Open to current location if set, otherwise default storage root
        if let currentPath = customRetraceDBLocation {
            panel.directoryURL = URL(fileURLWithPath: (currentPath as NSString).deletingLastPathComponent)
        } else {
            panel.directoryURL = URL(fileURLWithPath: AppPaths.expandedStorageRoot)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let selectedPath = url.path
        let defaultPath = NSString(string: AppPaths.defaultStorageRoot).expandingTildeInPath
        let currentPath = customRetraceDBLocation ?? defaultPath

        // Check if selecting the same location that's currently active
        if selectedPath == currentPath {
            Log.info("Retrace database location unchanged (same as current): \(selectedPath)", category: .ui)
            return
        }

        Task { @MainActor in
            let validation = await validateRetraceFolderSelection(at: selectedPath)

            switch validation {
            case .invalid(let title, let message):
                showDatabaseAlert(type: .error, title: title, message: message)
                return

            case .missingChunks:
                let shouldContinue = showDatabaseConfirmation(
                    title: "Missing Chunks Folder",
                    message: "The selected folder has retrace.db but is missing the 'chunks' folder with video files.\n\nRetrace may not be able to load existing video frames.\n\nDo you want to continue anyway?",
                    primaryButton: "Continue Anyway"
                )
                if !shouldContinue {
                    return
                }

            case .valid:
                break
            }

            // If selecting the default location, clear custom path
            if selectedPath == defaultPath {
                customRetraceDBLocation = nil
                Log.info("Retrace database location reset to default: \(selectedPath)", category: .ui)
            } else {
                customRetraceDBLocation = selectedPath
                Log.info("Retrace database location changed to: \(selectedPath)", category: .ui)
            }
        }
    }

    func selectRewindDBLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose the Rewind data folder (contains db-enc.sqlite3)"
        panel.prompt = "Select Folder"

        // Open to current location if set, otherwise default Rewind storage root
        if customRewindDBLocation != nil {
            panel.directoryURL = URL(fileURLWithPath: rewindFolderPath)
        } else {
            panel.directoryURL = URL(fileURLWithPath: AppPaths.expandedRewindStorageRoot)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let selectedPath = url.path
        let defaultPath = NSString(string: AppPaths.defaultRewindStorageRoot).expandingTildeInPath
        let currentPath = rewindFolderPath

        // Check if selecting the same location that's currently active
        if selectedPath == currentPath {
            Log.info("Rewind database folder unchanged (same as current): \(selectedPath)", category: .ui)
            return
        }

        Task { @MainActor in
            let validationResult = await validateRewindFolderSelection(at: selectedPath)

            switch validationResult {
            case .invalid(let message):
                showDatabaseAlert(
                    type: .error,
                    title: "Invalid Rewind Folder",
                    message: message
                )
                return

            case .valid(hasChunks: true):
                // Valid Rewind folder structure - apply immediately
                applyRewindDBLocation(selectedPath, defaultPath: defaultPath)

            case .valid(hasChunks: false):
                // Database exists but no chunks folder - ask user if they want to continue
                let shouldContinue = showDatabaseConfirmation(
                    title: "Missing Chunks Folder",
                    message: "The selected Rewind folder contains db-enc.sqlite3, but the 'chunks' folder (video storage) was not found in the same directory.\n\nRetrace may not be able to load video frames from this database.",
                    primaryButton: "Continue Anyway"
                )
                if shouldContinue {
                    applyRewindDBLocation(selectedPath, defaultPath: defaultPath)
                }
            }
        }
    }

    enum RetraceFolderValidationOutcome: Sendable {
        case valid
        case missingChunks
        case invalid(title: String, message: String)
    }

    enum RewindFolderValidationOutcome: Sendable {
        case valid(hasChunks: Bool)
        case invalid(message: String)
    }

    func validateRetraceFolderSelection(at selectedPath: String) async -> RetraceFolderValidationOutcome {
        await Task.detached(priority: .userInitiated) {
            Self.validateRetraceFolderSelectionSync(at: selectedPath)
        }.value
    }

    nonisolated private static func validateRetraceFolderSelectionSync(at selectedPath: String) -> RetraceFolderValidationOutcome {
        let fm = FileManager.default
        let dbPath = "\(selectedPath)/retrace.db"
        let chunksPath = "\(selectedPath)/chunks"
        let hasDatabase = fm.fileExists(atPath: dbPath)
        let hasChunks = fm.fileExists(atPath: chunksPath)

        if hasDatabase {
            let verification = verifyRetraceDatabase(at: dbPath)
            guard verification.isValid else {
                return .invalid(
                    title: "Invalid Retrace Database",
                    message: verification.error ?? "The selected folder contains a retrace.db file that is not a valid Retrace database."
                )
            }

            if let writeProbeFailure = probeRetraceFolderWriteAccess(at: selectedPath) {
                return .invalid(
                    title: "Folder Not Writable",
                    message: writeProbeFailure
                )
            }

            return hasChunks ? .valid : .missingChunks
        }

        let contents = (try? fm.contentsOfDirectory(atPath: selectedPath)) ?? []
        let visibleContents = contents.filter { !$0.hasPrefix(".") }
        guard visibleContents.isEmpty else {
            return .invalid(
                title: "Invalid Folder Selection",
                message: "The selected folder contains other files but is not a valid Retrace database folder.\n\nPlease select either:\n• An existing Retrace folder (with retrace.db)\n• An empty folder for a new database"
            )
        }

        if let writeProbeFailure = probeRetraceFolderWriteAccess(at: selectedPath) {
            return .invalid(
                title: "Folder Not Writable",
                message: writeProbeFailure
            )
        }

        return .valid
    }

    nonisolated private static func probeRetraceFolderWriteAccess(at selectedPath: String) -> String? {
        let probeURL = URL(fileURLWithPath: selectedPath, isDirectory: true)
            .appendingPathComponent(".retrace-write-probe-\(UUID().uuidString)")
        let probeData = Data("retrace-write-probe".utf8)

        do {
            try probeData.write(to: probeURL, options: .atomic)
            try FileManager.default.removeItem(at: probeURL)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: probeURL)
            return "The selected folder is not writable by Retrace.\n\nChoose a folder where Retrace can create and remove files.\n\nUnderlying error: \(error.localizedDescription)"
        }
    }

    func validateRewindFolderSelection(at selectedPath: String) async -> RewindFolderValidationOutcome {
        await Task.detached(priority: .userInitiated) {
            Self.validateRewindFolderSelectionSync(at: selectedPath)
        }.value
    }

    nonisolated private static func validateRewindFolderSelectionSync(at selectedPath: String) -> RewindFolderValidationOutcome {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: selectedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .invalid(message: "The selected location is not a folder.")
        }

        let dbPath = "\(selectedPath)/db-enc.sqlite3"
        guard fileManager.fileExists(atPath: dbPath) else {
            return .invalid(message: "The selected folder does not contain db-enc.sqlite3.")
        }

        let verificationResult = verifyRewindDatabase(at: dbPath)
        guard verificationResult.isValid else {
            return .invalid(message: verificationResult.error ?? "The selected folder does not contain a valid Rewind database.")
        }

        let chunksPath = "\(selectedPath)/chunks"
        let hasChunks = fileManager.fileExists(atPath: chunksPath)
        return .valid(hasChunks: hasChunks)
    }

    /// Verifies that a file is a valid Retrace database (unencrypted SQLite with expected tables)
    nonisolated private static func verifyRetraceDatabase(at path: String) -> (isValid: Bool, error: String?) {
        var db: OpaquePointer?

        // Try to open the database
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            return (false, "Failed to open database: \(errorMsg)")
        }

        // Verify we can read from sqlite_master (confirms it's a valid SQLite database)
        var testStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &testStmt, nil) == SQLITE_OK,
              sqlite3_step(testStmt) == SQLITE_ROW else {
            sqlite3_finalize(testStmt)
            sqlite3_close(db)
            return (false, "File is not a valid SQLite database.")
        }
        sqlite3_finalize(testStmt)

        // Check for Retrace-specific tables (frame, segment, video)
        let requiredTables = ["frame", "segment", "video"]
        for table in requiredTables {
            var stmt: OpaquePointer?
            let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='\(table)'"
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else {
                sqlite3_finalize(stmt)
                sqlite3_close(db)
                return (false, "Database is missing required '\(table)' table. This may not be a Retrace database.")
            }
            sqlite3_finalize(stmt)
        }

        sqlite3_close(db)
        return (true, nil)
    }

    /// Verifies that a file is a valid Rewind database by attempting to open it with SQLCipher (encrypted)
    nonisolated private static func verifyRewindDatabase(at path: String) -> (isValid: Bool, error: String?) {
        var db: OpaquePointer?

        // Try to open the database
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            return (false, "Failed to open database: \(errorMsg)")
        }

        // Set the Rewind encryption key
        let rewindPassword = "soiZ58XZJhdka55hLUp18yOtTUTDXz7Diu7Z4JzuwhRwGG13N6Z9RTVU1fGiKkuF"
        let keySQL = "PRAGMA key = '\(rewindPassword)'"
        var keyError: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, keySQL, nil, nil, &keyError) != SQLITE_OK {
            let error = keyError.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(keyError)
            sqlite3_close(db)
            return (false, "Failed to set encryption key: \(error)")
        }

        // Set cipher compatibility (Rewind uses SQLCipher 4)
        var compatError: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, "PRAGMA cipher_compatibility = 4", nil, nil, &compatError) != SQLITE_OK {
            let error = compatError.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(compatError)
            sqlite3_close(db)
            return (false, "Failed to set cipher compatibility: \(error)")
        }

        // Verify connection by querying sqlite_master
        var testStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &testStmt, nil) == SQLITE_OK,
              sqlite3_step(testStmt) == SQLITE_ROW else {
            sqlite3_finalize(testStmt)
            sqlite3_close(db)
            return (false, "Database encryption verification failed. This may not be a Rewind database.")
        }
        sqlite3_finalize(testStmt)

        // Check for Rewind-specific table (frame table)
        var frameStmt: OpaquePointer?
        let frameQuery = "SELECT name FROM sqlite_master WHERE type='table' AND name='frame'"
        guard sqlite3_prepare_v2(db, frameQuery, -1, &frameStmt, nil) == SQLITE_OK,
              sqlite3_step(frameStmt) == SQLITE_ROW else {
            sqlite3_finalize(frameStmt)
            sqlite3_close(db)
            return (false, "Database does not contain expected Rewind tables (missing 'frame' table).")
        }
        sqlite3_finalize(frameStmt)

        sqlite3_close(db)
        return (true, nil)
    }

    func applyRewindDBLocation(_ path: String, defaultPath: String) {
        let normalizedPath = Self.normalizeRewindFolderPath(path)
        if normalizedPath == defaultPath {
            customRewindDBLocation = nil
            Log.info("Rewind database folder reset to default: \(normalizedPath)", category: .ui)
        } else {
            customRewindDBLocation = normalizedPath
            Log.info("Rewind database folder changed to: \(normalizedPath)", category: .ui)
        }

        // Apply changes immediately by reconnecting Rewind source
        Task {
            let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
            let useRewindData = defaults.bool(forKey: "useRewindData")

            if useRewindData {
                Log.info("Reconnecting Rewind source with new location", category: .ui)
                // Disconnect old source
                await coordinatorWrapper.coordinator.setRewindSourceEnabled(false)
                // Reconnect with new location
                await coordinatorWrapper.coordinator.setRewindSourceEnabled(true)
                Log.info("✓ Rewind source reconnected", category: .ui)

                // Notify timeline to reload
                await MainActor.run {
                    SearchViewModel.clearPersistedSearchCache()
                    NotificationCenter.default.post(name: .dataSourceDidChange, object: nil)
                    Log.info("✓ Timeline notified of Rewind database change", category: .ui)
                }
            } else {
                Log.info("Rewind data not enabled, skipping reconnection", category: .ui)
            }
        }
    }

    func resetDatabaseLocations() {
        let hadCustomRewind = customRewindDBLocation != nil

        customRetraceDBLocation = nil
        customRewindDBLocation = nil
        Log.info("Database locations reset to defaults", category: .ui)

        // If Rewind was customized, apply the default location immediately
        if hadCustomRewind {
            Task {
                let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
                let useRewindData = defaults.bool(forKey: "useRewindData")

                if useRewindData {
                    Log.info("Reconnecting Rewind source with default location", category: .ui)
                    // Disconnect and reconnect to pick up default path
                    await coordinatorWrapper.coordinator.setRewindSourceEnabled(false)
                    await coordinatorWrapper.coordinator.setRewindSourceEnabled(true)
                    Log.info("✓ Rewind source reconnected to default location", category: .ui)

                    await MainActor.run {
                        SearchViewModel.clearPersistedSearchCache()
                        NotificationCenter.default.post(name: .dataSourceDidChange, object: nil)
                    }
                }
            }
        }
    }

    func resetAllSettings() {
        // Reset all UserDefaults to their default values
        let domain = "io.retrace.app"
        settingsStore.removePersistentDomain(forName: domain)
        settingsStore.synchronize()

        // Reset all pages using SettingsDefaults as source of truth
        resetGeneralSettings()
        resetCaptureSettings()
        resetStorageSettings()
        resetPrivacySettings()
        resetAdvancedSettings()
    }

    func deleteAllData() {
        Task {
            // Stop capture pipeline first
            try? await coordinatorWrapper.stopPipeline()

            // Delete the entire storage directory (respects custom location)
            let storagePath = AppPaths.expandedStorageRoot
            try? FileManager.default.removeItem(atPath: storagePath)

            // Quit the app - user will need to restart
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func clearAppNameCache() {
        let entriesCleared = AppNameResolver.shared.clearCache()
        if entriesCleared > 0 {
            Task { @MainActor in
                showSettingsToast("Cleared \(entriesCleared) cached app names. Changes take effect immediately.")
            }
        } else {
            Task { @MainActor in
                showSettingsToast("Cache was already empty. No restart needed.")
            }
        }
    }

    // MARK: - Alert Helpers

    enum AlertType {
        case error
        case warning
        case info

        var style: NSAlert.Style {
            switch self {
            case .error: return .critical
            case .warning: return .warning
            case .info: return .informational
            }
        }
    }

    /// Shows a simple alert dialog with an OK button
    func showDatabaseAlert(type: AlertType, title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = type.style
        alert.addButton(withTitle: "OK")
        alert.runModal()

        switch type {
        case .error:
            Log.error("\(title): \(message)", category: .ui)
        case .warning:
            Log.warning("\(title): \(message)", category: .ui)
        case .info:
            Log.info("\(title): \(message)", category: .ui)
        }
    }

    /// Shows a confirmation dialog with Continue/Cancel buttons
    /// Returns true if the user clicked the primary button
    func showDatabaseConfirmation(title: String, message: String, primaryButton: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: primaryButton)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
