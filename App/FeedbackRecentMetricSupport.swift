import Foundation
import Database

public struct FeedbackRecentMetricEvent: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let metricType: String
    public let summary: String
    public let details: [String: String]

    public init(
        timestamp: Date,
        metricType: String,
        summary: String,
        details: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.metricType = metricType
        self.summary = summary
        self.details = details
    }
}

public struct FilteredSearchMetricMetadata: Codable, Sendable, Equatable {
    public let queryLength: Int
    public let filterCount: Int

    public init(queryLength: Int, filterCount: Int) {
        self.queryLength = max(0, queryLength)
        self.filterCount = max(0, filterCount)
    }

    var feedbackDetails: [String: String] {
        var details: [String: String] = [:]
        if queryLength > 0 {
            details["queryLength"] = "\(queryLength)"
        }
        if filterCount > 0 {
            details["filterCount"] = "\(filterCount)"
        }
        return details
    }
}

public struct TimelineFilterMetricMetadata: Codable, Sendable, Equatable {
    public let hasAppFilter: Bool
    public let hasWindowFilter: Bool
    public let hasURLFilter: Bool
    public let hasStartDate: Bool
    public let hasEndDate: Bool

    public init(
        hasAppFilter: Bool,
        hasWindowFilter: Bool,
        hasURLFilter: Bool,
        hasStartDate: Bool,
        hasEndDate: Bool
    ) {
        self.hasAppFilter = hasAppFilter
        self.hasWindowFilter = hasWindowFilter
        self.hasURLFilter = hasURLFilter
        self.hasStartDate = hasStartDate
        self.hasEndDate = hasEndDate
    }

    var feedbackDetails: [String: String] {
        [
            "hasAppFilter": hasAppFilter,
            "hasWindowFilter": hasWindowFilter,
            "hasURLFilter": hasURLFilter,
            "hasStartDate": hasStartDate,
            "hasEndDate": hasEndDate,
        ]
        .compactMapValues { $0 ? "true" : nil }
    }
}

enum FeedbackRecentMetricSupport {
    static let excludedMetricTypes: Set<DailyMetricsQueries.MetricType> = [
        .appLaunches,
        .feedbackReportExport,
        .helpOpened,
        .inPageURLHover,
        .mouseClickCapture,
        .phraseLevelRedactionQueuedHover,
        .arrowKeyNavigation,
        .keyboardShortcut,
        .scrubDistance,
        .searchDialogOpens,
        .settingsSearchOpened,
        .timelineOpens,
        .timelineSessionDuration,
    ]

    static func sanitize(
        _ events: [DailyMetricsQueries.RecentEvent],
        limit displayLimit: Int? = nil
    ) -> [FeedbackRecentMetricEvent] {
        let sanitizedEvents = noiseReducedEvents(from: events).map { event in
            FeedbackRecentMetricEvent(
                timestamp: event.timestamp,
                metricType: event.metricType.rawValue,
                summary: summary(for: event.metricType),
                details: sanitizedDetails(
                    for: event.metricType,
                    metadata: event.metadata
                )
            )
        }

        guard let displayLimit else {
            return sanitizedEvents
        }

        let boundedLimit = max(0, displayLimit)
        guard boundedLimit > 0 else {
            return []
        }

        return Array(sanitizedEvents.suffix(boundedLimit))
    }

    static func rawEventFetchLimit(forDisplayedLimit displayLimit: Int) -> Int {
        let boundedLimit = max(0, displayLimit)
        guard boundedLimit > 0 else {
            return 0
        }

        return min(max(boundedLimit * 4, boundedLimit + 100), 1_000)
    }

    private static func summary(
        for metricType: DailyMetricsQueries.MetricType
    ) -> String {
        switch metricType {
        case .searches:
            return "Search submitted"
        case .helpOpened:
            return "Help opened"
        case .settingsSearchOpened:
            return "Settings search opened"
        case .feedbackReportExport:
            return "Feedback report export"
        case .searchDialogOpens:
            return "Search dialog opened"
        case .filteredSearchQuery:
            return "Filtered search submitted"
        case .timelineFilterQuery:
            return "Timeline filter applied"
        case .quickCommentOpened:
            return "Quick comment opened"
        case .quickCommentClosed:
            return "Quick comment closed"
        case .quickCommentContextPreviewToggle:
            return "Quick comment context preview toggled"
        case .commentAdded:
            return "Comment added"
        case .ocrReprocessRequests:
            return "OCR refresh requested"
        case .captureIntervalUpdated:
            return "Capture interval updated"
        case .videoQualityUpdated:
            return "Video quality updated"
        case .dockMenuAction:
            return "Dock menu action"
        case .dockIconVisibilityToggle:
            return "Dock icon visibility toggled"
        case .masterKeyFlow:
            return "Master key flow action"
        default:
            return metricType.rawValue
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private static func sanitizedDetails(
        for metricType: DailyMetricsQueries.MetricType,
        metadata: String?
    ) -> [String: String] {
        guard let metadata, !metadata.isEmpty else { return [:] }

        switch metricType {
        case .searches:
            return searchDetails(from: metadata)
        case .timelineSessionDuration:
            return scalarDetails(label: "durationMs", value: metadata)
        case .scrubDistance:
            return scalarDetails(label: "distancePx", value: metadata)
        case .arrowKeyNavigation:
            return scalarDetails(label: "direction", value: metadata)
        case .keyboardShortcut:
            return scalarDetails(label: "shortcut", value: metadata)
        case .shiftDragTextCopy:
            return scalarDetails(label: "textLength", value: "\(metadata.count)")
        case .filteredSearchQuery:
            return filteredSearchDetails(from: metadata)
        case .timelineFilterQuery:
            return timelineFilterDetails(from: metadata)
        default:
            break
        }

        guard let payload = jsonObject(from: metadata) else {
            return [:]
        }

        switch metricType {
        case .inPageURLHover, .inPageURLClick, .inPageURLRightClick, .inPageURLCopyLink:
            return linkInteractionDetails(from: payload)
        case .timelineAutoDismissed:
            return allowlistedDetails(
                from: payload,
                keys: ["trigger"]
            )
        case .developerSettingToggle:
            return allowlistedDetails(
                from: payload,
                keys: ["source", "settingKey", "isEnabled"]
            )
        case .storageHealthBannerAction:
            return allowlistedDetails(
                from: payload,
                keys: ["action", "severity", "availableGB", "shouldStop"]
            )
        case .watchdogCrashBannerAction, .walFailureBannerAction:
            return allowlistedDetails(
                from: payload,
                keys: ["action", "reportAgeSeconds"]
            )
        case .phraseLevelRedactionQueuedHover:
            return allowlistedDetails(
                from: payload,
                keys: ["processingStatus"]
            )
        default:
            return allowlistedDetails(
                from: payload,
                keys: [
                    "source",
                    "action",
                    "outcome",
                    "trigger",
                    "status",
                    "feedbackType",
                    "button",
                    "gesture",
                    "mode",
                    "seconds",
                    "quality",
                    "enabled",
                    "isEnabled",
                    "isCollapsed",
                    "isRunning",
                    "appWasHidden",
                    "dashboardWasVisible",
                    "isInitialized",
                    "includeLogs",
                    "includeScreenshot",
                    "exportedFileCount",
                    "availableGB",
                    "shouldStop",
                    "severity",
                    "reportAgeSeconds",
                    "processingStatus",
                    "cutoffTimestampMs",
                ]
            )
        }
    }

    private static func filteredSearchDetails(
        from metadata: String
    ) -> [String: String] {
        if let payload = decode(FilteredSearchMetricMetadata.self, from: metadata) {
            return payload.feedbackDetails
        }

        guard let payload = jsonObject(from: metadata) else {
            return [:]
        }

        var details: [String: String] = [:]

        if let query = payload["query"] as? String, !query.isEmpty {
            details["queryLength"] = "\(query.count)"
        }

        if let filters = payload["filters"] as? [String: Any],
           !filters.isEmpty {
            details["filterCount"] = "\(filters.count)"
        }

        return details
    }

    private static func searchDetails(
        from metadata: String
    ) -> [String: String] {
        let trimmedQuery = metadata.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return [:]
        }

        return ["queryLength": "\(trimmedQuery.count)"]
    }

    private static func timelineFilterDetails(
        from metadata: String
    ) -> [String: String] {
        if let payload = decode(TimelineFilterMetricMetadata.self, from: metadata) {
            return payload.feedbackDetails
        }

        guard let payload = jsonObject(from: metadata) else {
            return [:]
        }

        let legacyDateRanges = payload["dateRanges"] as? [[String: Any]] ?? []
        return [
            "hasAppFilter": hasNonEmptyString(payload["bundleID"]) || hasNonEmptyValues(payload["bundleIDs"]),
            "hasWindowFilter": hasNonEmptyString(payload["windowName"]),
            "hasURLFilter": hasNonEmptyString(payload["browserUrl"]),
            "hasStartDate": hasNonEmptyString(payload["startDate"]) || legacyDateRanges.contains(where: { hasNonEmptyString($0["start"]) }),
            "hasEndDate": hasNonEmptyString(payload["endDate"]) || legacyDateRanges.contains(where: { hasNonEmptyString($0["end"]) }),
        ]
        .compactMapValues { $0 ? "true" : nil }
    }

    private static func linkInteractionDetails(
        from payload: [String: Any]
    ) -> [String: String] {
        [
            "hasURL": hasNonEmptyString(payload["url"]),
            "hasLinkText": hasNonEmptyString(payload["linkText"]),
        ]
        .compactMapValues { $0 ? "true" : nil }
    }

    private static func allowlistedDetails(
        from payload: [String: Any],
        keys: [String]
    ) -> [String: String] {
        var details: [String: String] = [:]

        for key in keys {
            guard let value = payload[key],
                  let sanitizedValue = sanitizeScalarValue(value) else {
                continue
            }
            details[key] = sanitizedValue
        }

        return details
    }

    private static func scalarDetails(
        label: String,
        value: String
    ) -> [String: String] {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return [:] }
        return [label: trimmedValue]
    }

    private static func jsonObject(
        from metadata: String
    ) -> [String: Any]? {
        guard let data = metadata.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let payload = object as? [String: Any] else {
            return nil
        }
        return payload
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from metadata: String
    ) -> T? {
        guard let data = metadata.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func sanitizeScalarValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }

            let doubleValue = number.doubleValue
            if floor(doubleValue) == doubleValue {
                return "\(number.int64Value)"
            }
            return String(doubleValue)
        default:
            return nil
        }
    }

    private static func noiseReducedEvents(
        from events: [DailyMetricsQueries.RecentEvent]
    ) -> [DailyMetricsQueries.RecentEvent] {
        let filteredEvents = events.filter { !excludedMetricTypes.contains($0.metricType) }
        guard !filteredEvents.isEmpty else {
            return []
        }

        var collapsedEvents: [DailyMetricsQueries.RecentEvent] = []
        for event in filteredEvents {
            guard let lastEvent = collapsedEvents.last else {
                collapsedEvents.append(event)
                continue
            }

            if shouldCollapse(event, into: lastEvent) {
                collapsedEvents[collapsedEvents.count - 1] = event
                continue
            }

            collapsedEvents.append(event)
        }

        return collapsedEvents
    }

    private static func shouldCollapse(
        _ event: DailyMetricsQueries.RecentEvent,
        into previousEvent: DailyMetricsQueries.RecentEvent
    ) -> Bool {
        guard event.metricType == previousEvent.metricType else {
            return false
        }

        switch event.metricType {
        case .timelineFilterQuery:
            return event.timestamp.timeIntervalSince(previousEvent.timestamp) <= 10 &&
                comparisonSignature(for: event) == comparisonSignature(for: previousEvent)
        default:
            return false
        }
    }

    private static func comparisonSignature(
        for event: DailyMetricsQueries.RecentEvent
    ) -> String {
        let details = sanitizedDetails(
            for: event.metricType,
            metadata: event.metadata
        )

        return details.keys.sorted().compactMap { key in
            guard let value = details[key] else {
                return nil
            }
            return "\(key)=\(value)"
        }
        .joined(separator: "|")
    }

    private static func hasNonEmptyString(_ value: Any?) -> Bool {
        guard let string = value as? String else { return false }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasNonEmptyValues(_ value: Any?) -> Bool {
        guard let values = value as? [Any] else { return false }
        return !values.isEmpty
    }
}
