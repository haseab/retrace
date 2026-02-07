import SwiftUI
import App

/// Root content view with navigation between main views
public struct ContentView: View {

    // MARK: - Properties

    @State private var selectedView: MainView = .dashboard
    @State private var showOnboarding: Bool? = nil  // nil = loading, true = show onboarding, false = show main app
    @State private var showFeedbackSheet = false
    @StateObject private var deeplinkHandler = DeeplinkHandler()
    @StateObject private var launchOnLoginReminderManager: LaunchOnLoginReminderManager
    @StateObject private var milestoneCelebrationManager: MilestoneCelebrationManager
    @StateObject private var coordinatorWrapper: AppCoordinatorWrapper
    @StateObject private var dashboardViewModel: DashboardViewModel

    private let coordinator: AppCoordinator

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self._launchOnLoginReminderManager = StateObject(wrappedValue: LaunchOnLoginReminderManager(coordinator: coordinator))
        self._milestoneCelebrationManager = StateObject(wrappedValue: MilestoneCelebrationManager(coordinator: coordinator))
        self._coordinatorWrapper = StateObject(wrappedValue: AppCoordinatorWrapper(coordinator: coordinator))
        self._dashboardViewModel = StateObject(wrappedValue: DashboardViewModel(coordinator: coordinator))
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
                            MenuBarManager.shared?.syncWithCoordinator()
                        }
                    }
                } else {
                    // Main content based on selected view
                    // Note: Timeline and Search are now fullscreen overlays, not tabs
                    Group {
                        switch selectedView {
                        case .dashboard:
                            DashboardView(
                                viewModel: dashboardViewModel,
                                coordinator: coordinator,
                                launchOnLoginReminderManager: launchOnLoginReminderManager,
                                milestoneCelebrationManager: milestoneCelebrationManager
                            )

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
                .environmentObject(coordinatorWrapper)
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
            // Switch to dashboard view and show window
            selectedView = .dashboard
            bringWindowToFront()
        }

        NotificationCenter.default.addObserver(
            forName: .toggleDashboard,
            object: nil,
            queue: .main
        ) { _ in
            // Toggle dashboard visibility - hide if visible and frontmost, show otherwise
            if isDashboardWindowFrontmost() {
                hideMainWindow()
            } else {
                selectedView = .dashboard
                bringWindowToFront()
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

    /// Check if the dashboard window is currently frontmost and visible
    private func isDashboardWindowFrontmost() -> Bool {
        // Check if our app is active
        guard NSApp.isActive else { return false }

        // Check if the main window (level 0) is key and visible
        for window in NSApp.windows {
            guard window.level.rawValue == 0 else { continue }
            if window.isKeyWindow && window.isVisible {
                return true
            }
        }
        return false
    }

    /// Hide the main window
    private func hideMainWindow() {
        for window in NSApp.windows {
            // Skip menu bar windows
            guard window.level.rawValue == 0 else { continue }
            window.orderOut(nil)
        }
        // Optionally hide the app from dock focus
        NSApp.hide(nil)
    }

    // MARK: - Deeplink Handling

    private func handleDeeplink(_ route: DeeplinkRoute?) {
        guard let route = route else { return }

        switch route {
        case .search(_, let timestamp, _):
            // Open fullscreen timeline with search
            if let timestamp = timestamp {
                TimelineWindowController.shared.showAndNavigate(to: timestamp)
            } else {
                TimelineWindowController.shared.show()
            }

        case .timeline(let timestamp):
            // Open fullscreen timeline at specific timestamp
            if let timestamp = timestamp {
                TimelineWindowController.shared.showAndNavigate(to: timestamp)
            } else {
                TimelineWindowController.shared.show()
            }
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
