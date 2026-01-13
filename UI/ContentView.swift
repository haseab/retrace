import SwiftUI
import App

/// Root content view with navigation between main views
public struct ContentView: View {

    // MARK: - Properties

    @State private var selectedView: MainView = .dashboard
    @State private var showOnboarding: Bool? = nil  // nil = loading, true = show onboarding, false = show main app
    @State private var showFeedbackSheet = false
    @StateObject private var deeplinkHandler = DeeplinkHandler()
    @StateObject private var menuBarManager: MenuBarManager

    private let coordinator: AppCoordinator

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _menuBarManager = StateObject(wrappedValue: MenuBarManager(
            coordinator: coordinator,
            onboardingManager: coordinator.onboardingManager
        ))
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            if let showOnboarding = showOnboarding {
                if showOnboarding {
                    // Show onboarding flow
                    OnboardingView(coordinator: coordinator) {
                        withAnimation {
                            self.showOnboarding = false
                            // Sync menu bar recording status after onboarding completes
                            menuBarManager.syncWithCoordinator()
                        }
                    }
                } else {
                    // Main content based on selected view
                    // Note: Timeline and Search are now fullscreen overlays, not tabs
                    Group {
                        switch selectedView {
                        case .dashboard:
                            DashboardView(coordinator: coordinator)

                        case .settings:
                            SettingsView()
                        }
                    }
                }
            } else {
                // Loading state - show nothing or a loading indicator
                Color.retraceBackground
                    .ignoresSafeArea()
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .task {
            // Check onboarding status FIRST before anything else
            // This prevents flicker by determining what to show before rendering
            await checkOnboarding()
        }
        .onAppear {
            // Delay activation to ensure window is fully loaded
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Activate app
                let currentApp = NSRunningApplication.current
                currentApp.activate(options: .activateIgnoringOtherApps)
                NSApp.activate(ignoringOtherApps: true)

                // Bring main window to front
                for window in NSApp.windows {
                    // Skip menu bar windows (level > 0 means floating/status bar)
                    guard window.level.rawValue == 0 else { continue }

                    // Set window properties
                    window.level = .normal
                    window.collectionBehavior = [.managed, .participatesInCycle]

                    // Make key and order front
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }

            menuBarManager.setup()
            setupNotifications()
        }
        .onOpenURL { url in
            deeplinkHandler.handle(url)
        }
        .onChange(of: deeplinkHandler.activeRoute) { route in
            handleDeeplink(route)
        }
        .sheet(isPresented: $showFeedbackSheet) {
            FeedbackFormView()
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        // Note: Timeline and Search notifications are now handled by MenuBarManager
        // They open the fullscreen overlay instead of switching tabs

        NotificationCenter.default.addObserver(
            forName: .openDashboard,
            object: nil,
            queue: .main
        ) { _ in
            // Toggle dashboard visibility
            let mainWindow = NSApp.windows.first { window in
                window.level.rawValue == 0 && window.isVisible
            }

            if let window = mainWindow, window.isKeyWindow {
                // Window is already visible and focused - hide it
                window.orderOut(nil)
            } else {
                // Window is hidden or not focused - show and activate
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.level.rawValue == 0 {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .openSettings,
            object: nil,
            queue: .main
        ) { _ in
            selectedView = .settings
            bringWindowToFront()
        }

        NotificationCenter.default.addObserver(
            forName: .openFeedback,
            object: nil,
            queue: .main
        ) { _ in
            showFeedbackSheet = true
            bringWindowToFront()
        }
    }

    private func bringWindowToFront() {
        // Activate the app
        NSApp.activate(ignoringOtherApps: true)

        // Bring main window to front
        for window in NSApp.windows {
            // Skip menu bar windows (level > 0 means floating/status bar)
            guard window.level.rawValue == 0 else { continue }

            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    // MARK: - Deeplink Handling

    private func handleDeeplink(_ route: DeeplinkRoute?) {
        guard let route = route else { return }

        switch route {
        case .search:
            // Open fullscreen timeline with search
            TimelineWindowController.shared.show()

        case .timeline:
            // Open fullscreen timeline
            TimelineWindowController.shared.show()
        }
    }

    // MARK: - Onboarding

    private func checkOnboarding() async {
        let shouldShow = await coordinator.onboardingManager.shouldShowOnboarding()
        await MainActor.run {
            showOnboarding = shouldShow
        }
    }
}

// MARK: - Main Views

enum MainView {
    case dashboard
    case settings
    // Note: timeline and search are now fullscreen overlays handled by TimelineWindowController
}

// MARK: - Preview

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()

        ContentView(coordinator: coordinator)
            .preferredColorScheme(.dark)
    }
}
#endif
