import Foundation
import Shared

/// Manages first-launch onboarding flow
/// Tracks whether user has completed model downloads
/// Owner: APP integration
public actor OnboardingManager {

    // MARK: - UserDefaults Keys

    private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private static let hasDownloadedModelsKey = "hasDownloadedModels"
    private static let onboardingSkippedKey = "onboardingSkipped"

    // MARK: - State

    public var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey)
    }

    public var hasDownloadedModels: Bool {
        UserDefaults.standard.bool(forKey: Self.hasDownloadedModelsKey)
    }

    public var onboardingSkipped: Bool {
        UserDefaults.standard.bool(forKey: Self.onboardingSkippedKey)
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Onboarding Flow

    public func shouldShowOnboarding() async -> Bool {
        // Show onboarding if user hasn't completed it and hasn't downloaded models
        return !hasCompletedOnboarding && !hasDownloadedModels
    }

    public func markOnboardingCompleted() {
        UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
        Log.info("Onboarding marked as completed", category: .app)
    }

    public func markModelsDownloaded() {
        UserDefaults.standard.set(true, forKey: Self.hasDownloadedModelsKey)
        Log.info("Models marked as downloaded", category: .app)
    }

    public func markOnboardingSkipped() {
        UserDefaults.standard.set(true, forKey: Self.onboardingSkippedKey)
        UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
        Log.info("Onboarding skipped by user", category: .app)
    }

    // MARK: - Reset (for testing)

    public func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: Self.hasCompletedOnboardingKey)
        UserDefaults.standard.removeObject(forKey: Self.hasDownloadedModelsKey)
        UserDefaults.standard.removeObject(forKey: Self.onboardingSkippedKey)
        Log.info("Onboarding state reset", category: .app)
    }
}
