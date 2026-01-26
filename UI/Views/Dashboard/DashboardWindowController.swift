import AppKit
import SwiftUI
import App
import Shared

/// Manages the dashboard window as an on-demand window
/// This follows the menu bar app pattern where windows are only created when requested
@MainActor
public class DashboardWindowController: NSObject {

    // MARK: - Singleton

    public static let shared = DashboardWindowController()

    // MARK: - Properties

    private(set) var window: NSWindow?
    private var coordinator: AppCoordinator?

    /// Whether the dashboard window is currently visible
    public private(set) var isVisible = false

    // MARK: - Initialization

    private override init() {
        super.init()
        setupNotifications()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .toggleDashboard,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.toggle()
        }
    }

    // MARK: - Configuration

    /// Configure with the app coordinator (call once during app launch)
    public func configure(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Show/Hide

    /// Show the dashboard window
    public func show() {
        // If window already exists and is visible, just bring it to front
        if let window = window, window.isVisible {
            bringToFront()
            return
        }

        guard let coordinator = coordinator else {
            Log.error("[DashboardWindowController] Cannot show - coordinator not configured", category: .ui)
            return
        }

        // Create window if needed
        if window == nil {
            window = createWindow(coordinator: coordinator)
        }

        guard let window = window else { return }

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        isVisible = true

        // Post notification
        NotificationCenter.default.post(name: .dashboardDidOpen, object: nil)
    }

    /// Hide the dashboard window
    public func hide() {
        guard let window = window, isVisible else { return }

        window.orderOut(nil)
        isVisible = false

        // Post notification
        NotificationCenter.default.post(name: .dashboardDidClose, object: nil)
    }

    /// Toggle dashboard visibility
    /// - If hidden: show and bring to front
    /// - If visible but behind other windows: bring to front
    /// - If visible and frontmost: hide
    public func toggle() {
        if isVisible {
            // Check if window is frontmost (key window and app is active)
            if let window = window, window.isKeyWindow && NSApp.isActive {
                hide()
            } else {
                bringToFront()
            }
        } else {
            show()
        }
    }

    /// Bring dashboard window to front if visible
    public func bringToFront() {
        guard let window = window else { return }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - Window Creation

    private func createWindow(coordinator: AppCoordinator) -> NSWindow {
        // Create the SwiftUI view for the dashboard content
        let dashboardContent = DashboardContentView(coordinator: coordinator)

        // Create hosting controller
        let hostingController = NSHostingController(rootView: dashboardContent)

        // Create window
        let window = NSWindow(contentViewController: hostingController)

        // Configure window properties
        window.title = "Retrace"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.minSize = NSSize(width: 1000, height: 700)
        window.center()

        // Set window level and appearance
        window.level = .normal
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.backgroundColor = NSColor(named: "retraceBackground") ?? NSColor.windowBackgroundColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Set delegate to handle window events
        window.delegate = self

        return window
    }

    // MARK: - Navigate to View

    /// Navigate to settings view within the dashboard
    public func showSettings() {
        show()
        NotificationCenter.default.post(name: .dashboardShowSettings, object: nil)
    }
}

// MARK: - NSWindowDelegate

extension DashboardWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        isVisible = false
        NotificationCenter.default.post(name: .dashboardDidClose, object: nil)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        // Window is now active
    }
}

// MARK: - Dashboard Content View

/// SwiftUI view that wraps the dashboard content
/// This handles navigation between dashboard and settings views
struct DashboardContentView: View {
    let coordinator: AppCoordinator

    /// Wrapper for coordinator to inject as environment object for child views
    @StateObject private var coordinatorWrapper: AppCoordinatorWrapper

    /// Manager for launch on login reminder
    @StateObject private var launchOnLoginReminderManager: LaunchOnLoginReminderManager

    /// Manager for milestone celebrations
    @StateObject private var milestoneCelebrationManager: MilestoneCelebrationManager

    @State private var selectedView: DashboardSelectedView = .dashboard
    @State private var showFeedbackSheet = false
    @State private var showOnboarding: Bool? = nil

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self._coordinatorWrapper = StateObject(wrappedValue: AppCoordinatorWrapper(coordinator: coordinator))
        self._launchOnLoginReminderManager = StateObject(wrappedValue: LaunchOnLoginReminderManager(coordinator: coordinator))
        self._milestoneCelebrationManager = StateObject(wrappedValue: MilestoneCelebrationManager(coordinator: coordinator))
    }

    var body: some View {
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
                    Group {
                        switch selectedView {
                        case .dashboard:
                            DashboardView(
                                coordinator: coordinator,
                                launchOnLoginReminderManager: launchOnLoginReminderManager,
                                milestoneCelebrationManager: milestoneCelebrationManager
                            )

                        case .settings:
                            SettingsView()
                                .environmentObject(coordinatorWrapper)
                        }
                    }
                }
            } else {
                // Loading state
                Color.retraceBackground
                    .ignoresSafeArea()
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .task {
            await checkOnboarding()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDashboard)) { _ in
            selectedView = .dashboard
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardShowSettings)) { _ in
            selectedView = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            selectedView = .settings
            DashboardWindowController.shared.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsAppearance)) { _ in
            selectedView = .settings
            DashboardWindowController.shared.show()
            // General tab contains Appearance settings - it's the default tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFeedback)) { _ in
            showFeedbackSheet = true
            DashboardWindowController.shared.show()
        }
        .sheet(isPresented: $showFeedbackSheet) {
            FeedbackFormView()
        }
    }

    private func checkOnboarding() async {
        let shouldShow = await coordinator.onboardingManager.shouldShowOnboarding()
        await MainActor.run {
            showOnboarding = shouldShow
        }
    }
}

// MARK: - Dashboard Selected View

enum DashboardSelectedView {
    case dashboard
    case settings
}

// MARK: - Notifications

extension Notification.Name {
    static let dashboardDidOpen = Notification.Name("dashboardDidOpen")
    static let dashboardDidClose = Notification.Name("dashboardDidClose")
    static let dashboardShowSettings = Notification.Name("dashboardShowSettings")
}
