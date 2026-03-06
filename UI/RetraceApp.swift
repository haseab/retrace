import SwiftUI
import App
import Shared
import SQLCipher
import Darwin
import IOKit.ps

private enum WatchdogRelaunchGuard {
    private static let lock = NSLock()
    private static let relaunchTimestampsKey = "watchdogAutoRelaunchTimestamps"
    private static let relaunchWindowSeconds: TimeInterval = 5 * 60
    private static let maxRelaunchesPerWindow = 2

    struct Decision {
        let shouldRelaunch: Bool
        let recentCount: Int
    }

    static func evaluateAndRecord(now: Date = Date()) -> Decision {
        lock.lock()
        defer { lock.unlock() }

        let defaults = UserDefaults.standard
        let cutoff = now.timeIntervalSince1970 - relaunchWindowSeconds
        var timestamps = (defaults.array(forKey: relaunchTimestampsKey) as? [TimeInterval] ?? [])
            .filter { $0 >= cutoff }

        if timestamps.count >= maxRelaunchesPerWindow {
            defaults.set(timestamps, forKey: relaunchTimestampsKey)
            defaults.synchronize()
            return Decision(shouldRelaunch: false, recentCount: timestamps.count)
        }

        timestamps.append(now.timeIntervalSince1970)
        defaults.set(timestamps, forKey: relaunchTimestampsKey)
        defaults.synchronize()
        return Decision(shouldRelaunch: true, recentCount: timestamps.count)
    }
}

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

            Button("Open Changelog") {
                DashboardWindowController.shared.showChangelog()
            }

            Button("Open Timeline") {
                TimelineWindowController.shared.toggle()
            }
            // Note: Global hotkey is registered via HotkeyManager from saved settings
            // Don't add a static .keyboardShortcut here as it would conflict

            Divider()
        }

        CommandMenu("View") {
            Button("Dashboard") {
                if TimelineWindowController.shared.isVisible {
                    TimelineWindowController.shared.hideToShowDashboard()
                }
                DashboardWindowController.shared.show()
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Changelog") {
                if TimelineWindowController.shared.isVisible {
                    TimelineWindowController.shared.hideToShowDashboard()
                }
                DashboardWindowController.shared.showChangelog()
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Timeline") {
                // Open fullscreen timeline overlay
                TimelineWindowController.shared.toggle()
            }
            // Note: Global hotkey is registered via HotkeyManager from saved settings
            // Don't add a static .keyboardShortcut here as it would conflict

            Divider()

            Button("Settings") {
                if TimelineWindowController.shared.isVisible {
                    TimelineWindowController.shared.hideToShowDashboard()
                }
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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    var menuBarManager: MenuBarManager?
    private var coordinatorWrapper: AppCoordinatorWrapper?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var powerSettingsApplyTask: Task<Void, Never>?
    private var powerSettingsObserver: NSObjectProtocol?
    private var lowPowerModeObserver: NSObjectProtocol?
    private var pendingPowerSettingsSnapshot: OCRPowerSettingsSnapshot?
    private var wasRecordingBeforeSleep = false
    private var lastKnownPowerSource: PowerStateMonitor.PowerSource?
    private var lastKnownLowPowerMode: Bool?
    private var isHandlingSystemSleep = false
    private var isHandlingSystemWake = false
    private var pendingDeeplinkURLs: [URL] = []
    private var shouldShowDashboardAfterInitialization = false
    private var isActivationRevealInFlight = false
    private var isInitialized = false
    private var isTerminationFlushInProgress = false
    private var isTerminationDecisionInProgress = false
    private var bypassQuitConfirmationPromptOnce = false
    private var quitConfirmationHostWindow: NSWindow?
    private var singleInstanceLockFileDescriptor: CInt = -1
    private let settingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard
    private static let devDeeplinkEnvKey = "RETRACE_DEV_DEEPLINK_URL"
    private static let externalDashboardRevealNotification = Notification.Name("io.retrace.app.externalDashboardReveal")
    private static let quitConfirmationPreferenceKey = "quitConfirmationPreference"
    private static let canonicalBundleIdentifier = "io.retrace.app"
    private static let singleInstanceLockPath = "/tmp/io.retrace.app.instance.lock"
    nonisolated private static let watchdogSleepSuspensionSeconds: TimeInterval = 12 * 60 * 60
    nonisolated private static let watchdogWakeGracePeriodSeconds: TimeInterval = 60

    private enum QuitTerminationPreference: String {
        case ask
        case quit
        case runInBackground
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt user to move app to Applications folder if not already there
        AppMover.moveToApplicationsFolderIfNecessary()
        setupExternalDashboardRevealObserver()

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
            Log.info("[AppDelegate] App relaunched successfully", category: .app)
            UserDefaults.standard.removeObject(forKey: "isRelaunching")
        } else {
            let hasSingleInstanceLock = acquireSingleInstanceLock()
            if !hasSingleInstanceLock || isAnotherInstanceRunning() {
                Log.info("[AppDelegate] Another instance already running, activating it", category: .app)
                activateExistingInstance()
                requestImmediateTermination(skipQuitConfirmation: true)
                return
            }
        }

        // Configure app appearance
        configureAppearance()

        // Initialize the Sparkle updater for automatic updates
        UpdaterManager.shared.initialize()
        UpdaterManager.shared.checkForUpdatesOnStartup()

        // Start main thread hang detection (writes emergency diagnostics if main thread freezes)
        MainThreadHangDetector.shared.start()

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
        if !(await checkStoragePathAvailable()) {
            return // User chose to quit or we're waiting for them to reconnect
        }

        do {
            let wrapper = AppCoordinatorWrapper()
            self.coordinatorWrapper = wrapper
            try await wrapper.initialize()
            Log.info("[AppDelegate] Coordinator initialized successfully", category: .app)

            configureWatchdogAutoQuit()

            // Start the main thread watchdog to detect UI freezes
            MainThreadWatchdog.shared.start()

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

            // Setup power settings change observer
            setupPowerSettingsObserver()
            ProcessCPUMonitor.shared.start()

            Log.info("[AppDelegate] Menu bar and window controllers initialized", category: .app)

            // Mark as initialized before processing pending deeplinks
            isInitialized = true

            // Process any deeplinks that arrived before initialization completed
            var didHandleInitialDeeplink = false
            if !pendingDeeplinkURLs.isEmpty {
                Log.info("[AppDelegate] Processing \(pendingDeeplinkURLs.count) pending deeplink(s)", category: .app)
                for url in pendingDeeplinkURLs {
                    handleDeeplink(url)
                }
                pendingDeeplinkURLs.removeAll()
                didHandleInitialDeeplink = true
            }

            // Dev-only startup deeplink simulation from terminal:
            // RETRACE_DEV_DEEPLINK_URL='retrace://search?...' swift run Retrace
            if processDevDeeplinkFromEnvironment() {
                didHandleInitialDeeplink = true
            }

            if shouldShowDashboardAfterInitialization {
                requestDashboardReveal(source: "pendingExternalDashboardReveal")
                shouldShowDashboardAfterInitialization = false
            } else if !didHandleInitialDeeplink {
                // Show dashboard on first launch (only if no deeplinks)
                DashboardWindowController.shared.show()
            }

        } catch {
            Log.error("[AppDelegate] Failed to initialize: \(error)", category: .app)
        }
    }

    private func configureWatchdogAutoQuit() {
        MainThreadWatchdog.shared.setAutoQuitHandler { blockedSeconds in
            let blockedFor = String(format: "%.1f", blockedSeconds)

            let displayCount = Self.activeDisplayCount()
            if displayCount <= 0 {
                let displayStateDescription = displayCount == 0 ? "0 active displays" : "display probe failed"
                Log.warning(
                    "[Watchdog] Auto-quit suppressed: \(displayStateDescription) (darkwake/sleep transition). blocked=\(blockedFor)s",
                    category: .ui
                )
                MainThreadWatchdog.shared.suspendAutoQuit(
                    for: Self.watchdogWakeGracePeriodSeconds,
                    reason: "\(displayStateDescription) (darkwake/sleep transition)"
                )
                EmergencyDiagnostics.capture(trigger: "watchdog_auto_quit_suppressed_no_display")
                return
            }

            Log.critical("[Watchdog] Auto-quit threshold reached (\(blockedFor)s). Capturing diagnostics and attempting automatic relaunch.", category: .ui)
            EmergencyDiagnostics.capture(trigger: "watchdog_auto_quit")

            let relaunchDecision = WatchdogRelaunchGuard.evaluateAndRecord()
            guard relaunchDecision.shouldRelaunch else {
                Log.critical(
                    "[Watchdog] Auto-relaunch suppressed to prevent restart loop (\(relaunchDecision.recentCount) relaunches in last 5 minutes). Exiting without relaunch.",
                    category: .ui
                )
                Darwin.exit(0)
            }

            // Ensure we still terminate if relaunch scheduling fails unexpectedly.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3.0) {
                Log.critical("[Watchdog] Relaunch did not complete after auto-quit trigger. Force exiting.", category: .ui)
                Darwin.exit(0)
            }

            // Reuse the same restart path as Settings so watchdog quits auto-recover.
            AppRelaunch.relaunch()
        }
    }

    nonisolated private static func activeDisplayCount() -> Int {
        var displayCount: UInt32 = 0
        let result = CGGetActiveDisplayList(0, nil, &displayCount)
        guard result == .success else {
            return -1
        }
        return Int(displayCount)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running in menu bar even when window is closed
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            Log.info("[LaunchSurface] applicationShouldHandleReopen hasVisibleWindows=\(flag) state=\(launchSurfaceStateSnapshot())", category: .app)
            requestDashboardReveal(source: "applicationShouldHandleReopen")
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            let shouldReveal = shouldRevealDashboardForActivation()
            Log.info("[LaunchSurface] applicationDidBecomeActive shouldReveal=\(shouldReveal) state=\(launchSurfaceStateSnapshot())", category: .app)

            guard shouldReveal, !isActivationRevealInFlight else { return }

            isActivationRevealInFlight = true
            requestDashboardReveal(source: "applicationDidBecomeActive")
            isActivationRevealInFlight = false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminationFlushInProgress {
            return .terminateNow
        }

        if isTerminationDecisionInProgress {
            return .terminateLater
        }

        switch terminationPreferenceForCurrentRequest() {
        case .quit:
            beginTerminationFlush()
            return .terminateLater
        case .runInBackground:
            runInBackgroundInsteadOfQuitting()
            return .terminateCancel
        case .ask:
            break
        }

        isTerminationDecisionInProgress = true
        presentQuitConfirmationAlert()

        return .terminateLater
    }

    private func requestImmediateTermination(skipQuitConfirmation: Bool) {
        if skipQuitConfirmation {
            bypassQuitConfirmationPromptOnce = true
        }
        NSApp.terminate(nil)
    }

    private func terminationPreferenceForCurrentRequest() -> QuitTerminationPreference {
        if bypassQuitConfirmationPromptOnce {
            bypassQuitConfirmationPromptOnce = false
            return .quit
        }

        guard let rawValue = settingsStore.string(forKey: Self.quitConfirmationPreferenceKey),
              let storedPreference = QuitTerminationPreference(rawValue: rawValue) else {
            return .ask
        }

        return storedPreference
    }

    private func beginTerminationFlush() {
        guard !isTerminationFlushInProgress else { return }

        isTerminationFlushInProgress = true

        // Save timeline state (filters, search) for cross-session persistence.
        TimelineWindowController.shared.saveStateForTermination()

        // Flush active timeline metrics asynchronously with a bounded timeout.
        // Use terminateLater to avoid blocking the main thread during shutdown.
        Task { @MainActor [weak self] in
            _ = await TimelineWindowController.shared.forceRecordSessionMetrics(timeoutMs: 350)
            self?.isTerminationFlushInProgress = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    private func presentQuitConfirmationAlert() {
        Log.info("[AppDelegate] Presenting standard quit confirmation alert", category: .app)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Are you sure you want to quit Retrace?"
        alert.informativeText = "Quitting Retrace will stop any active capture and end ongoing recording. You can keep Retrace running in the background without interruption."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.addButton(withTitle: "Quit Retrace")
        alert.addButton(withTitle: "Run Retrace in Background")
        alert.addButton(withTitle: "Cancel")
        styleQuitAlertPrimaryButton(alert, context: "initial")

        let anchorWindow = currentTerminationAnchorWindow() ?? makeQuitConfirmationHostWindow()
        scheduleQuitButtonStyleEnforcement(for: alert, context: "sheet")
        alert.beginSheetModal(for: anchorWindow) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.handleQuitAlertResponse(response, dontAskAgain: alert.suppressionButton?.state == .on)
                self.dismissQuitConfirmationHostWindowIfNeeded(anchorWindow)
            }
        }
    }

    private func handleQuitAlertResponse(_ response: NSApplication.ModalResponse, dontAskAgain: Bool) {
        let result: QuitConfirmationResult
        switch response {
        case .alertFirstButtonReturn:
            result = QuitConfirmationResult(action: .quit, dontAskAgain: dontAskAgain)
        case .alertSecondButtonReturn:
            result = QuitConfirmationResult(action: .runInBackground, dontAskAgain: dontAskAgain)
        default:
            result = QuitConfirmationResult(action: .cancel, dontAskAgain: dontAskAgain)
        }
        handleQuitConfirmationResult(result)
    }

    private func currentTerminationAnchorWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow {
            return keyWindow
        }
        return NSApp.mainWindow
    }

    private func makeQuitConfirmationHostWindow() -> NSWindow {
        if let window = quitConfirmationHostWindow {
            return window
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Retrace"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        quitConfirmationHostWindow = window
        return window
    }

    private func dismissQuitConfirmationHostWindowIfNeeded(_ window: NSWindow) {
        guard quitConfirmationHostWindow === window else { return }
        window.orderOut(nil)
        window.close()
        quitConfirmationHostWindow = nil
    }

    private func scheduleQuitButtonStyleEnforcement(for alert: NSAlert, context: String) {
        // AppKit may restyle alert buttons after presentation; re-apply a few times.
        let delays: [TimeInterval] = [0.0, 0.04, 0.10, 0.20]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.styleQuitAlertPrimaryButton(alert, context: "\(context)-t+\(String(format: "%.2f", delay))")
            }
        }
    }

    private func styleQuitAlertPrimaryButton(_ alert: NSAlert, context: String) {
        guard let quitButton = alert.buttons.first else { return }

        let retraceQuitBlue = NSColor(
            calibratedRed: 11.0 / 255.0,
            green: 51.0 / 255.0,
            blue: 108.0 / 255.0,
            alpha: 1.0
        )

        quitButton.appearance = NSAppearance(named: .darkAqua)
        quitButton.bezelColor = retraceQuitBlue
        quitButton.contentTintColor = .white
        quitButton.attributedTitle = NSAttributedString(
            string: quitButton.title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: quitButton.font?.pointSize ?? 15, weight: .semibold)
            ]
        )
        quitButton.needsDisplay = true

        if let appliedColor = quitButton.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            Log.debug("[QUIT_ALERT] Applied style context=\(context) fg=\(appliedColor) bezel=\(retraceQuitBlue)", category: .ui)
        } else {
            Log.warning("[QUIT_ALERT] Failed to read attributed foreground color context=\(context)", category: .ui)
        }
    }

    private func handleQuitConfirmationResult(_ result: QuitConfirmationResult) {
        isTerminationDecisionInProgress = false

        if result.dontAskAgain {
            switch result.action {
            case .quit:
                settingsStore.set(QuitTerminationPreference.quit.rawValue, forKey: Self.quitConfirmationPreferenceKey)
            case .runInBackground:
                settingsStore.set(QuitTerminationPreference.runInBackground.rawValue, forKey: Self.quitConfirmationPreferenceKey)
            case .cancel:
                break
            }
        }

        switch result.action {
        case .quit:
            Log.info("[AppDelegate] User confirmed quit", category: .app)
            beginTerminationFlush()
        case .runInBackground:
            Log.info("[AppDelegate] User chose to keep Retrace running in background", category: .app)
            runInBackgroundInsteadOfQuitting()
            NSApp.reply(toApplicationShouldTerminate: false)
        case .cancel:
            Log.info("[AppDelegate] User cancelled quit", category: .app)
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    private func runInBackgroundInsteadOfQuitting() {
        TimelineWindowController.shared.hide()
        DashboardWindowController.shared.hide()
        NSApp.hide(nil)
    }

    // MARK: - Storage Path Validation

    /// Pre-flight check to ensure custom storage path is accessible
    /// Returns true if app should continue, false if user chose to quit
    @MainActor
    private func checkStoragePathAvailable() async -> Bool {
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
            if let newPath = await browseForDatabaseFolder(startingAt: parentDir) {
                defaults.set(newPath, forKey: "customRetraceDBLocation")
                defaults.synchronize()
                Log.info("[AppDelegate] User selected new storage location: \(newPath)", category: .app)
                return true
            } else {
                // User cancelled - show dialog again
                return await checkStoragePathAvailable()
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
            requestImmediateTermination(skipQuitConfirmation: true)
            return false
        }
    }

    /// Shows folder picker for selecting database location
    /// Returns the selected path if valid, nil if cancelled or invalid
    @MainActor
    private func browseForDatabaseFolder(startingAt directory: String?) async -> String? {
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
        let validationResult = await validateRetraceFolderSelection(at: selectedPath)

        switch validationResult {
        case .valid:
            return selectedPath

        case .missingChunks:
            let alert = NSAlert()
            alert.messageText = "Missing Chunks Folder"
            alert.informativeText = "The selected folder has retrace.db but is missing the 'chunks' folder with video files.\n\nRetrace may not be able to load existing video frames.\n\nDo you want to continue anyway?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue Anyway")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() != .alertFirstButtonReturn {
                // User cancelled - let them pick again
                return await browseForDatabaseFolder(startingAt: directory)
            }
            return selectedPath

        case .invalidFolder:
            let alert = NSAlert()
            alert.messageText = "Invalid Folder Selection"
            alert.informativeText = "The selected folder contains other files but is not a valid Retrace database folder.\n\nPlease select either:\n• An existing Retrace folder (with retrace.db)\n• An empty folder for a new database"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()

            // Let them pick again
            return await browseForDatabaseFolder(startingAt: directory)

        case .invalidDatabase(let error):
            let alert = NSAlert()
            alert.messageText = "Invalid Retrace Database"
            alert.informativeText = error
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()

            // Let them pick again
            return await browseForDatabaseFolder(startingAt: directory)
        }
    }

    private enum RetraceFolderValidationResult: Sendable {
        case valid
        case missingChunks
        case invalidFolder
        case invalidDatabase(error: String)
    }

    private func validateRetraceFolderSelection(at selectedPath: String) async -> RetraceFolderValidationResult {
        await Task.detached(priority: .userInitiated) {
            Self.validateRetraceFolderSelectionSync(at: selectedPath)
        }.value
    }

    nonisolated private static func validateRetraceFolderSelectionSync(at selectedPath: String) -> RetraceFolderValidationResult {
        let fm = FileManager.default
        let dbPath = "\(selectedPath)/retrace.db"
        let chunksPath = "\(selectedPath)/chunks"
        let hasDatabase = fm.fileExists(atPath: dbPath)
        let hasChunks = fm.fileExists(atPath: chunksPath)

        if hasDatabase {
            let verification = verifyRetraceDatabase(at: dbPath)
            guard verification.isValid else {
                return .invalidDatabase(error: verification.error ?? "The selected folder contains a retrace.db file that is not a valid Retrace database.")
            }
            return hasChunks ? .valid : .missingChunks
        }

        let contents = (try? fm.contentsOfDirectory(atPath: selectedPath)) ?? []
        let visibleContents = contents.filter { !$0.hasPrefix(".") }
        return visibleContents.isEmpty ? .valid : .invalidFolder
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

    // MARK: - Sleep/Wake Handling

    private func setupSleepWakeObservers() {
        guard sleepWakeObservers.isEmpty else {
            return
        }

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

        let screensSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleScreensSleep()
            }
        }
        sleepWakeObservers.append(screensSleepObserver)

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

        let screensWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleScreensWake()
            }
        }
        sleepWakeObservers.append(screensWakeObserver)

        // Power source change detection - coalesced with sleep/wake observers
        // NSWorkspace doesn't have a direct power change notification, but we can:
        // 1. Check power state on wake (covers most plug/unplug during sleep)
        // 2. Use IOKit's power source notification for real-time detection
        setupPowerSourceMonitoring()
        setupLowPowerModeObserver()

        Log.info("[AppDelegate] Sleep/wake observers registered", category: .app)
    }

    /// Setup IOKit-based power source monitoring for AC/battery changes
    private func setupPowerSourceMonitoring() {
        guard powerSourceRunLoopSource == nil else {
            return
        }

        // Create a run loop source for power source notifications
        let context = Unmanaged.passUnretained(self).toOpaque()

        if let runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                await delegate.handlePowerSourceChange()
            }
        }, context)?.takeRetainedValue() {
            powerSourceRunLoopSource = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            let initialSource = PowerStateMonitor.shared.getCurrentPowerSource()
            lastKnownPowerSource = initialSource
            Log.info("[AppDelegate] Power source monitoring registered (initial: \(initialSource))", category: .app)
        }
    }

    private func setupLowPowerModeObserver() {
        guard lowPowerModeObserver == nil else {
            return
        }

        lastKnownLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        lowPowerModeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleLowPowerModeChange()
            }
        }
    }

    @MainActor
    private func handlePowerSourceChange() async {
        guard coordinatorWrapper != nil else { return }

        let newSource = PowerStateMonitor.shared.getCurrentPowerSource()
        if let lastKnownPowerSource, lastKnownPowerSource == newSource {
            return
        }
        lastKnownPowerSource = newSource

        Log.info("[AppDelegate] Power source changed to: \(newSource)", category: .app)
        schedulePowerSettingsApply()

        // Notify UI to update power status display
        NotificationCenter.default.post(name: NSNotification.Name("PowerSourceDidChange"), object: newSource)
    }

    @MainActor
    private func handleLowPowerModeChange() async {
        guard coordinatorWrapper != nil else { return }

        let isLowPowerEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let lastKnownLowPowerMode, lastKnownLowPowerMode == isLowPowerEnabled {
            return
        }
        lastKnownLowPowerMode = isLowPowerEnabled

        Log.info("[AppDelegate] Low Power Mode changed: \(isLowPowerEnabled)", category: .app)
        schedulePowerSettingsApply()
    }

    @MainActor
    private func schedulePowerSettingsApply(snapshot: OCRPowerSettingsSnapshot? = nil) {
        if let snapshot {
            pendingPowerSettingsSnapshot = snapshot
        }

        powerSettingsApplyTask?.cancel()
        powerSettingsApplyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .nanoseconds(Int64(250_000_000)), clock: .continuous)
            } catch {
                return
            }

            guard let self, let wrapper = self.coordinatorWrapper else { return }
            if let snapshot = self.pendingPowerSettingsSnapshot {
                await wrapper.coordinator.applyPowerSettings(snapshot: snapshot)
                self.pendingPowerSettingsSnapshot = nil
            } else {
                await wrapper.coordinator.applyPowerSettings()
            }
            self.powerSettingsApplyTask = nil
        }
    }

    /// Setup observer for power settings changes from Settings UI
    private func setupPowerSettingsObserver() {
        guard powerSettingsObserver == nil else {
            return
        }

        powerSettingsObserver = NotificationCenter.default.addObserver(
            forName: OCRPowerSettingsNotification.didChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard self.coordinatorWrapper != nil else { return }
                Log.info("[AppDelegate] Power settings changed, applying...", category: .app)

                if let snapshot = notification.object as? OCRPowerSettingsSnapshot {
                    self.schedulePowerSettingsApply(snapshot: snapshot)
                } else {
                    self.schedulePowerSettingsApply()
                }
            }
        }
    }

    @MainActor
    private func handleSystemSleep() async {
        MainThreadWatchdog.shared.suspendAutoQuit(
            for: Self.watchdogSleepSuspensionSeconds,
            reason: "system will sleep"
        )

        guard let wrapper = coordinatorWrapper else { return }
        guard !isHandlingSystemSleep else { return }
        isHandlingSystemSleep = true
        defer { isHandlingSystemSleep = false }

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
        MainThreadWatchdog.shared.resumeAutoQuit(
            after: Self.watchdogWakeGracePeriodSeconds,
            reason: "system did wake"
        )

        guard let wrapper = coordinatorWrapper else { return }
        guard !isHandlingSystemWake else { return }
        guard wasRecordingBeforeSleep else { return }
        isHandlingSystemWake = true
        wasRecordingBeforeSleep = false
        defer { isHandlingSystemWake = false }

        if await wrapper.coordinator.isCapturing() {
            await wrapper.refreshStatus()
            return
        }

        Log.info("[AppDelegate] System woke from sleep - resuming pipeline", category: .app)
        do {
            try await wrapper.coordinator.startPipeline()
            await wrapper.refreshStatus()
        } catch {
            Log.error("[AppDelegate] Failed to resume pipeline on wake: \(error)", category: .app)
        }
    }

    @MainActor
    private func handleScreensSleep() async {
        MainThreadWatchdog.shared.suspendAutoQuit(
            for: Self.watchdogSleepSuspensionSeconds,
            reason: "screens did sleep"
        )
    }

    @MainActor
    private func handleScreensWake() async {
        MainThreadWatchdog.shared.resumeAutoQuit(
            after: Self.watchdogWakeGracePeriodSeconds,
            reason: "screens did wake"
        )
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

    private func singleInstanceBundleIdentifier() -> String {
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            return bundleID
        }

        if let infoBundleID = Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String,
           !infoBundleID.isEmpty {
            return infoBundleID
        }

        Log.warning(
            "[AppDelegate] Missing runtime bundle identifier; using canonical identifier \(Self.canonicalBundleIdentifier) for single-instance coordination",
            category: .app
        )
        return Self.canonicalBundleIdentifier
    }

    private func acquireSingleInstanceLock() -> Bool {
        if singleInstanceLockFileDescriptor >= 0 {
            return true
        }

        let lockPath = Self.singleInstanceLockPath
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if fd == -1 {
            let openError = errno
            Log.error(
                "[AppDelegate] Failed to open single-instance lock file at \(lockPath): \(String(cString: strerror(openError)))",
                category: .app
            )
            return true
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            close(fd)

            if lockError == EWOULDBLOCK {
                return false
            }

            Log.error(
                "[AppDelegate] Failed to acquire single-instance lock at \(lockPath): \(String(cString: strerror(lockError)))",
                category: .app
            )
            return true
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        let pidString = "\(currentPID)\n"
        pidString.withCString { pidCString in
            _ = write(fd, pidCString, strlen(pidCString))
        }

        singleInstanceLockFileDescriptor = fd
        return true
    }

    private func releaseSingleInstanceLock() {
        guard singleInstanceLockFileDescriptor >= 0 else { return }

        _ = flock(singleInstanceLockFileDescriptor, LOCK_UN)
        close(singleInstanceLockFileDescriptor)
        singleInstanceLockFileDescriptor = -1
    }

    private func lockFileInstancePID() -> pid_t? {
        guard let data = FileManager.default.contents(atPath: Self.singleInstanceLockPath),
              let lockContents = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let lockPID = Int32(lockContents) else {
            return nil
        }
        return pid_t(lockPID)
    }

    private func postExternalDashboardRevealNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.externalDashboardRevealNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        Log.info("[LaunchSurface] Posted external dashboard reveal notification", category: .app)
    }

    private func isAnotherInstanceRunning() -> Bool {
        let retraceBundleID = singleInstanceBundleIdentifier()
        let runningApps = NSWorkspace.shared.runningApplications
        let myPID = ProcessInfo.processInfo.processIdentifier

        return runningApps.contains { app in
            app.processIdentifier != myPID && app.bundleIdentifier == retraceBundleID
        }
    }

    private func activateExistingInstance() {
        let retraceBundleID = singleInstanceBundleIdentifier()
        let myPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications

        if let existingApp = runningApps.first(where: { app in
            app.bundleIdentifier == retraceBundleID &&
                app.processIdentifier != myPID
        }) {
            Log.info("[LaunchSurface] Forwarding duplicate launch to existing instance pid=\(existingApp.processIdentifier) hidden=\(existingApp.isHidden) active=\(existingApp.isActive)", category: .app)
            existingApp.activate(options: .activateIgnoringOtherApps)
            postExternalDashboardRevealNotification()
            return
        }

        if let lockPID = lockFileInstancePID(),
           lockPID != myPID,
           let lockedApp = NSRunningApplication(processIdentifier: lockPID) {
            Log.info("[LaunchSurface] Forwarding duplicate launch to locked instance pid=\(lockPID) hidden=\(lockedApp.isHidden) active=\(lockedApp.isActive)", category: .app)
            lockedApp.activate(options: .activateIgnoringOtherApps)
            postExternalDashboardRevealNotification()
        } else {
            Log.warning("[LaunchSurface] Duplicate launch detected but no existing instance was found", category: .app)
        }
    }

    @MainActor
    private func requestDashboardReveal(source: String) {
        if isInitialized {
            Log.info("[LaunchSurface] requestDashboardReveal source=\(source) before state=\(launchSurfaceStateSnapshot())", category: .app)

            let wasHidden = NSApp.isHidden
            if wasHidden {
                Log.info("[LaunchSurface] Unhiding app before reveal source=\(source)", category: .app)
                NSApp.unhide(nil)
            }

            let dashboard = DashboardWindowController.shared
            if dashboard.isVisible {
                dashboard.bringToFront()
                Log.info("[LaunchSurface] Brought dashboard to front source=\(source) appWasHidden=\(wasHidden) after state=\(launchSurfaceStateSnapshot())", category: .app)
            } else {
                dashboard.show()
                Log.info("[LaunchSurface] Called dashboard.show source=\(source) appWasHidden=\(wasHidden) after state=\(launchSurfaceStateSnapshot())", category: .app)
            }
        } else {
            shouldShowDashboardAfterInitialization = true
            Log.info("[LaunchSurface] Queued dashboard reveal until initialization source=\(source) state=\(launchSurfaceStateSnapshot())", category: .app)
        }
    }

    private func setupExternalDashboardRevealObserver() {
        Log.info("[LaunchSurface] Registering external dashboard reveal observer", category: .app)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalDashboardRevealNotification(_:)),
            name: Self.externalDashboardRevealNotification,
            object: nil
        )
    }

    @objc private func handleExternalDashboardRevealNotification(_ notification: Notification) {
        Task { @MainActor in
            Log.info("[LaunchSurface] Received external dashboard reveal notification state=\(launchSurfaceStateSnapshot())", category: .app)
            requestDashboardReveal(source: "externalDashboardRevealNotification")
        }
    }

    @MainActor
    private func launchSurfaceStateSnapshot() -> String {
        let dashboard = DashboardWindowController.shared
        let window = dashboard.window
        let windowVisible = window?.isVisible ?? false
        let windowKey = window?.isKeyWindow ?? false
        let windowMini = window?.isMiniaturized ?? false
        let windowMain = window?.isMainWindow ?? false

        return "initialized=\(isInitialized) appHidden=\(NSApp.isHidden) appActive=\(NSApp.isActive) dashboardVisible=\(dashboard.isVisible) windowVisible=\(windowVisible) windowKey=\(windowKey) windowMain=\(windowMain) windowMini=\(windowMini)"
    }

    @MainActor
    private func shouldRevealDashboardForActivation() -> Bool {
        guard isInitialized else { return false }
        guard !isTerminationDecisionInProgress else { return false }
        guard !isTerminationFlushInProgress else { return false }
        guard !TimelineWindowController.shared.isVisible else { return false }
        guard !DashboardWindowController.shared.isVisible else { return false }
        guard !PauseReminderWindowController.shared.isVisible else { return false }

        let hasVisibleForegroundWindow = NSApp.windows.contains { window in
            window.level.rawValue == 0 && window.isVisible
        }
        return !hasVisibleForegroundWindow
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseSingleInstanceLock()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers {
            workspaceCenter.removeObserver(observer)
        }
        sleepWakeObservers.removeAll()
        powerSettingsApplyTask?.cancel()
        powerSettingsApplyTask = nil
        pendingPowerSettingsSnapshot = nil
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
            self.powerSourceRunLoopSource = nil
        }
        if let powerSettingsObserver {
            NotificationCenter.default.removeObserver(powerSettingsObserver)
            self.powerSettingsObserver = nil
        }
        if let lowPowerModeObserver {
            NotificationCenter.default.removeObserver(lowPowerModeObserver)
            self.lowPowerModeObserver = nil
        }
        DistributedNotificationCenter.default().removeObserver(self)
        ProcessCPUMonitor.shared.stop()

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
        guard let route = DeeplinkHandler.route(for: url) else {
            return
        }

        switch route {
        case let .timeline(timestamp):
            Log.info("[AppDelegate] Opening timeline deeplink at timestamp: \(String(describing: timestamp))", category: .app)
            if let timestamp {
                TimelineWindowController.shared.showAndNavigate(to: timestamp)
            } else {
                TimelineWindowController.shared.show()
            }

        case let .search(query, timestamp, appBundleID):
            Log.info("[AppDelegate] Opening search deeplink: query=\(query ?? "nil"), timestamp=\(String(describing: timestamp)), app=\(appBundleID ?? "nil")", category: .app)
            TimelineWindowController.shared.showSearch(
                query: query,
                timestamp: timestamp,
                appBundleID: appBundleID,
                source: "AppDelegate.openURLs"
            )
        }
    }

    /// Process a dev deeplink URL from environment for local interactive testing.
    /// Example:
    /// RETRACE_DEV_DEEPLINK_URL='retrace://search?q=test&app=com.google.Chrome&t=1704067200000' swift run Retrace
    @MainActor
    private func processDevDeeplinkFromEnvironment() -> Bool {
        guard let rawValue = ProcessInfo.processInfo.environment[Self.devDeeplinkEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return false
        }

        guard let url = URL(string: rawValue) else {
            Log.warning("[AppDelegate] Ignoring invalid \(Self.devDeeplinkEnvKey): \(rawValue)", category: .app)
            return false
        }

        Log.info("[AppDelegate] Processing dev deeplink from env: \(url)", category: .app)
        handleDeeplink(url)
        return true
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

private enum QuitConfirmationAction {
    case quit
    case runInBackground
    case cancel
}

private struct QuitConfirmationResult {
    let action: QuitConfirmationAction
    let dontAskAgain: Bool
}

// MARK: - URL Handling

extension RetraceApp {
    /// Handle URL scheme: retrace://
    func onOpenURL(_ url: URL) {
        Log.info("[RetraceApp] Handling URL: \(url)", category: .app)
        // URL handling is done in ContentView via .onOpenURL
    }
}
