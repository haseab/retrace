import Foundation
import Shared

// MARK: - Feedback Stats Provider

/// Protocol for providing database statistics to feedback service
public protocol FeedbackStatsProvider {
    func getDatabaseStats() async throws -> DatabaseStatistics
    func getAppSessionCount() async throws -> Int
}

// MARK: - Feedback Service

/// Collects diagnostic information and submits feedback.
///
/// **Why this exists:** Retrace has no pre-existing telemetry, analytics, or crash reporting SDK.
/// This service is the *only* mechanism for understanding user-reported issues. All data is
/// collected on-demand when the user explicitly submits feedback — nothing is collected in the
/// background or sent automatically.
///
/// **Privacy preserved:** Process info reports category counts only, never app names.
/// Memory-spike diagnostics add only a small allowlist of Retrace/media-system helper process
/// names (for example `VTDecoderXPCService`) because those are directly relevant to decoder leaks.
/// No file paths, no user data. Settings use a strict whitelist (see `collectSanitizedSettingsSnapshot`).
public final class FeedbackService: @unchecked Sendable {

    public static let shared = FeedbackService()
    static let diagnosticsLogLimit = 1_000
    static let submissionDiagnosticsLogLimit = 10_000
    static let groupedFeedbackLogLimitPerFamily = 2_000
    static let feedbackEndpoint = URL(string: "https://retrace.to/api/feedback")!

    private init() {}

    static func submissionRawLogBudget(memorySummaryCount: Int) -> Int {
        max(0, submissionDiagnosticsLogLimit - max(0, memorySummaryCount))
    }
}

// MARK: - Errors

public enum FeedbackError: LocalizedError {
    case submissionFailed
    case invalidData
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .submissionFailed:
            return "Failed to submit feedback. Please try again."
        case .invalidData:
            return "Invalid feedback data."
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}
