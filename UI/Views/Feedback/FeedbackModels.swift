import Foundation

// MARK: - Feedback Type

/// Types of feedback users can submit
public enum FeedbackType: String, CaseIterable, Identifiable {
    case bug = "Bug Report"
    case feature = "Feature Request"
    case question = "Question"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .bug: return "ladybug"
        case .feature: return "lightbulb"
        case .question: return "questionmark.circle"
        }
    }

    /// Short label for compact button display
    public var shortLabel: String {
        switch self {
        case .bug: return "Bug"
        case .feature: return "Feature"
        case .question: return "Question"
        }
    }

    public var placeholder: String {
        switch self {
        case .bug: return "Describe what happened and what you expected..."
        case .feature: return "Describe the feature you'd like to see..."
        case .question: return "What would you like to know?"
        }
    }
}

// MARK: - Diagnostic Info

/// System and app diagnostic information included with feedback
public struct DiagnosticInfo: Codable {
    public let appVersion: String
    public let buildNumber: String
    public let macOSVersion: String
    public let deviceModel: String
    public let totalDiskSpace: String
    public let freeDiskSpace: String
    public let databaseStats: DatabaseStats
    public let recentErrors: [String]
    public let recentLogs: [String]
    public let timestamp: Date

    public struct DatabaseStats: Codable {
        public let sessionCount: Int
        public let frameCount: Int
        public let segmentCount: Int
        public let databaseSizeMB: Double
    }

    public init(
        appVersion: String,
        buildNumber: String,
        macOSVersion: String,
        deviceModel: String,
        totalDiskSpace: String,
        freeDiskSpace: String,
        databaseStats: DatabaseStats,
        recentErrors: [String],
        recentLogs: [String] = []
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.macOSVersion = macOSVersion
        self.deviceModel = deviceModel
        self.totalDiskSpace = totalDiskSpace
        self.freeDiskSpace = freeDiskSpace
        self.databaseStats = databaseStats
        self.recentErrors = recentErrors
        self.recentLogs = recentLogs
        self.timestamp = Date()
    }

    /// Format as readable text for display (summary without full logs)
    public func formattedText() -> String {
        var text = """
        App Version: \(appVersion) (\(buildNumber))
        macOS: \(macOSVersion)
        Device: \(deviceModel)
        Disk: \(freeDiskSpace) free of \(totalDiskSpace)

        Database Stats:
        - Sessions: \(databaseStats.sessionCount)
        - Frames: \(databaseStats.frameCount)
        - Segments: \(databaseStats.segmentCount)
        - Size: \(String(format: "%.1f", databaseStats.databaseSizeMB)) MB

        Recent Errors: \(recentErrors.isEmpty ? "None" : "\(recentErrors.count) error(s)")
        """

        if !recentLogs.isEmpty {
            text += "\nRecent Logs: \(recentLogs.count) entries from last hour"
        }

        return text
    }

    /// Full formatted text including all logs
    public func fullFormattedText() -> String {
        var text = formattedText()

        if !recentErrors.isEmpty {
            text += "\n\n--- ERRORS ---\n"
            text += recentErrors.joined(separator: "\n")
        }

        if !recentLogs.isEmpty {
            text += "\n\n--- FULL LOGS (last hour) ---\n"
            text += recentLogs.joined(separator: "\n")
        }

        return text
    }
}

// MARK: - Feedback Submission

/// Complete feedback submission payload
public struct FeedbackSubmission: Codable {
    public let type: String
    public let email: String?
    public let description: String
    public let diagnostics: DiagnosticInfo
    public let includeScreenshot: Bool
    public let screenshotData: Data?

    public init(
        type: FeedbackType,
        email: String = "",
        description: String,
        diagnostics: DiagnosticInfo,
        includeScreenshot: Bool = false,
        screenshotData: Data? = nil
    ) {
        self.type = type.rawValue
        self.email = email.isEmpty ? nil : email
        self.description = description
        self.diagnostics = diagnostics
        self.includeScreenshot = includeScreenshot
        self.screenshotData = screenshotData
    }
}
