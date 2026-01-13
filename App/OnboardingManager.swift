import Foundation
import Shared

/// Manages first-launch onboarding flow
/// Tracks whether user has completed the 8-step onboarding
/// Owner: APP integration
public actor OnboardingManager {

    // MARK: - UserDefaults Keys

    private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private static let hasDownloadedModelsKey = "hasDownloadedModels"
    private static let onboardingSkippedKey = "onboardingSkipped"
    private static let onboardingVersionKey = "onboardingVersion"
    private static let timelineShortcutKey = "timelineShortcutConfig"
    private static let dashboardShortcutKey = "dashboardShortcutConfig"
    private static let hasRewindDataKey = "hasRewindData"
    private static let rewindMigrationCompletedKey = "rewindMigrationCompleted"

    // Current onboarding version - increment to force re-onboarding
    private static let currentOnboardingVersion = 2

    // MARK: - State

    public var hasCompletedOnboarding: Bool {
        let completedVersion = UserDefaults.standard.integer(forKey: Self.onboardingVersionKey)
        return completedVersion >= Self.currentOnboardingVersion
    }

    public var hasDownloadedModels: Bool {
        UserDefaults.standard.bool(forKey: Self.hasDownloadedModelsKey)
    }

    public var onboardingSkipped: Bool {
        UserDefaults.standard.bool(forKey: Self.onboardingSkippedKey)
    }

    /// Timeline shortcut configuration (key + modifiers)
    public var timelineShortcut: ShortcutConfig {
        guard let data = UserDefaults.standard.data(forKey: Self.timelineShortcutKey),
              let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) else {
            return .defaultTimeline
        }
        return config
    }

    /// Dashboard shortcut configuration (key + modifiers)
    public var dashboardShortcut: ShortcutConfig {
        guard let data = UserDefaults.standard.data(forKey: Self.dashboardShortcutKey),
              let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) else {
            return .defaultDashboard
        }
        return config
    }

    public var hasRewindData: Bool? {
        if UserDefaults.standard.object(forKey: Self.hasRewindDataKey) == nil {
            return nil
        }
        return UserDefaults.standard.bool(forKey: Self.hasRewindDataKey)
    }

    public var rewindMigrationCompleted: Bool {
        UserDefaults.standard.bool(forKey: Self.rewindMigrationCompletedKey)
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Onboarding Flow

    public func shouldShowOnboarding() async -> Bool {
        // Show onboarding if user hasn't completed current version
        return !hasCompletedOnboarding
    }

    public func markOnboardingCompleted() {
        UserDefaults.standard.set(Self.currentOnboardingVersion, forKey: Self.onboardingVersionKey)
        UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
        Log.info("Onboarding marked as completed (version \(Self.currentOnboardingVersion))", category: .app)
    }

    public func markModelsDownloaded() {
        UserDefaults.standard.set(true, forKey: Self.hasDownloadedModelsKey)
        Log.info("Models marked as downloaded", category: .app)
    }

    public func markOnboardingSkipped() {
        UserDefaults.standard.set(true, forKey: Self.onboardingSkippedKey)
        UserDefaults.standard.set(Self.currentOnboardingVersion, forKey: Self.onboardingVersionKey)
        Log.info("Onboarding skipped by user", category: .app)
    }

    // MARK: - Shortcuts

    /// Set timeline shortcut (full config with key + modifiers)
    public func setTimelineShortcut(_ config: ShortcutConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.timelineShortcutKey)
            Log.info("Timeline shortcut set to: \(config.displayString)", category: .app)
        }
    }

    /// Set dashboard shortcut (full config with key + modifiers)
    public func setDashboardShortcut(_ config: ShortcutConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.dashboardShortcutKey)
            Log.info("Dashboard shortcut set to: \(config.displayString)", category: .app)
        }
    }

    // MARK: - Rewind Data

    public func setHasRewindData(_ hasData: Bool) {
        UserDefaults.standard.set(hasData, forKey: Self.hasRewindDataKey)
        Log.info("Has Rewind data: \(hasData)", category: .app)
    }

    public func markRewindMigrationCompleted() {
        UserDefaults.standard.set(true, forKey: Self.rewindMigrationCompletedKey)
        Log.info("Rewind migration marked as completed", category: .app)
    }

    // MARK: - Reset (for testing)

    public func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: Self.hasCompletedOnboardingKey)
        UserDefaults.standard.removeObject(forKey: Self.hasDownloadedModelsKey)
        UserDefaults.standard.removeObject(forKey: Self.onboardingSkippedKey)
        UserDefaults.standard.removeObject(forKey: Self.onboardingVersionKey)
        UserDefaults.standard.removeObject(forKey: Self.timelineShortcutKey)
        UserDefaults.standard.removeObject(forKey: Self.dashboardShortcutKey)
        UserDefaults.standard.removeObject(forKey: Self.hasRewindDataKey)
        UserDefaults.standard.removeObject(forKey: Self.rewindMigrationCompletedKey)
        Log.info("Onboarding state reset", category: .app)
    }
}
