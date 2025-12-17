import SwiftUI
import App
import Inject

/// Root content view with navigation between main views
public struct ContentView: View {

    // MARK: - Properties

    @ObserveInjection var inject
    @State private var selectedView: MainView = .dashboard
    @State private var showOnboarding: Bool? = nil  // nil = loading, true = show onboarding, false = show main app
    @StateObject private var deeplinkHandler = DeeplinkHandler()
    @StateObject private var menuBarManager: MenuBarManager

    private let coordinator: AppCoordinator

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _menuBarManager = StateObject(wrappedValue: MenuBarManager(coordinator: coordinator))
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
                    Group {
                        switch selectedView {
                        case .dashboard:
                            DashboardView(coordinator: coordinator)

                        case .timeline:
                            TimelineView(coordinator: coordinator)

                        case .search:
                            SearchView(coordinator: coordinator)

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
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .openTimeline,
            object: nil,
            queue: .main
        ) { _ in
            selectedView = .timeline
        }

        NotificationCenter.default.addObserver(
            forName: .openSearch,
            object: nil,
            queue: .main
        ) { _ in
            selectedView = .search
        }

        NotificationCenter.default.addObserver(
            forName: .openDashboard,
            object: nil,
            queue: .main
        ) { _ in
            selectedView = .dashboard
        }

        NotificationCenter.default.addObserver(
            forName: .openSettings,
            object: nil,
            queue: .main
        ) { _ in
            selectedView = .settings
        }
    }

    // MARK: - Deeplink Handling

    private func handleDeeplink(_ route: DeeplinkRoute?) {
        guard let route = route else { return }

        switch route {
        case .search:
            selectedView = .search
            // TODO: Pass query/timestamp/app to SearchView

        case .timeline:
            selectedView = .timeline
            // TODO: Pass timestamp to TimelineView
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
    case timeline
    case search
    case settings
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
