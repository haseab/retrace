import Foundation
import ScreenCaptureKit
import Shared

/// Continuously monitors for private/incognito browser windows
/// Detects new private windows opened after capture has started
actor PrivateWindowMonitor {

    // MARK: - Properties

    private var monitoringTask: Task<Void, Never>?
    private var currentPrivateWindows: Set<UInt32> = [] // Window IDs

    /// Callback when private windows are detected
    nonisolated(unsafe) var onPrivateWindowsChanged: (@Sendable ([SCWindow]) async -> Void)?

    /// Callback when accessibility permission is denied
    nonisolated(unsafe) var onAccessibilityPermissionDenied: (@Sendable () async -> Void)?

    /// How often to check for private windows (in seconds)
    private let checkIntervalSeconds: Double

    // MARK: - Initialization

    init(checkIntervalSeconds: Double = 30.0) {
        self.checkIntervalSeconds = checkIntervalSeconds
    }

    // MARK: - Lifecycle

    /// Start monitoring for private windows
    /// - Parameter config: Capture configuration
    func startMonitoring(config: CaptureConfig) {
        guard config.excludePrivateWindows else {
            Log.info("Private window monitoring disabled in config", category: .capture)
            return
        }

        Log.info("Starting private window monitor (checking every \(Int(checkIntervalSeconds))s)", category: .capture)

        monitoringTask = Task {
            while !Task.isCancelled {
                await checkForPrivateWindows()

                // Wait before next check
                try? await Task.sleep(for: .seconds(checkIntervalSeconds))
            }
        }
    }

    /// Stop monitoring
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        currentPrivateWindows.removeAll()
        Log.info("Stopped private window monitor", category: .capture)
    }

    // MARK: - Private Methods

    /// Check for private windows and update if changed
    private func checkForPrivateWindows() async {
        do {
            // Get shareable content
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            // Detect private windows
            var privateWindows: [SCWindow] = []
            var hasAXPermission = true

            for window in content.windows {
                let (isPrivate, permissionGranted) = PrivateWindowDetector.isPrivateWindowWithPermissionStatus(window)

                if !permissionGranted {
                    hasAXPermission = false
                }

                if isPrivate {
                    privateWindows.append(window)
                }
            }

            // Check if AX permission was lost
            if !hasAXPermission {
                Log.warning("Accessibility permission denied during private window detection", category: .capture)
                if let callback = onAccessibilityPermissionDenied {
                    await callback()
                }
                // Continue with title-based detection
            }

            // Get window IDs
            let newPrivateWindowIDs = Set(privateWindows.map { $0.windowID })

            // Check if the set of private windows changed
            if newPrivateWindowIDs != currentPrivateWindows {
                let added = newPrivateWindowIDs.subtracting(currentPrivateWindows)
                let removed = currentPrivateWindows.subtracting(newPrivateWindowIDs)

                if !added.isEmpty {
                    Log.info("New private windows detected: \(added.count)", category: .capture)
                }
                if !removed.isEmpty {
                    Log.info("Private windows closed: \(removed.count)", category: .capture)
                }

                currentPrivateWindows = newPrivateWindowIDs

                // Notify callback with updated list
                if let callback = onPrivateWindowsChanged {
                    await callback(privateWindows)
                }
            }

        } catch {
            Log.error("Failed to check for private windows: \(error)", category: .capture)
        }
    }

    /// Get current list of private window IDs
    func getCurrentPrivateWindowIDs() -> Set<UInt32> {
        currentPrivateWindows
    }
}
