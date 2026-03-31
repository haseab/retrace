import AppKit

enum LaunchMenuRouting {
    enum VisibleDashboardContent: Equatable {
        case none
        case dashboard
        case settings
        case changelog
        case monitor
    }

    private static let timelineHandoffDelay: TimeInterval = 0.2

    static func dashboardIsFrontAndCenter() -> Bool {
        visibleDashboardContent() == .dashboard
    }

    static func settingsIsFrontAndCenter() -> Bool {
        visibleDashboardContent() == .settings
    }

    static func systemMonitorIsFrontAndCenter() -> Bool {
        visibleDashboardContent() == .monitor
    }

    static func visibleDashboardContent() -> VisibleDashboardContent {
        MainActor.assumeIsolated {
            if let monitorWindow = SystemMonitorWindowController.shared.window,
               SystemMonitorWindowController.shared.isVisible,
               isWindowFrontAndCenter(monitorWindow) {
                return .monitor
            }

            guard let dashboardWindow = DashboardWindowController.shared.window,
                  DashboardWindowController.shared.isVisible,
                  isWindowFrontAndCenter(dashboardWindow) else {
                return .none
            }

            return content(forDashboardWindowTitle: dashboardWindow.title)
        }
    }

    static func content(forDashboardWindowTitle title: String) -> VisibleDashboardContent {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedTitle == "System Monitor" {
            return .monitor
        }
        if trimmedTitle == "Changelog" {
            return .changelog
        }
        if trimmedTitle.hasPrefix("Settings") {
            return .settings
        }
        return .dashboard
    }

    static func showTimeline() {
        MainActor.assumeIsolated {
            TimelineWindowController.shared.show()
        }
    }

    static func hideTimeline() {
        MainActor.assumeIsolated {
            TimelineWindowController.shared.hide()
        }
    }

    static func showSearch(source: String) {
        MainActor.assumeIsolated {
            TimelineWindowController.shared.showSearch(
                query: nil,
                timestamp: nil,
                appBundleID: nil,
                source: source
            )
        }
    }

    static func showDashboard() {
        routeFromTimelineIfNeeded {
            MainActor.assumeIsolated {
                DashboardWindowController.shared.showDashboard()
            }
        }
    }

    static func showSettings() {
        routeFromTimelineIfNeeded {
            MainActor.assumeIsolated {
                DashboardWindowController.shared.showSettings()
            }
        }
    }

    static func showChangelog() {
        routeFromTimelineIfNeeded {
            MainActor.assumeIsolated {
                DashboardWindowController.shared.showChangelog()
            }
        }
    }

    static func showSystemMonitor() {
        routeFromTimelineIfNeeded {
            MainActor.assumeIsolated {
                DashboardWindowController.shared.show()
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
            }
        }
    }

    static func toggleSystemMonitor() {
        routeFromTimelineIfNeeded {
            let isDashboardVisible = MainActor.assumeIsolated {
                DashboardWindowController.shared.isVisible
            }
            guard isDashboardVisible else {
                showSystemMonitor()
                return
            }

            NotificationCenter.default.post(name: .toggleSystemMonitor, object: nil)
        }
    }
}

private extension LaunchMenuRouting {
    static func routeFromTimelineIfNeeded(_ action: @escaping () -> Void) {
        MainActor.assumeIsolated {
            if TimelineWindowController.shared.isVisible {
                TimelineWindowController.shared.hideToShowDashboard()
                DispatchQueue.main.asyncAfter(deadline: .now() + timelineHandoffDelay) {
                    action()
                }
            } else {
                action()
            }
        }
    }

    static func isWindowFrontAndCenter(_ window: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard NSApp.isActive else { return false }
            guard window.isVisible else { return false }
            return window.isKeyWindow || window.attachedSheet != nil
        }
    }
}
