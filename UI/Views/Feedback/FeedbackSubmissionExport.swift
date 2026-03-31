import Foundation
import App

extension FeedbackSubmission: Encodable {
    fileprivate static let exportTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public var exportSuggestedBaseName: String {
        Self.suggestedBaseName(forType: type, timestamp: diagnostics.timestamp)
    }

    public static func suggestedBaseName(forType type: String, timestamp: Date = Date()) -> String {
        let typeSlug = type
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let formattedTimestamp = exportFileTimestampFormatter.string(from: timestamp)
        return "retrace-feedback-\(typeSlug.isEmpty ? "report" : typeSlug)-\(formattedTimestamp)"
    }

    public func exportText(
        generatedAt: Date = Date(),
        launchSource: FeedbackLaunchContext.Source? = nil,
        screenshotFileName: String? = nil
    ) -> String {
        let filteredDiagnostics = FilteredDiagnosticInfo(
            diagnostics: diagnostics,
            includedSections: includedDiagnosticSections
        )
        let generatedAtString = Self.exportTimestampFormatter.string(from: generatedAt)
        let diagnosticsTimestamp = Self.exportTimestampFormatter.string(from: diagnostics.timestamp)
        let screenshotLabel = includeScreenshot ? (screenshotFileName ?? "(attached separately)") : "(none)"
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        let structureGuide = [
            "summary header: export metadata, report type, and attachment state",
            "structure guide: quick map of the sections that follow",
            "feedback section: user-entered email and description",
            "diagnostics section: full environment snapshot included with the report",
            "attachment section: exported screenshot filename when present",
            "JSON footer markers: BEGIN/END SUBMISSION JSON delimit the machine-readable payload"
        ]

        let summaryLines = [
            "RETRACE FEEDBACK EXPORT (USER REPORT)",
            "generated_at: \(generatedAtString)",
            "export_format_version: 1",
            "submission_endpoint: https://retrace.to/api/feedback",
            "feedback_type: \(type)",
            "launch_source: \(launchSource?.rawValue ?? FeedbackLaunchContext.Source.manual.rawValue)",
            "report_email: \(email ?? "(none)")",
            "description_length: \(description.count)",
            "diagnostics_timestamp: \(diagnosticsTimestamp)",
            "diagnostics_included_section_count: \(filteredDiagnostics.includedSectionIDs.count)",
            "diagnostics_excluded_section_count: \(filteredDiagnostics.excludedSectionIDs.count)",
            "recent_errors_count: \(filteredDiagnostics.recentErrorsCount)",
            "recent_logs_count: \(filteredDiagnostics.recentLogsCount)",
            "includes_screenshot: \(includeScreenshot ? "yes" : "no")",
            "screenshot_file: \(screenshotLabel)",
            "",
            "STRUCTURE GUIDE",
        ] + structureGuide.enumerated().map { index, line in
            "\(String(format: "%02d", index + 1)). \(line)"
        }

        let payload = FeedbackExportEnvelope(
            metadata: FeedbackExportEnvelope.Metadata(
                description: "LLM-oriented export of the feedback report prepared by Retrace.",
                exportFormatVersion: 1,
                generatedAt: generatedAt,
                submissionEndpoint: "https://retrace.to/api/feedback",
                launchSource: launchSource?.rawValue ?? FeedbackLaunchContext.Source.manual.rawValue,
                screenshotFileName: screenshotFileName,
                screenshotByteCount: screenshotData?.count
            ),
            report: FeedbackExportEnvelope.Report(
                type: type,
                email: email,
                description: description,
                includeScreenshot: includeScreenshot,
                diagnostics: filteredDiagnostics
            )
        )

        return [
            summaryLines.joined(separator: "\n"),
            "",
            "=== FEEDBACK ===",
            "Type: \(type)",
            "Email: \(email ?? "(none)")",
            "",
            "Description:",
            trimmedDescription.isEmpty ? "(empty)" : trimmedDescription,
            "",
            "=== DIAGNOSTICS ===",
            diagnostics.fullFormattedText(including: includedDiagnosticSections),
            "",
            "=== ATTACHMENTS ===",
            includeScreenshot ? "Screenshot: \(screenshotLabel)" : "Screenshot: none",
            "",
            "=== BEGIN SUBMISSION JSON ===",
            payload.prettyPrintedJSON() ?? "{}",
            "=== END SUBMISSION JSON ==="
        ].joined(separator: "\n")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encode(description, forKey: .description)
        try container.encode(
            FilteredDiagnosticInfo(
                diagnostics: diagnostics,
                includedSections: includedDiagnosticSections
            ),
            forKey: .diagnostics
        )
        try container.encode(includeScreenshot, forKey: .includeScreenshot)
        try container.encodeIfPresent(screenshotData, forKey: .screenshotData)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case email
        case description
        case diagnostics
        case includeScreenshot
        case screenshotData
    }

    private static let exportFileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

private struct FilteredDiagnosticInfo: Encodable {
    let diagnostics: DiagnosticInfo
    let includedSections: Set<DiagnosticInfo.SectionID>

    var availableSectionIDs: [DiagnosticInfo.SectionID] {
        diagnostics.availableSectionIDs(includeVerboseSections: true)
    }

    var activeSectionIDs: [DiagnosticInfo.SectionID] {
        availableSectionIDs.filter(includedSections.contains)
    }

    var inactiveSectionIDs: [DiagnosticInfo.SectionID] {
        availableSectionIDs.filter { !includedSections.contains($0) }
    }

    var includedSectionIDs: [String] {
        activeSectionIDs.map(\.rawValue)
    }

    var excludedSectionIDs: [String] {
        inactiveSectionIDs.map(\.rawValue)
    }

    var recentErrorsCount: Int {
        activeSectionIDs.contains(.recentErrors) ? diagnostics.recentErrors.count : 0
    }

    var recentLogsCount: Int {
        diagnostics.filteredRecentLogs(including: Set(activeSectionIDs)).count
    }

    func encode(to encoder: Encoder) throws {
        let activeSections = Set(activeSectionIDs)
        let filteredLogs = diagnostics.filteredRecentLogs(including: activeSections)

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(diagnostics.timestamp, forKey: .timestamp)
        try container.encode(includedSectionIDs, forKey: .includedSections)
        try container.encode(excludedSectionIDs, forKey: .excludedSections)

        if activeSections.contains(.appSystem) {
            try container.encode(diagnostics.appVersion, forKey: .appVersion)
            try container.encode(diagnostics.buildNumber, forKey: .buildNumber)
            try container.encode(diagnostics.macOSVersion, forKey: .macOSVersion)
            try container.encode(diagnostics.deviceModel, forKey: .deviceModel)
            try container.encode(diagnostics.totalDiskSpace, forKey: .totalDiskSpace)
            try container.encode(diagnostics.freeDiskSpace, forKey: .freeDiskSpace)
        }

        if activeSections.contains(.database) {
            try container.encode(diagnostics.databaseStats, forKey: .databaseStats)
        }

        if activeSections.contains(.settings) {
            try container.encode(diagnostics.settingsSnapshot, forKey: .settingsSnapshot)
        }

        if activeSections.contains(.recentErrors), !diagnostics.recentErrors.isEmpty {
            try container.encode(diagnostics.recentErrors, forKey: .recentErrors)
        }

        if !filteredLogs.isEmpty {
            try container.encode(filteredLogs, forKey: .recentLogs)
        }

        if activeSections.contains(.recentActions), !diagnostics.recentMetricEvents.isEmpty {
            try container.encode(diagnostics.recentMetricEvents, forKey: .recentMetricEvents)
        }

        if activeSections.contains(.displays) {
            try container.encode(diagnostics.displayInfo, forKey: .displayInfo)
        }

        if activeSections.contains(.runningApps) {
            try container.encode(diagnostics.processInfo, forKey: .processInfo)
        }

        if activeSections.contains(.accessibility) {
            try container.encode(diagnostics.accessibilityInfo, forKey: .accessibilityInfo)
        }

        if activeSections.contains(.performance) {
            try container.encode(diagnostics.performanceInfo, forKey: .performanceInfo)
        }

        if activeSections.contains(.emergencyCrashReports),
           let emergencyCrashReports = diagnostics.emergencyCrashReports,
           !emergencyCrashReports.isEmpty {
            try container.encode(emergencyCrashReports, forKey: .emergencyCrashReports)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case includedSections
        case excludedSections
        case appVersion
        case buildNumber
        case macOSVersion
        case deviceModel
        case totalDiskSpace
        case freeDiskSpace
        case databaseStats
        case settingsSnapshot
        case recentErrors
        case recentLogs
        case recentMetricEvents
        case displayInfo
        case processInfo
        case accessibilityInfo
        case performanceInfo
        case emergencyCrashReports
    }
}

private struct FeedbackExportEnvelope: Encodable {
    struct Metadata: Encodable {
        let description: String
        let exportFormatVersion: Int
        let generatedAt: Date
        let submissionEndpoint: String
        let launchSource: String
        let screenshotFileName: String?
        let screenshotByteCount: Int?
    }

    struct Report: Encodable {
        let type: String
        let email: String?
        let description: String
        let includeScreenshot: Bool
        let diagnostics: FilteredDiagnosticInfo
    }

    let metadata: Metadata
    let report: Report

    func prettyPrintedJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
