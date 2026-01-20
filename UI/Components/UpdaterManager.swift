import Foundation
import Sparkle
import Shared

/// Manages the Sparkle updater for automatic app updates
/// This class wraps SPUStandardUpdaterController to provide a clean interface
/// for the rest of the app to interact with the update system.
public final class UpdaterManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = UpdaterManager()

    // MARK: - Properties

    /// The Sparkle updater controller
    private var updaterController: SPUStandardUpdaterController?

    /// Whether automatic update checks are enabled
    @Published public var automaticUpdatesEnabled: Bool = true {
        didSet {
            updaterController?.updater.automaticallyChecksForUpdates = automaticUpdatesEnabled
        }
    }

    /// Whether the updater can check for updates (is properly configured)
    @Published public private(set) var canCheckForUpdates: Bool = false

    /// Whether an update check is currently in progress
    @Published public private(set) var isCheckingForUpdates: Bool = false

    /// The last time we checked for updates
    @Published public private(set) var lastUpdateCheckDate: Date?

    // MARK: - Initialization

    private init() {
        // Initialize will be called separately to ensure proper setup timing
    }

    /// Initialize the Sparkle updater
    /// Call this after the app has finished launching
    public func initialize() {
        // Skip updater in debug builds
        #if DEBUG
        Log.info("[UpdaterManager] Skipping updater initialization in DEBUG mode", category: .app)
        canCheckForUpdates = false
        return
        #else
        // Create the updater controller
        // startingUpdater: true - starts automatic update checks
        // updaterDelegate: nil - use default behavior
        // userDriverDelegate: nil - use default UI
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Check if properly configured
        canCheckForUpdates = updaterController?.updater.canCheckForUpdates ?? false

        // Sync automatic updates setting
        if let updater = updaterController?.updater {
            automaticUpdatesEnabled = updater.automaticallyChecksForUpdates
            lastUpdateCheckDate = updater.lastUpdateCheckDate
        }

        Log.info("[UpdaterManager] Initialized. Can check for updates: \(canCheckForUpdates)", category: .app)

        if !canCheckForUpdates {
            Log.warning("[UpdaterManager] Update checking is not available. Check SUFeedURL and SUPublicEDKey in Info.plist", category: .app)
        }
        #endif
    }

    // MARK: - Public Methods

    /// Manually check for updates
    /// This shows the update UI if an update is available
    public func checkForUpdates() {
        guard canCheckForUpdates else {
            Log.warning("[UpdaterManager] Cannot check for updates - updater not properly configured", category: .app)
            return
        }

        Log.info("[UpdaterManager] Checking for updates...", category: .app)
        isCheckingForUpdates = true

        // checkForUpdates shows UI and handles the entire update flow
        updaterController?.checkForUpdates(nil)

        // Update the last check date after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.isCheckingForUpdates = false
            self?.lastUpdateCheckDate = self?.updaterController?.updater.lastUpdateCheckDate
        }
    }

    /// Check for updates in the background without showing UI unless an update is found
    public func checkForUpdatesInBackground() {
        guard canCheckForUpdates else { return }

        Log.info("[UpdaterManager] Checking for updates in background...", category: .app)
        updaterController?.updater.checkForUpdatesInBackground()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.lastUpdateCheckDate = self?.updaterController?.updater.lastUpdateCheckDate
        }
    }

    /// Get the current app version
    public var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    /// Get the current build number
    public var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }
}
