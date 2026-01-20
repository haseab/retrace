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
        Log.debug("[AppCoordinatorWrapper] initialize() called - starting coordinator.initialize()", category: .app)
        try await coordinator.initialize()
        Log.debug("[AppCoordinatorWrapper] coordinator.initialize() completed", category: .app)

        // Set up accessibility permission warning callback
        await coordinator.setupAccessibilityWarningCallback { [weak self] in
            Task { @MainActor in
                self?.showAccessibilityPermissionWarning = true
            }
        }

        // Auto-start recording if it was previously running
        let shouldAutoStart = AppCoordinator.shouldAutoStartRecording()
        Log.debug("[AppCoordinatorWrapper] shouldAutoStartRecording() = \(shouldAutoStart)", category: .app)
        if shouldAutoStart {
            Log.debug("[AppCoordinatorWrapper] Auto-starting recording based on previous state", category: .app)
            do {
                try await coordinator.startPipeline()
                await updateStatus()
                Log.debug("[AppCoordinatorWrapper] Auto-start recording succeeded", category: .app)
            } catch {
                Log.error("[AppCoordinatorWrapper] Auto-start recording failed: \(error)", category: .app)
            }
        } else {
            Log.debug("[AppCoordinatorWrapper] Not auto-starting (shouldAutoStart=false)", category: .app)
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
