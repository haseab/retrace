import SwiftUI
import Combine
import Shared
import App

/// MainActor wrapper for AppCoordinator to make it compatible with SwiftUI's @StateObject
/// Since AppCoordinator is an actor, we need this Observable wrapper for SwiftUI integration
@MainActor
public class AppCoordinatorWrapper: ObservableObject {

    // MARK: - Properties

    /// The underlying actor-based coordinator
    public let coordinator: AppCoordinator

    // Published state for UI updates
    @Published public var isRunning = false
    @Published public var pipelineStatus: PipelineStatus?
    @Published public var lastError: String?
    @Published public var showAccessibilityPermissionWarning = false

    // MARK: - Initialization

    public init() {
        self.coordinator = AppCoordinator()
    }

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Lifecycle

    public func initialize() async throws {
        try await coordinator.initialize()

        // Set up accessibility permission warning callback
        await coordinator.setupAccessibilityWarningCallback { [weak self] in
            Task { @MainActor in
                self?.showAccessibilityPermissionWarning = true
            }
        }
    }

    public func startPipeline() async throws {
        try await coordinator.startPipeline()
        await updateStatus()
    }

    public func dismissAccessibilityWarning() {
        showAccessibilityPermissionWarning = false
    }

    public func stopPipeline() async throws {
        try await coordinator.stopPipeline()
        await updateStatus()
    }

    public func shutdown() async throws {
        try await coordinator.shutdown()
    }

    // MARK: - Status Updates

    private func updateStatus() async {
        let status = await coordinator.getStatus()
        self.isRunning = status.isRunning
        self.pipelineStatus = status
    }

    public func refreshStatus() async {
        await updateStatus()
    }
}
