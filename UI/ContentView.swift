import SwiftUI
import App

/// Root content view with navigation between main views
public struct ContentView: View {

    // MARK: - Properties

    @State private var selectedView: MainView = .dashboard
    @State private var showOnboarding = false
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
        .frame(minWidth: 1000, minHeight: 700)
        .onAppear {
            menuBarManager.setup()
            setupNotifications()
            checkOnboarding()
        }
        .onOpenURL { url in
            deeplinkHandler.handle(url)
        }
        .onChange(of: deeplinkHandler.activeRoute) { route in
            handleDeeplink(route)
        }
        .sheet(isPresented: $showOnboarding) {
            ModelDownloadView()
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

        case .timeline(let timestamp):
            selectedView = .timeline
            // TODO: Pass timestamp to TimelineView
        }
    }

    // MARK: - Onboarding

    private func checkOnboarding() {
        Task {
            let shouldShow = await coordinator.onboardingManager.shouldShowOnboarding()
            await MainActor.run {
                showOnboarding = shouldShow
            }
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
