import SwiftUI
import App
import Shared

/// Main app entry point
@main
struct RetraceApp: App {

    // MARK: - Properties

    @StateObject private var coordinatorWrapper = AppCoordinatorWrapper()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Initialization

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinatorWrapper.coordinator)
                .environmentObject(coordinatorWrapper)
                .task {
                    await initializeApp()
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultPosition(.center)
        .commands {
            appCommands
        }
    }

    // MARK: - Commands

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            // Remove "New Window" since we're a single-window app
        }

        CommandMenu("View") {
            Button("Dashboard") {
                NotificationCenter.default.post(name: .openDashboard, object: nil)
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
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Recording") {
            Button("Start/Stop Recording") {
                Task {
                    try? await coordinatorWrapper.startPipeline()
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }

    // MARK: - Initialization

    private func initializeApp() async {
        do {
            try await coordinatorWrapper.initialize()
            Log.info("[RetraceApp] Initialized successfully", category: .app)

            // Setup menu bar icon and timeline window controller
            await MainActor.run {
                let menuBar = MenuBarManager(
                    coordinator: coordinatorWrapper.coordinator,
                    onboardingManager: coordinatorWrapper.coordinator.onboardingManager
                )
                menuBar.setup()

                // Configure the timeline window controller
                TimelineWindowController.shared.configure(coordinator: coordinatorWrapper.coordinator)

                // Configure the pause reminder window controller
                PauseReminderWindowController.shared.configure(coordinator: coordinatorWrapper.coordinator)

                // Store in AppDelegate to keep it alive
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.menuBarManager = menuBar
                }

                Log.info("[RetraceApp] Menu bar icon and timeline controller initialized", category: .app)
            }
            // Note: Auto-start recording is handled in AppCoordinatorWrapper.initialize()
        } catch {
            Log.error("[RetraceApp] Failed to initialize: \(error)", category: .app)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt user to move app to Applications folder if not already there
        AppMover.moveToApplicationsFolderIfNecessary()

        // CRITICAL FIX: Ensure bundle identifier is set
        // When running from Xcode/SPM, the bundle ID might not be set correctly
        if Bundle.main.bundleIdentifier == nil {
            // Set activation policy to regular (shows in Dock and can be activated)
            // This is required when running without a proper bundle ID
            NSApp.setActivationPolicy(.regular)
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

        // Activate the app and bring window to front
        // Use a slight delay to ensure window is created first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Use NSRunningApplication for most reliable activation
            let currentApp = NSRunningApplication.current
            currentApp.activate(options: .activateIgnoringOtherApps)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Menu bar will be initialized from initializeApp after coordinator is ready
        // Note: Permissions are now handled in the onboarding flow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running in menu bar even when window is closed
        return false
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
        // Cleanup
        Log.info("[AppDelegate] Application terminating", category: .app)
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
