import SwiftUI
import App
import Shared
import SQLCipher

/// Main app entry point
@main
struct RetraceApp: App {

    // MARK: - Properties

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Body

    var body: some Scene {
        // Menu bar app - no WindowGroup, use Settings for menu commands only
        Settings {
            EmptyView()
        }
        .commands {
            appCommands
        }
    }

    // MARK: - Commands

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            // Remove "New Window" since we're a menu bar app
        }

        // Add Dashboard and Timeline to the app menu (top left, after "About Retrace")
        CommandGroup(after: .appInfo) {
            Button("Open Dashboard") {
                DashboardWindowController.shared.show()
            }
            // Note: Global hotkey is registered via HotkeyManager from saved settings
            // Don't add a static .keyboardShortcut here as it would conflict

            Button("Open Timeline") {
                TimelineWindowController.shared.toggle()
            }
            // Note: Global hotkey is registered via HotkeyManager from saved settings
            // Don't add a static .keyboardShortcut here as it would conflict

            Divider()
        }

        CommandMenu("View") {
            Button("Dashboard") {
                DashboardWindowController.shared.show()
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Timeline") {
                // Open fullscreen timeline overlay
                TimelineWindowController.shared.toggle()
            }
            // Note: Global hotkey is registered via HotkeyManager from saved settings
            // Don't add a static .keyboardShortcut here as it would conflict

            Divider()

            Button("Settings") {
                DashboardWindowController.shared.toggleSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Recording") {
            Button("Start/Stop Recording") {
                Task {
                    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                        try? await appDelegate.toggleRecording()
                    }
                }
            }
            // Note: Global hotkey is registered via HotkeyManager from saved settings
            // Don't add a static .keyboardShortcut here as it would conflict
        }
    }

}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var menuBarManager: MenuBarManager?
    private var coordinatorWrapper: AppCoordinatorWrapper?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var wasRecordingBeforeSleep = false
    private var pendingDeeplinkURLs: [URL] = []
    private var isInitialized = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt user to move app to Applications folder if not already there
        AppMover.moveToApplicationsFolderIfNecessary()

        // CRITICAL FIX: Ensure bundle identifier is set
        // When running from Xcode/SPM, the bundle ID might not be set correctly
        if Bundle.main.bundleIdentifier == nil {
            // Set activation policy to accessory (menu bar app, no dock icon)
            // This is required when running without a proper bundle ID
            NSApp.setActivationPolicy(.accessory)
        }

        // Check if another instance is already running (skip if this is a relaunch)
        let isRelaunch = UserDefaults.standard.bool(forKey: "isRelaunching")
        if isRelaunch {
            UserDefaults.standard.removeObject(forKey: "isRelaunching")
        } else if isAnotherInstanceRunning() {
            Log.info("[AppDelegate] Another instance already running, activating it", category: .app)
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        }

        // Configure app appearance
        configureAppearance()

        // Initialize the Sparkle updater for automatic updates
        UpdaterManager.shared.initialize()

        // Initialize the app coordinator and UI
        Task { @MainActor in
            await initializeApp()
            
            // Record app launch metric
            if let coordinator = coordinatorWrapper?.coordinator {
                DashboardViewModel.recordAppLaunch(coordinator: coordinator)
            }
        }

        // Note: Permissions are now handled in the onboarding flow
    }

    @MainActor
    private func initializeApp() async {
        // Pre-flight check: Ensure custom storage path is accessible (if set)
        if !checkStoragePathAvailable() {
            return // User chose to quit or we're waiting for them to reconnect
        }

        do {
            let wrapper = AppCoordinatorWrapper()
            self.coordinatorWrapper = wrapper
            try await wrapper.initialize()
            Log.info("[AppDelegate] Coordinator initialized successfully", category: .app)

            // Setup menu bar icon
            let menuBar = MenuBarManager(
                coordinator: wrapper.coordinator,
                onboardingManager: wrapper.coordinator.onboardingManager
            )
            menuBar.setup()
            self.menuBarManager = menuBar

            // Configure the timeline window controller
            TimelineWindowController.shared.configure(coordinator: wrapper.coordinator)

            // Configure the dashboard window controller
            DashboardWindowController.shared.configure(coordinator: wrapper.coordinator)

            // Configure the pause reminder window controller
            PauseReminderWindowController.shared.configure(coordinator: wrapper.coordinator)

            // Setup sleep/wake observers to properly handle segment tracking
            setupSleepWakeObservers()

            Log.info("[AppDelegate] Menu bar and window controllers initialized", category: .app)

            // Mark as initialized before processing pending deeplinks
            isInitialized = true

            // Process any deeplinks that arrived before initialization completed
            if !pendingDeeplinkURLs.isEmpty {
                Log.info("[AppDelegate] Processing \(pendingDeeplinkURLs.count) pending deeplink(s)", category: .app)
                for url in pendingDeeplinkURLs {
                    handleDeeplink(url)
                }
                pendingDeeplinkURLs.removeAll()
            } else {
                // Show dashboard on first launch (only if no deeplinks)
                DashboardWindowController.shared.show()
            }

        } catch {
            Log.error("[AppDelegate] Failed to initialize: \(error)", category: .app)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running in menu bar even when window is closed
        return false
    }

    // MARK: - Storage Path Validation

    /// Pre-flight check to ensure custom storage path is accessible
    /// Returns true if app should continue, false if user chose to quit
    @MainActor
    private func checkStoragePathAvailable() -> Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

        // Only check if user has set a custom path (not new users)
        guard let customPath = defaults.string(forKey: "customRetraceDBLocation") else {
            return true // Using default path, always available
        }

        let fm = FileManager.default
        let expandedPath = NSString(string: customPath).expandingTildeInPath

        // Check if the custom path itself exists
        // User explicitly set this path, so we should verify it's there
        if fm.fileExists(atPath: expandedPath) {
            return true // Custom path exists
        }

        // Custom path doesn't exist - determine the appropriate message
        let parentDir = (expandedPath as NSString).deletingLastPathComponent
        let isDriveDisconnected = !fm.fileExists(atPath: parentDir)

        Log.warning("[AppDelegate] Custom storage path not found: \(expandedPath) (drive disconnected: \(isDriveDisconnected))", category: .app)

        let alert = NSAlert()
        if isDriveDisconnected {
            alert.messageText = "Storage Drive Not Found"
            alert.informativeText = """
                Retrace is configured to store data at:
                \(customPath)

                This location is not accessible. The drive may be disconnected.

                What would you like to do?
                """
        } else {
            alert.messageText = "Database Folder Not Found"
            alert.informativeText = """
                Retrace is configured to store data at:
                \(customPath)

                This folder no longer exists. It may have been moved or deleted.

                What would you like to do?
                """
        }
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Browse for Folder")
        alert.addButton(withTitle: "Reset to Default Location")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Browse for folder - open at parent of the missing path
            if let newPath = browseForDatabaseFolder(startingAt: parentDir) {
                defaults.set(newPath, forKey: "customRetraceDBLocation")
                defaults.synchronize()
                Log.info("[AppDelegate] User selected new storage location: \(newPath)", category: .app)
                return true
            } else {
                // User cancelled - show dialog again
                return checkStoragePathAvailable()
            }

        case .alertSecondButtonReturn:
            // Reset to default location
            defaults.removeObject(forKey: "customRetraceDBLocation")
            defaults.synchronize()
            Log.info("[AppDelegate] Reset to default storage location", category: .app)
            return true

        default:
            // Quit
            Log.info("[AppDelegate] User chose to quit", category: .app)
            NSApp.terminate(nil)
            return false
        }
    }

    /// Shows folder picker for selecting database location
    /// Returns the selected path if valid, nil if cancelled or invalid
    @MainActor
    private func browseForDatabaseFolder(startingAt directory: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for the Retrace database"
        panel.prompt = "Select"

        // Open at the specified directory if it exists
        if let dir = directory, FileManager.default.fileExists(atPath: dir) {
            panel.directoryURL = URL(fileURLWithPath: dir)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        let selectedPath = url.path
        let fm = FileManager.default
        let dbPath = "\(selectedPath)/retrace.db"
        let chunksPath = "\(selectedPath)/chunks"
        let hasDatabase = fm.fileExists(atPath: dbPath)
        let hasChunks = fm.fileExists(atPath: chunksPath)

        // If has database but no chunks, ask if they want to continue
        if hasDatabase && !hasChunks {
            let alert = NSAlert()
            alert.messageText = "Missing Chunks Folder"
            alert.informativeText = "The selected folder has retrace.db but is missing the 'chunks' folder with video files.\n\nRetrace may not be able to load existing video frames.\n\nDo you want to continue anyway?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue Anyway")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() != .alertFirstButtonReturn {
                // User cancelled - let them pick again
                return browseForDatabaseFolder(startingAt: directory)
            }
        }

        // If no database, check if directory is empty or has other files
        if !hasDatabase {
            let contents = (try? fm.contentsOfDirectory(atPath: selectedPath)) ?? []
            // Filter out hidden files like .DS_Store
            let visibleContents = contents.filter { !$0.hasPrefix(".") }

            if !visibleContents.isEmpty {
                // Folder has other files - show error dialog
                let alert = NSAlert()
                alert.messageText = "Invalid Folder Selection"
                alert.informativeText = "The selected folder contains other files but is not a valid Retrace database folder.\n\nPlease select either:\n• An existing Retrace folder (with retrace.db)\n• An empty folder for a new database"
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()

                // Let them pick again
                return browseForDatabaseFolder(startingAt: directory)
            }
        }

        // Verify it's a valid Retrace database
        if hasDatabase {
            let verification = verifyRetraceDatabase(at: dbPath)
            if !verification.isValid {
                let alert = NSAlert()
                alert.messageText = "Invalid Retrace Database"
                alert.informativeText = verification.error ?? "The selected folder contains a retrace.db file that is not a valid Retrace database."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()

                // Let them pick again
                return browseForDatabaseFolder(startingAt: directory)
            }
        }

        return selectedPath
    }

    /// Verifies that a file is a valid Retrace database (unencrypted SQLite with expected tables)
    private func verifyRetraceDatabase(at path: String) -> (isValid: Bool, error: String?) {
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

    // MARK: - Sleep/Wake Handling

    private func setupSleepWakeObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        let sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSystemSleep()
            }
        }
        sleepWakeObservers.append(sleepObserver)

        let wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSystemWake()
            }
        }
        sleepWakeObservers.append(wakeObserver)

        Log.info("[AppDelegate] Sleep/wake observers registered", category: .app)
    }

    @MainActor
    private func handleSystemSleep() async {
        guard let wrapper = coordinatorWrapper else { return }

        wasRecordingBeforeSleep = await wrapper.coordinator.isCapturing()

        if wasRecordingBeforeSleep {
            Log.info("[AppDelegate] System going to sleep - stopping pipeline to finalize current segment", category: .app)
            do {
                try await wrapper.coordinator.stopPipeline(persistState: false)
            } catch {
                Log.error("[AppDelegate] Failed to stop pipeline on sleep: \(error)", category: .app)
            }
        }
    }

    @MainActor
    private func handleSystemWake() async {
        guard let wrapper = coordinatorWrapper else { return }

        if wasRecordingBeforeSleep {
            Log.info("[AppDelegate] System woke from sleep - resuming pipeline", category: .app)
            do {
                try await wrapper.coordinator.startPipeline()
                await wrapper.refreshStatus()
            } catch {
                Log.error("[AppDelegate] Failed to resume pipeline on wake: \(error)", category: .app)
            }
        }
    }

    // MARK: - Recording Control

    func toggleRecording() async throws {
        guard let wrapper = coordinatorWrapper else { return }
        let isCapturing = await wrapper.coordinator.isCapturing()
        if isCapturing {
            try await wrapper.stopPipeline()
        } else {
            try await wrapper.startPipeline()
        }
    }

    // MARK: - Single Instance Check

    private func isAnotherInstanceRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        let myPID = ProcessInfo.processInfo.processIdentifier

        let retraceApps = runningApps.filter { app in
            let isRetrace = app.bundleIdentifier?.contains("retrace") == true ||
                           app.localizedName?.contains("Retrace") == true
            return isRetrace && app.processIdentifier != myPID
        }

        return !retraceApps.isEmpty
    }

    private func activateExistingInstance() {
        let runningApps = NSWorkspace.shared.runningApplications
        if let existingApp = runningApps.first(where: { app in
            (app.bundleIdentifier?.contains("retrace") == true ||
             app.localizedName?.contains("Retrace") == true) &&
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) {
            existingApp.activate(options: .activateIgnoringOtherApps)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers {
            workspaceCenter.removeObserver(observer)
        }
        sleepWakeObservers.removeAll()

        // Save timeline state (filters, search) for cross-session persistence
        TimelineWindowController.shared.saveStateForTermination()

        // Force record any active timeline session before terminating
        TimelineWindowController.shared.forceRecordSessionMetrics()

        Log.info("[AppDelegate] Application terminating", category: .app)
    }

    // MARK: - URL Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        Log.info("[AppDelegate] Received URLs: \(urls), isInitialized: \(isInitialized)", category: .app)
        for url in urls {
            if isInitialized {
                Task { @MainActor in
                    self.handleDeeplink(url)
                }
            } else {
                // Queue the URL to be processed after initialization
                Log.info("[AppDelegate] Queuing deeplink for later: \(url)", category: .app)
                pendingDeeplinkURLs.append(url)
            }
        }
    }

    @MainActor
    private func handleDeeplink(_ url: URL) {
        guard url.scheme == "retrace" else {
            Log.warning("[AppDelegate] Invalid URL scheme: \(url.scheme ?? "none")", category: .app)
            return
        }

        guard let host = url.host else {
            Log.warning("[AppDelegate] No host in URL: \(url)", category: .app)
            return
        }

        let queryParams = url.queryParameters

        switch host.lowercased() {
        case "timeline":
            // Parse timestamp from query params (t=unix_ms)
            let timestamp = queryParams["t"].flatMap { Int64($0) }.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            Log.info("[AppDelegate] Opening timeline at timestamp: \(String(describing: timestamp))", category: .app)

            if let timestamp = timestamp {
                TimelineWindowController.shared.showAndNavigate(to: timestamp)
            } else {
                TimelineWindowController.shared.show()
            }

        case "search":
            // Parse search parameters
            let timestamp = queryParams["t"].flatMap { Int64($0) }.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            Log.info("[AppDelegate] Opening search/timeline at timestamp: \(String(describing: timestamp))", category: .app)

            if let timestamp = timestamp {
                TimelineWindowController.shared.showAndNavigate(to: timestamp)
            } else {
                TimelineWindowController.shared.show()
            }

        default:
            Log.warning("[AppDelegate] Unknown deeplink route: \(host)", category: .app)
        }
    }

    // MARK: - Permissions

    private func requestPermissions() {
        // Request screen recording permission
        // This will show a system dialog on first run
        CGRequestScreenCaptureAccess()

        // Request accessibility permission
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Appearance

    private func configureAppearance() {
        // Force dark mode - the app UI is designed for dark theme
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

// MARK: - URL Handling

extension RetraceApp {
    /// Handle URL scheme: retrace://
    func onOpenURL(_ url: URL) {
        Log.info("[RetraceApp] Handling URL: \(url)", category: .app)
        // URL handling is done in ContentView via .onOpenURL
    }
}
