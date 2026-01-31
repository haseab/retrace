import SwiftUI
import App
import Shared

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
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Open Timeline") {
                TimelineWindowController.shared.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

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
                DashboardWindowController.shared.showSettings()
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
            .keyboardShortcut("r", modifiers: [.command, .shift])
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

        // Check if another instance is already running
        if isAnotherInstanceRunning() {
            Log.info("[AppDelegate] Another instance of Retrace is already running. Activating existing instance...", category: .app)
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
        let retraceApps = runningApps.filter { app in
            // Check for Retrace by bundle identifier or name
            return (app.bundleIdentifier?.contains("retrace") == true ||
                    app.localizedName?.contains("Retrace") == true) &&
                   app.processIdentifier != ProcessInfo.processInfo.processIdentifier
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
