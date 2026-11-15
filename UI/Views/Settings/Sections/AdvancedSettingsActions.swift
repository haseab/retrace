import SwiftUI
import App
import Database

extension SettingsView {
    var retraceCLILauncherManager: CLILauncherManager {
        CLILauncherManager()
    }

    var retraceCLIStatusTitle: String {
        switch retraceCLIStatus.state {
        case .unsupportedAppLocation:
            return "Unsupported App Location"
        case .bundledCLIMissing:
            return "Bundled CLI Missing"
        case .notInstalled:
            return "Not Installed"
        case .installed:
            return "Installed"
        case .needsRepair:
            return "Needs Repair"
        }
    }

    var retraceCLIStatusColor: Color {
        switch retraceCLIStatus.state {
        case .installed:
            return .green
        case .needsRepair, .bundledCLIMissing:
            return .orange
        case .unsupportedAppLocation:
            return .yellow
        case .notInstalled:
            return .retraceSecondary
        }
    }

    var canInstallRetraceCLI: Bool {
        enableRetraceCLI &&
            !isPerformingRetraceCLILauncherOperation &&
            retraceCLIStatus.state == .notInstalled
    }

    var canRepairRetraceCLI: Bool {
        enableRetraceCLI &&
            !isPerformingRetraceCLILauncherOperation &&
            (retraceCLIStatus.state == .installed || retraceCLIStatus.state == .needsRepair)
    }

    var canRemoveRetraceCLI: Bool {
        !isPerformingRetraceCLILauncherOperation &&
            FileManager.default.fileExists(atPath: retraceCLIStatus.launcherPath)
    }

    func refreshRetraceCLIStatus() {
        retraceCLIStatus = retraceCLILauncherManager.status()
    }

    func handleRetraceCLIToggleChanged(_ enabled: Bool) {
        DashboardViewModel.recordDeveloperSettingToggle(
            coordinator: coordinatorWrapper.coordinator,
            source: "settings.advanced",
            settingKey: "enableRetraceCLI",
            isEnabled: enabled
        )

        refreshRetraceCLIStatus()

        if enabled {
            showSettingsToast("CLI installation controls shown. Install the command below to use `retrace` in Terminal.")
        }
    }

    func installRetraceCLILauncher() {
        performRetraceCLILauncherOperation(
            action: .install,
            successMessage: "Installed `retrace` at \(retraceCLIStatus.launcherPath)"
        ) { manager in
            try manager.installLauncher()
        }
    }

    func repairRetraceCLILauncher() {
        performRetraceCLILauncherOperation(
            action: .repair,
            successMessage: "Repaired `retrace` at \(retraceCLIStatus.launcherPath)"
        ) { manager in
            try manager.repairLauncher()
        }
    }

    func removeRetraceCLILauncher() {
        performRetraceCLILauncherOperation(
            action: .remove,
            successMessage: "Removed `retrace` from \(retraceCLIStatus.launcherPath)"
        ) { manager in
            try manager.removeLauncher()
        }
    }

    private func performRetraceCLILauncherOperation(
        action: CLILauncherOperationResult.Action,
        successMessage: String,
        operation: @escaping @Sendable (CLILauncherManager) throws -> CLILauncherOperationResult
    ) {
        guard !isPerformingRetraceCLILauncherOperation else { return }

        let manager = retraceCLILauncherManager
        let statusBefore = manager.status()
        isPerformingRetraceCLILauncherOperation = true

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try operation(manager)
                }.value
                let statusAfter = manager.status()

                await MainActor.run {
                    retraceCLIStatus = statusAfter
                    isPerformingRetraceCLILauncherOperation = false
                    showSettingsToast(successMessage)
                    recordRetraceCLILauncherMetric(
                        action: action.rawValue,
                        outcome: "success",
                        status: statusAfter.state.rawValue,
                        usedPrivileges: result.usedPrivileges
                    )
                }
            } catch {
                let statusAfter = manager.status()

                await MainActor.run {
                    retraceCLIStatus = statusAfter
                    isPerformingRetraceCLILauncherOperation = false
                    showSettingsToast(error.localizedDescription, isError: true)
                    recordRetraceCLILauncherMetric(
                        action: action.rawValue,
                        outcome: "failure",
                        status: statusBefore.state.rawValue,
                        usedPrivileges: nil,
                        error: error.localizedDescription
                    )
                }
            }
        }
    }

    func recordRetraceCLILauncherMetric(
        action: String,
        outcome: String,
        status: String,
        usedPrivileges: Bool?,
        error: String? = nil
    ) {
        var payload: [String: Any] = [
            "source": "settings.advanced",
            "action": action,
            "outcome": outcome,
            "status": status
        ]
        if let usedPrivileges {
            payload["usedPrivileges"] = usedPrivileges
        }
        if let error, !error.isEmpty {
            payload["error"] = error
        }

        UIMetricsRecorder.recordDictionary(
            coordinator: coordinatorWrapper.coordinator,
            type: .terminalCommandAction,
            payload: payload
        )
    }
}
