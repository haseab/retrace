import App
import Combine
import CrashRecoverySupport
import Foundation

struct CrashRecoveryStatusBannerState: Equatable {
    enum Status: String {
        case requiresApproval = "requires_approval"
        case registrationFailed = "registration_failed"
        case helperArmFailed = "helper_arm_failed"
    }

    let status: Status

    init?(userFacingStatus: CrashRecoverySupport.Status) {
        switch userFacingStatus {
        case .available:
            return nil
        case .requiresApproval:
            status = .requiresApproval
        case .unavailable(.registrationFailed):
            status = .registrationFailed
        case .unavailable(.helperArmFailed):
            status = .helperArmFailed
        }
    }

    var signature: String {
        status.rawValue
    }

    var messageText: String {
        switch status {
        case .requiresApproval:
            return "Automatic restart after crashes is off until you allow Retrace's background helper in System Settings > General > Login Items & Extensions > Allow in Background. After enabling it, return to Retrace and click Retry."
        case .registrationFailed:
            return "Automatic restart after crashes is off because Retrace couldn't register its background helper. Reinstall or replace this build, then click Retry."
        case .helperArmFailed:
            return "Automatic restart after crashes is off because Retrace couldn't connect to its background helper after launch. Click Retry. If it keeps failing, replace this build."
        }
    }

    var showsOpenSettingsAction: Bool {
        status == .requiresApproval
    }
}

@MainActor
final class CrashRecoveryBannerModel: ObservableObject {
    @Published private(set) var state: CrashRecoveryStatusBannerState?

    private let coordinator: AppCoordinator
    private let manager: CrashRecoveryManager
    private var cancellables = Set<AnyCancellable>()
    private var dismissedUntil: Date?
    private var lastTrackedSignature: String?

    private static let dismissSnoozeInterval: TimeInterval = 30 * 60

    convenience init(coordinator: AppCoordinator) {
        self.init(coordinator: coordinator, manager: CrashRecoveryManager.shared)
    }

    init(
        coordinator: AppCoordinator,
        manager: CrashRecoveryManager
    ) {
        self.coordinator = coordinator
        self.manager = manager

        manager.$userFacingStatus
            .sink { [weak self] status in
                self?.apply(userFacingStatus: status)
            }
            .store(in: &cancellables)
    }

    func refresh() {
        manager.refreshUserFacingStatus()
    }

    func dismiss() {
        guard let state else { return }
        recordAction("dismissed", state: state)
        self.state = nil
        dismissedUntil = Date().addingTimeInterval(Self.dismissSnoozeInterval)
        lastTrackedSignature = nil
    }

    func openSettings() {
        guard let state, state.showsOpenSettingsAction else { return }
        recordAction("open_settings_clicked", state: state)
        SystemSettingsOpener.openSystemSettingsApp()
    }

    func retry() {
        guard let state else { return }
        recordAction("retry_clicked", state: state)

        Task { @MainActor [weak self] in
            await self?.manager.retryActivationAfterApprovalChange()
            self?.refresh()
        }
    }

    private func apply(
        userFacingStatus: CrashRecoverySupport.Status,
        now: Date = Date()
    ) {
        guard let nextState = CrashRecoveryStatusBannerState(userFacingStatus: userFacingStatus) else {
            state = nil
            dismissedUntil = nil
            lastTrackedSignature = nil
            return
        }

        if let dismissedUntil, dismissedUntil > now {
            state = nil
            return
        }

        state = nextState

        guard nextState.signature != lastTrackedSignature else {
            return
        }

        lastTrackedSignature = nextState.signature
        recordAction("banner_shown", state: nextState)
    }

    private func recordAction(_ action: String, state: CrashRecoveryStatusBannerState) {
        let metadata = jsonMetadata([
            "action": action,
            "status": state.status.rawValue
        ])
        Task {
            try? await coordinator.recordMetricEvent(
                metricType: .crashRecoveryApprovalBannerAction,
                metadata: metadata
            )
        }
    }

    private func jsonMetadata(_ fields: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
