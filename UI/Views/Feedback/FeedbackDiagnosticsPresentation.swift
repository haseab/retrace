import Foundation
import App

public extension DiagnosticInfo {
    enum SectionID: String, CaseIterable, Codable, Hashable, Identifiable {
        case appSystem = "app_system"
        case database = "database"
        case displays = "displays"
        case performance = "performance"
        case memorySummary = "retrace_memory_summary"
        case runningApps = "running_apps"
        case accessibility = "accessibility"
        case recentErrors = "recent_errors"
        case settings = "settings"
        case recentActions = "recent_actions"
        case emergencyCrashReports = "emergency_crash_reports"
        case fullLogs = "full_logs"

        public var id: String { rawValue }
    }

    struct SectionSummary: Identifiable {
        public let id: SectionID
        public let title: String
        public let reason: String
        public let countSummary: String?
        public let preview: String
        public let previewDisclosure: String?
    }

    /// Format as readable text for display (summary without full logs).
    /// Each section explains why this data helps diagnose the issue.
    func formattedText(including includedSections: Set<SectionID>? = nil) -> String {
        FeedbackDiagnosticsTextFormatter.format(
            sectionIDs: filteredSectionIDs(
                including: includedSections,
                includeVerboseSections: false
            ),
            diagnostics: self
        )
    }

    /// Full formatted text including all logs.
    func fullFormattedText(including includedSections: Set<SectionID>? = nil) -> String {
        FeedbackDiagnosticsTextFormatter.format(
            sectionIDs: filteredSectionIDs(
                including: includedSections,
                includeVerboseSections: true
            ),
            diagnostics: self
        )
    }

    func sectionSummaries(includeVerboseSections: Bool = true) -> [SectionSummary] {
        availableSectionIDs(includeVerboseSections: includeVerboseSections).map(sectionSummary(for:))
    }

    func availableSectionIDs(includeVerboseSections: Bool = true) -> [SectionID] {
        var sectionIDs: [SectionID] = [
            .appSystem,
            .database,
            .displays,
            .performance,
        ]

        if !memoryProfileEntries.isEmpty {
            sectionIDs.append(.memorySummary)
        }

        sectionIDs.append(.runningApps)
        sectionIDs.append(.accessibility)

        if !recentErrors.isEmpty {
            sectionIDs.append(.recentErrors)
        }

        if !settingsSnapshot.isEmpty {
            sectionIDs.append(.settings)
        }

        if !recentMetricEvents.isEmpty {
            sectionIDs.append(.recentActions)
        }

        if includeVerboseSections,
           let crashReports = emergencyCrashReports,
           !crashReports.isEmpty {
            sectionIDs.append(.emergencyCrashReports)
        }

        if includeVerboseSections, hasFullLogsContent {
            sectionIDs.append(.fullLogs)
        }

        return sectionIDs
    }

    func filteredRecentLogs(including includedSections: Set<SectionID>) -> [String] {
        let includeMemorySummary = includedSections.contains(.memorySummary)
        let includeFullLogs = includedSections.contains(.fullLogs)
        guard includeMemorySummary || includeFullLogs else {
            return []
        }

        let recentErrorEntries = Set(recentErrors)
        return recentLogs.filter { entry in
            let isMemoryProfile = Self.isMemoryProfileLog(entry)
            if recentErrorEntries.contains(entry) {
                return false
            }
            return (isMemoryProfile && includeMemorySummary) || (!isMemoryProfile && includeFullLogs)
        }
    }

    func filteredGroupedRecentLogs(including includedSections: Set<SectionID>) -> GroupedRecentLogs? {
        guard includedSections.contains(.fullLogs) else {
            return nil
        }

        return groupedRecentLogs
    }

    func filteredRecentLogEntryCount(including includedSections: Set<SectionID>) -> Int {
        var count = 0

        if includedSections.contains(.memorySummary) {
            count += memoryProfileEntries.count
        }

        if includedSections.contains(.fullLogs) {
            count += fullLogRepresentedEntryCount
        }

        return count
    }

    static func fullLogsPreviewDisclosureText() -> String {
        "Preview truncated. Download .json.gz below to inspect all included log entries from the last ~30 minutes."
    }
}

private extension DiagnosticInfo {
    static let feedbackMemoryProfileMarker = "[FeedbackMemoryProfile]"

    struct PreviewContent {
        let text: String
        let isTruncated: Bool
    }

    var memoryProfileEntries: [String] {
        recentLogs
            .filter(Self.isMemoryProfileLog)
            .map(Self.memoryProfileMessage)
    }

    var nonMemoryProfileLogs: [String] {
        let recentErrorEntries = Set(recentErrors)
        return recentLogs.filter { entry in
            !Self.isMemoryProfileLog(entry) && !recentErrorEntries.contains(entry)
        }
    }

    var hasFullLogsContent: Bool {
        !fullLogEntries.isEmpty
    }

    var fullLogRepresentedEntryCount: Int {
        nonMemoryProfileLogs.count + (groupedRecentLogs?.representedEntryCount ?? 0)
    }

    var fullLogEntries: [String] {
        var entries: [String] = []

        if let groupedRecentLogs,
           !groupedRecentLogs.groups.isEmpty {
            if let schemaLine = minifiedGroupedLogSchemaLine(groupedRecentLogs.schema) {
                entries.append(schemaLine)
            }

            entries.append(contentsOf: groupedRecentLogs.groups.compactMap(Self.minifiedJSONLine))

            if !nonMemoryProfileLogs.isEmpty {
                entries.append("--- RAW LOGS ---")
            }
        }

        entries.append(contentsOf: nonMemoryProfileLogs)
        return entries
    }

    static func isMemoryProfileLog(_ entry: String) -> Bool {
        entry.contains(feedbackMemoryProfileMarker)
    }

    static func memoryProfileMessage(from entry: String) -> String {
        guard let markerRange = entry.range(of: feedbackMemoryProfileMarker) else {
            return entry
        }

        let message = String(entry[markerRange.upperBound...]).trimmingCharacters(in: .newlines)
        if message.hasPrefix(" ") {
            return String(message.dropFirst())
        }
        return message
    }

    func filteredSectionIDs(
        including includedSections: Set<SectionID>?,
        includeVerboseSections: Bool
    ) -> [SectionID] {
        let sectionIDs = availableSectionIDs(includeVerboseSections: includeVerboseSections)
        guard let includedSections else {
            return sectionIDs
        }
        return sectionIDs.filter { includedSections.contains($0) }
    }

    func sectionSummary(for sectionID: SectionID) -> SectionSummary {
        let previewContent = previewContent(for: sectionID)
        return SectionSummary(
            id: sectionID,
            title: sectionTitle(for: sectionID),
            reason: sectionReason(for: sectionID),
            countSummary: countSummary(for: sectionID),
            preview: previewContent.text,
            previewDisclosure: previewDisclosure(for: sectionID, previewContent: previewContent)
        )
    }

    func previewDisclosure(
        for sectionID: SectionID,
        previewContent: PreviewContent
    ) -> String? {
        guard previewContent.isTruncated else { return nil }

        switch sectionID {
        case .fullLogs:
            return Self.fullLogsPreviewDisclosureText()
        case .appSystem,
             .database,
             .displays,
             .performance,
             .memorySummary,
             .runningApps,
             .accessibility,
             .recentErrors,
             .settings,
             .recentActions,
             .emergencyCrashReports:
            return "Preview truncated. Download .json.gz below to inspect the full contents."
        }
    }

    func sectionTitle(for sectionID: SectionID) -> String {
        switch sectionID {
        case .appSystem:
            return "App & System"
        case .database:
            return "Database"
        case .displays:
            return "Displays"
        case .performance:
            return "Performance"
        case .memorySummary:
            return "Retrace Memory Summary"
        case .runningApps:
            return "Running Apps"
        case .accessibility:
            return "Accessibility"
        case .recentErrors:
            return "Recent Errors"
        case .settings:
            return "Settings"
        case .recentActions:
            return "Recent Actions"
        case .emergencyCrashReports:
            return "Emergency Crash Reports"
        case .fullLogs:
            return "Full Logs"
        }
    }

    func formattedHeading(for sectionID: SectionID) -> String {
        switch sectionID {
        case .appSystem:
            return "APP & SYSTEM"
        case .database:
            return "DATABASE"
        case .displays:
            return "DISPLAYS (\(displayInfo.count))"
        case .performance:
            return "PERFORMANCE"
        case .memorySummary:
            return "RETRACE MEMORY SUMMARY"
        case .runningApps:
            return "RUNNING APPS"
        case .accessibility:
            return "ACCESSIBILITY"
        case .recentErrors:
            return "RECENT ERRORS (\(recentErrors.count))"
        case .settings:
            return "SETTINGS"
        case .recentActions:
            return "RECENT ACTIONS (\(recentMetricEvents.count))"
        case .emergencyCrashReports:
            return "EMERGENCY CRASH REPORTS"
        case .fullLogs:
            return "FULL LOGS (last ~30 minutes)"
        }
    }

    func sectionReason(for sectionID: SectionID) -> String {
        switch sectionID {
        case .appSystem:
            return "Identifies your build and hardware so we can match against known issues."
        case .database:
            return "Helps diagnose data corruption, retention, and storage pressure issues."
        case .displays:
            return "Needed to reproduce scaling, color space, and multi-monitor rendering bugs."
        case .performance:
            return "Distinguishes app bugs from system resource pressure."
        case .memorySummary:
            return "Hierarchical breakdown from the system monitor sampler included with this report."
        case .runningApps:
            return "Detects tools that commonly interfere with screen capture and accessibility."
        case .accessibility:
            return "These OS settings directly affect rendering and compositing behavior."
        case .recentErrors:
            return "Recent error-level entries may indicate the root cause."
        case .settings:
            return "Whitelisted behavioral toggles and thresholds that help reproduce misconfiguration issues."
        case .recentActions:
            return "Relevant recent daily-metrics events with limited metadata, filtered to avoid noisy telemetry."
        case .emergencyCrashReports:
            return "Auto-captured when the app was frozen and included only with your permission."
        case .fullLogs:
            return "High-volume log families are compacted into exact columnar JSON blocks before raw one-off logs."
        }
    }

    func countSummary(for sectionID: SectionID) -> String? {
        switch sectionID {
        case .displays:
            let count = displayInfo.count
            return "\(count) display\(count == 1 ? "" : "s")"
        case .memorySummary:
            let count = memoryProfileEntries.count
            return "\(count) entr\(count == 1 ? "y" : "ies")"
        case .recentErrors:
            let count = recentErrors.count
            return "\(count) error\(count == 1 ? "" : "s")"
        case .settings:
            let count = settingsSnapshot.count
            return "\(count) key\(count == 1 ? "" : "s")"
        case .recentActions:
            let count = recentMetricEvents.count
            return "\(count) event\(count == 1 ? "" : "s")"
        case .emergencyCrashReports:
            let count = emergencyCrashReports?.count ?? 0
            return "\(count) report\(count == 1 ? "" : "s")"
        case .fullLogs:
            let count = fullLogRepresentedEntryCount
            return "\(count) log entr\(count == 1 ? "y" : "ies")"
        case .appSystem, .database, .performance, .runningApps, .accessibility:
            return nil
        }
    }

    func isDetailSection(_ sectionID: SectionID) -> Bool {
        switch sectionID {
        case .emergencyCrashReports, .fullLogs:
            return true
        case .appSystem, .database, .displays, .performance, .memorySummary, .runningApps, .accessibility, .recentErrors, .settings, .recentActions:
            return false
        }
    }

    func sectionBody(for sectionID: SectionID) -> String {
        switch sectionID {
        case .appSystem:
            return [
                "App Version: \(appVersion) (\(buildNumber))",
                "macOS: \(macOSVersion)",
                "Device: \(deviceModel)",
                "Disk: \(freeDiskSpace) free of \(totalDiskSpace)",
            ].joined(separator: "\n")
        case .database:
            return [
                "Sessions: \(databaseStats.sessionCount)",
                "Frames: \(databaseStats.frameCount)",
                "Segments: \(databaseStats.segmentCount)",
                "Size: \(String(format: "%.1f", databaseStats.databaseSizeMB)) MB",
            ].joined(separator: "\n")
        case .displays:
            return displaySectionBody
        case .performance:
            return performanceSectionBody
        case .memorySummary:
            return memoryProfileEntries.joined(separator: "\n")
        case .runningApps:
            return runningAppsSectionBody
        case .accessibility:
            return accessibilitySectionBody
        case .recentErrors:
            return recentErrors.joined(separator: "\n")
        case .settings:
            return settingsSnapshot.keys.sorted().compactMap { key in
                settingsSnapshot[key].map { "\(key): \($0)" }
            }.joined(separator: "\n")
        case .recentActions:
            return recentMetricEvents
                .map(FeedbackDiagnosticsTextFormatter.recentMetricLine)
                .joined(separator: "\n")
        case .emergencyCrashReports:
            return (emergencyCrashReports ?? []).joined(separator: "\n---\n")
        case .fullLogs:
            return fullLogEntries.joined(separator: "\n")
        }
    }

    func previewContent(for sectionID: SectionID) -> PreviewContent {
        switch sectionID {
        case .memorySummary:
            return previewContent(
                from: memoryProfileEntries,
                lineLimit: 4,
                characterLimit: 260
            )
        case .recentActions:
            return previewContent(
                from: recentMetricEvents.map(FeedbackDiagnosticsTextFormatter.recentMetricLine),
                lineLimit: 4,
                characterLimit: 260
            )
        case .emergencyCrashReports:
            return crashReportsPreviewContent()
        case .fullLogs:
            return fullLogsPreviewContent()
        case .appSystem, .database, .displays, .performance, .runningApps, .accessibility, .recentErrors, .settings:
            return previewContent(
                from: sectionBody(for: sectionID).components(separatedBy: .newlines),
                lineLimit: 8,
                characterLimit: 420
            )
        }
    }

    func previewContent(
        from lines: [String],
        lineLimit: Int,
        characterLimit: Int,
        overflowText: ((Int) -> String)? = nil
    ) -> PreviewContent {
        let trimmedLines = lines.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }

        guard !trimmedLines.isEmpty else {
            return PreviewContent(text: "No data captured.", isTruncated: false)
        }

        let limitedLines = Array(trimmedLines.prefix(lineLimit))
        var preview = limitedLines.joined(separator: "\n")
        let wasCharacterTruncated = preview.count > characterLimit
        if wasCharacterTruncated {
            preview = String(preview.prefix(characterLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let remainingLineCount = max(trimmedLines.count - limitedLines.count, 0)
        if remainingLineCount > 0 {
            if let overflowText {
                return PreviewContent(
                    text: preview + "\n… " + overflowText(remainingLineCount),
                    isTruncated: true
                )
            }
            return PreviewContent(
                text: preview + "\n… \(remainingLineCount) more line\(remainingLineCount == 1 ? "" : "s")",
                isTruncated: true
            )
        }

        if wasCharacterTruncated {
            return PreviewContent(
                text: preview + "\n… truncated",
                isTruncated: true
            )
        }

        return PreviewContent(text: preview, isTruncated: false)
    }

    func fullLogsPreviewContent() -> PreviewContent {
        previewContent(
            from: fullLogEntries,
            lineLimit: 4,
            characterLimit: 260,
            overflowText: { remainingCount in
                "\(remainingCount) more log entr\(remainingCount == 1 ? "y" : "ies") in the downloadable .json.gz report"
            }
        )
    }

    func minifiedGroupedLogSchemaLine(
        _ schema: [String: GroupedRecentLogs.SchemaEntry]
    ) -> String? {
        Self.minifiedJSONLine(GroupedLogSchemaEnvelope(logSchema: schema))
    }

    static func minifiedJSONLine<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(value) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    func crashReportsPreviewContent() -> PreviewContent {
        guard let crashReports = emergencyCrashReports, !crashReports.isEmpty else {
            return PreviewContent(text: "No crash reports captured.", isTruncated: false)
        }

        let firstReportPreview = previewContent(
            from: crashReports[0].components(separatedBy: .newlines),
            lineLimit: 6,
            characterLimit: 320
        )

        let remainingReportCount = crashReports.count - 1
        guard remainingReportCount > 0 else {
            return firstReportPreview
        }

        return PreviewContent(
            text: firstReportPreview.text + "\n… plus \(remainingReportCount) more report\(remainingReportCount == 1 ? "" : "s")",
            isTruncated: true
        )
    }

    var displaySectionBody: String {
        guard !displayInfo.displays.isEmpty else {
            return "No display information captured."
        }

        return displayInfo.displays.map { display in
            let mainTag = display.index == displayInfo.mainDisplayIndex ? " <- MAIN" : ""
            return "[\(display.index)] \(display.resolution) @\(display.backingScaleFactor)x\(display.isRetina ? " Retina" : "") \(display.refreshRate) \(display.colorSpace) \(display.frame)\(mainTag)"
        }.joined(separator: "\n")
    }

    var performanceSectionBody: String {
        var lines = [
            "CPU: \(String(format: "%.1f", performanceInfo.cpuUsagePercent))%",
            "Memory: \(String(format: "%.1f", performanceInfo.memoryUsedGB)) GB / \(String(format: "%.1f", performanceInfo.memoryTotalGB)) GB (\(performanceInfo.memoryPressure))",
            "Swap: \(String(format: "%.1f", performanceInfo.swapUsedGB)) GB",
            "Thermal: \(performanceInfo.thermalState)",
            "Power: \(performanceInfo.powerSource)",
            "Low Power Mode: \(performanceInfo.isLowPowerModeEnabled)",
            "Processors: \(performanceInfo.processorCount)",
        ]

        if let battery = performanceInfo.batteryLevel {
            lines[4] += " (\(battery)%)"
        }

        return lines.joined(separator: "\n")
    }

    var runningAppsSectionBody: String {
        var lines = ["Total: \(processInfo.totalRunning)"]

        if processInfo.eventMonitoringApps > 0 {
            lines.append("Event Monitoring: \(processInfo.eventMonitoringApps)")
        }
        if processInfo.windowManagementApps > 0 {
            lines.append("Window Management: \(processInfo.windowManagementApps)")
        }
        if processInfo.securityApps > 0 {
            lines.append("Security/MDM: \(processInfo.securityApps)")
        }
        if processInfo.hasJamf {
            lines.append("Jamf: detected")
        }
        if processInfo.hasKandji {
            lines.append("Kandji: detected")
        }
        if processInfo.axuiServerCPU > 1.0 {
            lines.append("AXUIServer CPU: \(String(format: "%.1f", processInfo.axuiServerCPU))%")
        }
        if processInfo.windowServerCPU > 5.0 {
            lines.append("WindowServer CPU: \(String(format: "%.1f", processInfo.windowServerCPU))%")
        }

        if lines.count == 1 {
            lines.append("No known screen-capture interference tools detected in the local allowlist.")
        }

        return lines.joined(separator: "\n")
    }

    var accessibilitySectionBody: String {
        let enabledFeatures = [
            ("VoiceOver", accessibilityInfo.voiceOverEnabled),
            ("SwitchControl", accessibilityInfo.switchControlEnabled),
            ("ReduceMotion", accessibilityInfo.reduceMotionEnabled),
            ("IncreaseContrast", accessibilityInfo.increaseContrastEnabled),
            ("ReduceTransparency", accessibilityInfo.reduceTransparencyEnabled),
            ("DifferentiateWithoutColor", accessibilityInfo.differentiateWithoutColorEnabled),
            ("InvertColors", accessibilityInfo.displayHasInvertedColors),
        ]
        .filter(\.1)
        .map(\.0)

        guard !enabledFeatures.isEmpty else {
            return "No enabled accessibility display overrides detected."
        }

        return enabledFeatures.joined(separator: "\n")
    }
}

private struct GroupedLogSchemaEnvelope: Encodable {
    let logSchema: [String: DiagnosticInfo.GroupedRecentLogs.SchemaEntry]

    private enum CodingKeys: String, CodingKey {
        case logSchema = "log_schema"
    }
}

private enum FeedbackDiagnosticsTextFormatter {
    private static let recentMetricFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func format(
        sectionIDs: [DiagnosticInfo.SectionID],
        diagnostics: DiagnosticInfo
    ) -> String {
        guard !sectionIDs.isEmpty else {
            return "No diagnostic sections selected."
        }

        return sectionIDs.map { sectionID in
            let header: String
            if diagnostics.isDetailSection(sectionID) {
                header = "--- \(diagnostics.formattedHeading(for: sectionID)) ---"
            } else {
                header = "=== \(diagnostics.formattedHeading(for: sectionID)) ==="
            }

            return [
                header,
                "(\(diagnostics.sectionReason(for: sectionID)))",
                diagnostics.sectionBody(for: sectionID),
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func recentMetricLine(_ event: FeedbackRecentMetricEvent) -> String {
        let detailsText = event.details.keys.sorted().compactMap { key in
            event.details[key].map { "\(key)=\($0)" }
        }.joined(separator: ", ")

        let base = "[\(recentMetricFormatter.string(from: event.timestamp))] \(event.summary)"
        guard !detailsText.isEmpty else {
            return base
        }
        return "\(base) (\(detailsText))"
    }
}
