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
        let exportDiagnostics = FilteredDiagnosticInfo(
            diagnostics: diagnostics,
            includedSections: includedDiagnosticSections
        )

        let payload = FeedbackExportEnvelope(
            metadata: FeedbackExportEnvelope.Metadata(
                description: "Manual export",
                exportFormatVersion: 4,
                generatedAt: generatedAt,
                submissionEndpoint: "https://retrace.to/api/feedback",
                launchSource: launchSource?.rawValue ?? FeedbackLaunchContext.Source.manual.rawValue,
                screenshotFileName: screenshotFileName,
                screenshotByteCount: screenshotData?.count
            ),
            report: FeedbackExportEnvelope.Report(
                feedback: FeedbackExportEnvelope.Report.Feedback(
                    type: type,
                    email: email,
                    description: description,
                    includeScreenshot: includeScreenshot
                ),
                diagnostics: HierarchicalDiagnosticInfo(filteredDiagnostics: exportDiagnostics)
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return json
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

    init(
        diagnostics: DiagnosticInfo,
        includedSections: Set<DiagnosticInfo.SectionID>
    ) {
        self.diagnostics = diagnostics
        self.includedSections = includedSections
    }

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

    func encode(to encoder: Encoder) throws {
        let activeSections = Set(activeSectionIDs)
        let filteredLogs = diagnostics.filteredRecentLogs(including: activeSections)
        let groupedLogs = diagnostics.filteredGroupedRecentLogs(including: activeSections)

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

        if let groupedLogs,
           !groupedLogs.schema.isEmpty {
            try container.encode(groupedLogs.schema, forKey: .recentLogSchema)
        }

        if let groupedLogs,
           !groupedLogs.groups.isEmpty {
            try container.encode(groupedLogs.groups, forKey: .recentLogGroups)
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
        case recentLogSchema
        case recentLogGroups
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
        struct Feedback: Encodable {
            let type: String
            let email: String?
            let description: String
            let includeScreenshot: Bool
        }

        let feedback: Feedback
        let diagnostics: HierarchicalDiagnosticInfo
    }

    let metadata: Metadata
    let report: Report
}

private struct HierarchicalDiagnosticInfo: Encodable {
    struct Summary: Encodable {
        struct Counts: Encodable {
            let memorySummaryEntries: Int
            let recentErrors: Int
            let recentActions: Int
            let emergencyCrashReports: Int
            let fullLogEntries: Int
        }

        let capturedAt: Date
        let includedSectionIDs: [String]
        let excludedSectionIDs: [String]
        let sectionOrder: [String]
        let sectionCount: Int
        let excludedSectionCount: Int
        let counts: Counts
    }

    let filteredDiagnostics: FilteredDiagnosticInfo

    func encode(to encoder: Encoder) throws {
        let diagnostics = filteredDiagnostics.diagnostics
        let activeSectionIDs = filteredDiagnostics.activeSectionIDs
        let activeSectionSet = Set(activeSectionIDs)

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            Summary(
                capturedAt: diagnostics.timestamp,
                includedSectionIDs: filteredDiagnostics.includedSectionIDs,
                excludedSectionIDs: filteredDiagnostics.excludedSectionIDs,
                sectionOrder: activeSectionIDs.map(\.rawValue),
                sectionCount: filteredDiagnostics.includedSectionIDs.count,
                excludedSectionCount: filteredDiagnostics.excludedSectionIDs.count,
                counts: Summary.Counts(
                    memorySummaryEntries: activeSectionSet.contains(.memorySummary)
                        ? diagnostics.filteredRecentLogs(including: [.memorySummary]).count
                        : 0,
                    recentErrors: activeSectionSet.contains(.recentErrors)
                        ? diagnostics.recentErrors.count
                        : 0,
                    recentActions: activeSectionSet.contains(.recentActions)
                        ? diagnostics.recentMetricEvents.count
                        : 0,
                    emergencyCrashReports: activeSectionSet.contains(.emergencyCrashReports)
                        ? (diagnostics.emergencyCrashReports?.count ?? 0)
                        : 0,
                    fullLogEntries: activeSectionSet.contains(.fullLogs)
                        ? diagnostics.filteredRecentLogEntryCount(including: [.fullLogs])
                        : 0
                )
            ),
            forKey: .summary
        )

        var sectionsContainer = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .sections)

        for sectionID in activeSectionIDs {
            let key = DynamicCodingKey(sectionID.rawValue)

            switch sectionID {
            case .appSystem:
                try sectionsContainer.encode(
                    AppSystemSectionData(
                        appVersion: diagnostics.appVersion,
                        buildNumber: diagnostics.buildNumber,
                        macOSVersion: diagnostics.macOSVersion,
                        deviceModel: diagnostics.deviceModel,
                        disk: AppSystemSectionData.Disk(
                            total: diagnostics.totalDiskSpace,
                            free: diagnostics.freeDiskSpace
                        )
                    ),
                    forKey: key
                )
            case .database:
                try sectionsContainer.encode(diagnostics.databaseStats, forKey: key)
            case .displays:
                try sectionsContainer.encode(diagnostics.displayInfo, forKey: key)
            case .performance:
                try sectionsContainer.encode(diagnostics.performanceInfo, forKey: key)
            case .memorySummary:
                try sectionsContainer.encode(
                    LogEntriesSectionData(entries: diagnostics.filteredRecentLogs(including: [.memorySummary])),
                    forKey: key
                )
            case .runningApps:
                try sectionsContainer.encode(diagnostics.processInfo, forKey: key)
            case .accessibility:
                try sectionsContainer.encode(diagnostics.accessibilityInfo, forKey: key)
            case .recentErrors:
                try sectionsContainer.encode(
                    LogEntriesSectionData(entries: diagnostics.recentErrors),
                    forKey: key
                )
            case .settings:
                try sectionsContainer.encode(
                    SettingsSectionData(values: diagnostics.settingsSnapshot),
                    forKey: key
                )
            case .recentActions:
                try sectionsContainer.encode(
                    RecentActionsSectionData(events: diagnostics.recentMetricEvents),
                    forKey: key
                )
            case .emergencyCrashReports:
                try sectionsContainer.encode(
                    EmergencyCrashReportsSectionData(reports: diagnostics.emergencyCrashReports ?? []),
                    forKey: key
                )
            case .fullLogs:
                let groupedLogs = diagnostics.filteredGroupedRecentLogs(including: [.fullLogs])
                let rawEntries = diagnostics.filteredRecentLogs(including: [.fullLogs])
                let encodedRawLogs = encodeRawLogPayload(rawEntries)
                try sectionsContainer.encode(
                    FullLogsSectionData(
                        counts: FullLogsSectionData.Counts(
                            representedEntries: diagnostics.filteredRecentLogEntryCount(including: [.fullLogs]),
                            rawEntries: rawEntries.count,
                            groupedEntries: groupedLogs?.representedEntryCount ?? 0,
                            groupedFamilies: groupedLogs?.groups.count ?? 0
                        ),
                        rawEncoding: encodedRawLogs.encoding,
                        rawData: encodedRawLogs.data,
                        grouped: groupedLogs,
                        recentErrorsStoredSeparately: true
                    ),
                    forKey: key
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case sections
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(_ stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }
}

private func encodeRawLogPayload(_ rawEntries: [String]) -> (encoding: FullLogsSectionData.RawEncoding, data: String) {
    let rawText = rawEntries.joined(separator: "\n")
    let utf8Data = Data(rawText.utf8)
    guard !utf8Data.isEmpty else {
        return (.gzipBase64UTF8, "")
    }

    if let compressed = try? FeedbackService.gzipCompress(utf8Data) {
        return (.gzipBase64UTF8, compressed.base64EncodedString())
    }

    return (.base64UTF8, utf8Data.base64EncodedString())
}

private struct AppSystemSectionData: Encodable {
    struct Disk: Encodable {
        let total: String
        let free: String
    }

    let appVersion: String
    let buildNumber: String
    let macOSVersion: String
    let deviceModel: String
    let disk: Disk
}

private struct LogEntriesSectionData: Encodable {
    let entries: [String]
}

private struct SettingsSectionData: Encodable {
    let values: [String: String]
}

private struct RecentActionsSectionData: Encodable {
    let events: [FeedbackRecentMetricEvent]
}

private struct EmergencyCrashReportsSectionData: Encodable {
    let reports: [String]
}

private struct FullLogsSectionData: Encodable {
    enum RawEncoding: String, Encodable {
        case gzipBase64UTF8 = "gzip_base64_utf8"
        case base64UTF8 = "base64_utf8"
    }

    struct Counts: Encodable {
        let representedEntries: Int
        let rawEntries: Int
        let groupedEntries: Int
        let groupedFamilies: Int
    }

    let counts: Counts
    let rawEncoding: RawEncoding
    let rawData: String
    let grouped: DiagnosticInfo.GroupedRecentLogs?
    let recentErrorsStoredSeparately: Bool
}
