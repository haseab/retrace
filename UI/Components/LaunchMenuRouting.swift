import AppKit

enum LaunchMenuRouting {
    enum VisibleDashboardContent {
        case dashboard
        case monitor
        case other
    }

    static func visibleDashboardContent() -> VisibleDashboardContent {
        guard NSApp.isActive else { return .other }

        let titles = [NSApp.keyWindow?.title, NSApp.mainWindow?.title]
        if titles.contains("Dashboard") {
            return .dashboard
        }
        if titles.contains("System Monitor") {
            return .monitor
        }
        return .other
    }

    static func dashboardIsFrontAndCenter() -> Bool {
        visibleDashboardContent() == .dashboard
    }

    static func systemMonitorIsFrontAndCenter() -> Bool {
        visibleDashboardContent() == .monitor
    }

    static func settingsIsFrontAndCenter() -> Bool {
        guard NSApp.isActive else { return false }

        let titles = [NSApp.keyWindow?.title, NSApp.mainWindow?.title]
        return titles.contains { title in
            guard let title else { return false }
            return title.hasPrefix("Settings")
        }
    }

    @MainActor
    static func showDashboard() {
        if TimelineWindowController.shared.isVisible {
            TimelineWindowController.shared.hideToShowDashboard()
        }
        DashboardWindowController.shared.showDashboard()
    }

    @MainActor
    static func showChangelog() {
        DashboardWindowController.shared.showChangelog()
    }

    @MainActor
    static func showTimeline() {
        TimelineWindowController.shared.show()
    }

    @MainActor
    static func hideTimeline() {
        TimelineWindowController.shared.hide()
    }

    @MainActor
    static func showSearch(source: String) {
        TimelineWindowController.shared.showSearchOverlay(source: source)
    }

    @MainActor
    static func showSettings() {
        if TimelineWindowController.shared.isVisible {
            TimelineWindowController.shared.hideToShowDashboard()
        }
        DashboardWindowController.shared.showSettings()
    }

    @MainActor
    static func showSystemMonitor() {
        NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
    }

    @MainActor
    static func toggleSystemMonitor() {
        NotificationCenter.default.post(name: .toggleSystemMonitor, object: nil)
    }
}
