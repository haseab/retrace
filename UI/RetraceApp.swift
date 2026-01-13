import SwiftUI
import App

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
                .task {
                    await initializeApp()
                }
        }
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
            .keyboardShortcut(.space, modifiers: [.option, .shift])

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
            print("[RetraceApp] Initialized successfully")

            // Setup menu bar icon and timeline window controller
            await MainActor.run {
                let menuBar = MenuBarManager(
                    coordinator: coordinatorWrapper.coordinator,
                    onboardingManager: coordinatorWrapper.coordinator.onboardingManager
                )
                menuBar.setup()

                // Configure the timeline window controller
                TimelineWindowController.shared.configure(coordinator: coordinatorWrapper.coordinator)

                // Store in AppDelegate to keep it alive
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.menuBarManager = menuBar
                }

                print("[RetraceApp] Menu bar icon and timeline controller initialized")
            }

            // Optionally start capture immediately
            // try await coordinatorWrapper.startPipeline()
        } catch {
            print("[RetraceApp] Failed to initialize: \(error)")
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CRITICAL FIX: Ensure bundle identifier is set
        // When running from Xcode/SPM, the bundle ID might not be set correctly
        if Bundle.main.bundleIdentifier == nil {
            // Set activation policy to regular (shows in Dock and can be activated)
            // This is required when running without a proper bundle ID
            NSApp.setActivationPolicy(.regular)
        }

        // Check if another instance is already running
        if isAnotherInstanceRunning() {
            print("[AppDelegate] Another instance of Retrace is already running. Activating existing instance...")
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        }

        // Configure app appearance
        configureAppearance()

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
        print("[AppDelegate] Application terminating")
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
        // Read theme preference from UserDefaults
        let themeRaw = UserDefaults.standard.string(forKey: "theme") ?? "Auto"
        let theme = ThemePreference(rawValue: themeRaw) ?? .auto

        switch theme {
        case .auto:
            NSApp.appearance = nil // Use system setting
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - URL Handling

extension RetraceApp {
    /// Handle URL scheme: retrace://
    func onOpenURL(_ url: URL) {
        print("[RetraceApp] Handling URL: \(url)")
        // URL handling is done in ContentView via .onOpenURL
    }
}
