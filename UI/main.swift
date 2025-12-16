import SwiftUI
import App

/// Main app entry point
@main
struct RetraceApp: App {

    // MARK: - Properties

    @StateObject private var coordinatorWrapper = AppCoordinatorWrapper()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
                NotificationCenter.default.post(name: .openTimeline, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("Search") {
                NotificationCenter.default.post(name: .openSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)

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

            // Setup menu bar icon
            await MainActor.run {
                let menuBar = MenuBarManager(coordinator: coordinatorWrapper.coordinator)
                menuBar.setup()

                // Store in AppDelegate to keep it alive
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.menuBarManager = menuBar
                }

                print("[RetraceApp] Menu bar icon initialized")
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
        // Request permissions on first launch
        requestPermissions()

        // Configure app appearance
        configureAppearance()

        // Menu bar will be initialized from initializeApp after coordinator is ready
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running in menu bar even when window is closed
        return false
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
        // Force dark mode for now (can be made configurable later)
        NSApp.appearance = NSAppearance(named: .darkAqua)
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
