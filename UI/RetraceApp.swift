import SwiftUI
import AppKit
import App
import Shared

/// Main app entry point
/// This is a menu bar app - no automatic window is created on launch
@main
struct RetraceApp: App {

    // MARK: - Properties

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Body

    var body: some Scene {
        // Empty body - no windows created automatically
        // All windows (dashboard, timeline, settings) are created on-demand
        // via their respective window controllers
        Settings {
            // Empty settings - we handle settings in DashboardWindowController
            EmptyView()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var menuBarManager: MenuBarManager?
    private var coordinatorWrapper: AppCoordinatorWrapper?

    /// URL that was used to launch the app (for deeplink handling)
    static var launchURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register for Apple Events to catch deeplinks before app finishes launching
        // This is called BEFORE applicationDidFinishLaunching
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt user to move app to Applications folder if not already there
        AppMover.moveToApplicationsFolderIfNecessary()

        // Set activation policy to accessory (menu bar only, no dock icon)
        // This is the standard pattern for LSUIElement apps
        NSApp.setActivationPolicy(.accessory)

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

        // Initialize the app (coordinator, menu bar, window controllers)
        initializeApp()
    }

    // MARK: - App Initialization

    private func initializeApp() {
        Task { @MainActor in
            do {
                // Create and initialize coordinator
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

                // Configure window controllers
                DashboardWindowController.shared.configure(coordinator: wrapper.coordinator)
                TimelineWindowController.shared.configure(coordinator: wrapper.coordinator)
                PauseReminderWindowController.shared.configure(coordinator: wrapper.coordinator)

                Log.info("[AppDelegate] Menu bar and window controllers initialized", category: .app)

                // Handle launch URL if app was opened via deeplink
                if let launchURL = AppDelegate.launchURL {
                    AppDelegate.launchURL = nil
                    handleDeeplink(launchURL)
                } else {
                    // Normal launch - show dashboard window
                    // Use a slight delay to ensure window setup is complete
                    DashboardWindowController.shared.show()
                }
            } catch {
                Log.error("[AppDelegate] Failed to initialize: \(error)", category: .app)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running in menu bar even when window is closed
        return false
    }

    // MARK: - URL Handling

    /// Handle Apple Event for URL (called before app finishes launching when app is launched via deeplink)
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }

        Log.info("[AppDelegate] Received Apple Event URL: \(url)", category: .app)

        // If coordinator is not yet initialized, store for later
        // This catches URLs that come in during app launch
        if coordinatorWrapper == nil {
            AppDelegate.launchURL = url
            return
        }

        handleDeeplink(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Handle deeplink URLs (called when app is already running)
        guard let url = urls.first else { return }

        Log.info("[AppDelegate] Received URL via application(_:open:): \(url)", category: .app)

        // If coordinator is not yet initialized, store for later
        if coordinatorWrapper == nil {
            AppDelegate.launchURL = url
            return
        }

        handleDeeplink(url)
    }

    private func handleDeeplink(_ url: URL) {
        Log.info("[AppDelegate] Handling deeplink: \(url)", category: .app)

        guard url.scheme == "retrace" else { return }

        let host = url.host?.lowercased() ?? ""
        let queryParams = url.queryParameters

        Task { @MainActor in
            switch host {
            case "timeline":
                // Hide dashboard first to prevent it from being brought to front
                DashboardWindowController.shared.hide()

                // Parse timestamp if provided (format: t=unix_ms)
                if let timestampStr = queryParams["t"],
                   let timestampMs = Int64(timestampStr) {
                    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
                    Log.info("[AppDelegate] Opening timeline at date: \(date)", category: .app)
                    TimelineWindowController.shared.showAndNavigate(to: date)
                } else {
                    // No timestamp - just open timeline
                    TimelineWindowController.shared.show()
                }

            case "search":
                // Hide dashboard first to prevent it from being brought to front
                DashboardWindowController.shared.hide()

                // Parse timestamp if provided
                if let timestampStr = queryParams["t"],
                   let timestampMs = Int64(timestampStr) {
                    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
                    TimelineWindowController.shared.showAndNavigate(to: date)
                } else {
                    TimelineWindowController.shared.show()
                }

            case "dashboard":
                // Open dashboard
                DashboardWindowController.shared.show()

            case "settings":
                // Open settings (via dashboard)
                DashboardWindowController.shared.showSettings()

            default:
                // Unknown route - open dashboard
                DashboardWindowController.shared.show()
            }
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
