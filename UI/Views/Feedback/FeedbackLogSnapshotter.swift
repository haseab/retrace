import Foundation
import Shared

extension FeedbackService {
    private static let excludedFeedbackMessagePrefixes: [String] = [
        "[Pipeline-Memory]",
        "Closed segment:",
        "[Filter] ====== QUERY DEBUG START ======",
        "[Filter] Query SQL:",
        "[Filter] Apps filter:",
        "[Filter] Tags to filter:",
        "[Filter] Hidden filter:",
        "[Filter] Window name filter:",
        "[Filter] Browser URL filter:",
        "[Filter] Date ranges:",
        "[Filter] Binding ",
        "[Queue-Memory]",
        "[Queue-TIMING]",
        "[Queue-Rewrite]",
        "[Search-Memory]",
        "[VideoView] Released decoder resources",
        "[ZoomedTextSelectionNSView] updateNSView called",
        "[ZoomDismiss] ZoomUnifiedOverlay rendered",
        "[Timeline-Memory]",
        "[Memory]",
        "[SimpleTimelineViewModel] currentVideoInfo:",
        "[PhraseRedaction][UI]",
        "refreshRecentEntriesPopoverVisibility",
        "search field focused",
        "performFocus",
        "[StorageHealth]",
        "[VideoExtract] Invalidated stale cache",
        "[TimelineToggle]",
        "[TIMELINE-SHOW]",
        "[TIMELINE-FOCUS]",
        "[TIMELINE-REOPEN]",
        "[TIMELINE-PRERENDER]"
    ]
    private static let excludedFeedbackMessageContains: [String] = [
        "AX observer set up for",
        "frame processing paused",
        "frame processing resumed",
        "Purged frame extraction caches",
        "Purged video decoding caches"
    ]
    private static let droppedFeedbackMessagePrefixes: [String] = [
        "[Queue-DIAG]"
    ]
    private static let feedbackLogTailChunkSize = 64 * 1024

    // MARK: - Memory Spike Diagnostics

    static func filteredFeedbackLogEntries(_ entries: [String]) -> [String] {
        entries.filter { entry in
            switch feedbackLogDisposition(for: entry) {
            case .exclude, .drop:
                return false
            case .error, .grouped, .raw:
                return true
            }
        }
    }

    static func readRecentFeedbackLogEntries(
        maxCount: Int,
        fileURL: URL = URL(fileURLWithPath: Log.logFilePath)
    ) -> [String] {
        guard maxCount > 0 else {
            return []
        }

        var retained: [String] = []
        retained.reserveCapacity(maxCount)
        enumerateFeedbackLogLinesInReverse(fileURL: fileURL) { line in
            guard !isExcludedFeedbackLogEntry(line) else {
                return false
            }

            retained.append(line)
            return retained.count == maxCount
        }

        return retained.reversed()
    }

    struct FeedbackLogSnapshotResult {
        let retainedLogs: [String]
        let groupedLogs: DiagnosticInfo.GroupedRecentLogs?
        let recentErrors: [String]
    }

    static func collectFeedbackLogSnapshot(
        rawLimit: Int,
        fileURL: URL = URL(fileURLWithPath: Log.logFilePath),
        groupedLimitPerFamily: Int = FeedbackService.groupedFeedbackLogLimitPerFamily
    ) -> (retainedLogs: [String], groupedLogs: DiagnosticInfo.GroupedRecentLogs?) {
        let result = collectFeedbackLogSnapshotWithErrors(
            rawLimit: rawLimit,
            fileURL: fileURL,
            groupedLimitPerFamily: groupedLimitPerFamily,
            errorLimit: 0
        )
        return (result.retainedLogs, result.groupedLogs)
    }

    static func collectFeedbackLogSnapshotWithErrors(
        rawLimit: Int,
        fileURL: URL = URL(fileURLWithPath: Log.logFilePath),
        groupedLimitPerFamily: Int = FeedbackService.groupedFeedbackLogLimitPerFamily,
        errorLimit: Int
    ) -> FeedbackLogSnapshotResult {
        collectFeedbackLogSnapshotDetailed(
            rawLimit: rawLimit,
            fileURL: fileURL,
            groupedLimitPerFamily: groupedLimitPerFamily,
            errorLimit: errorLimit
        )
    }

    private static func collectFeedbackLogSnapshotDetailed(
        rawLimit: Int,
        fileURL: URL = URL(fileURLWithPath: Log.logFilePath),
        groupedLimitPerFamily: Int = FeedbackService.groupedFeedbackLogLimitPerFamily,
        errorLimit: Int
    ) -> FeedbackLogSnapshotResult {
        let sanitizedRawLimit = max(0, rawLimit)
        let sanitizedErrorLimit = max(0, errorLimit)
        let sanitizedGroupedLimitPerFamily = max(0, groupedLimitPerFamily)

        if sanitizedRawLimit == 0 && sanitizedErrorLimit == 0 && sanitizedGroupedLimitPerFamily == 0 {
            return FeedbackLogSnapshotResult(
                retainedLogs: [],
                groupedLogs: nil,
                recentErrors: []
            )
        }

        var retainedLogsReversed: [String] = []
        retainedLogsReversed.reserveCapacity(sanitizedRawLimit)
        var recentErrorsReversed: [String] = []
        recentErrorsReversed.reserveCapacity(sanitizedErrorLimit)
        var groupedEntriesReversed: [HighVolumeLogKind: [ParsedHighVolumeLogEntry]] = [:]

        enumerateFeedbackLogLinesInReverse(fileURL: fileURL) { entry in
            let parsedLine = parseFeedbackLogLine(entry)

            let excludedByMarker = isExcludedFeedbackMessage(
                parsedLine.message,
                category: parsedLine.category
            )
            if excludedByMarker {
                return false
            }

            let excludedBySQL = isExcludedSQLFragmentFeedbackLogEntry(entry)
            if excludedBySQL {
                return false
            }

            let isDroppedMarker = isDroppedFeedbackMessage(parsedLine.message)
            if isDroppedMarker {
                return false
            }

            let isErrorEntry = isFeedbackErrorLogLevel(parsedLine.level)
            if isErrorEntry {
                if recentErrorsReversed.count < sanitizedErrorLimit {
                    recentErrorsReversed.append(entry)
                }

                let rawFilled = sanitizedRawLimit == 0 || retainedLogsReversed.count >= sanitizedRawLimit
                let errorsFilled = sanitizedErrorLimit == 0 || recentErrorsReversed.count >= sanitizedErrorLimit
                return rawFilled && errorsFilled
            }

            let parsedEntry = parseHighVolumeLogEntry(parsedLine)
            if let parsedEntry {
                var entries = groupedEntriesReversed[parsedEntry.kind, default: []]
                if entries.count < sanitizedGroupedLimitPerFamily {
                    entries.append(parsedEntry)
                    groupedEntriesReversed[parsedEntry.kind] = entries
                }
            } else if retainedLogsReversed.count < sanitizedRawLimit {
                retainedLogsReversed.append(entry)
            }

            let rawFilled = sanitizedRawLimit == 0 || retainedLogsReversed.count >= sanitizedRawLimit
            let errorsFilled = sanitizedErrorLimit == 0 || recentErrorsReversed.count >= sanitizedErrorLimit
            return rawFilled && errorsFilled
        }

        let retainedLogs = Array(retainedLogsReversed.reversed())
        let recentErrors = Array(recentErrorsReversed.reversed())

        let groups = HighVolumeLogKind.allCases.compactMap { kind -> DiagnosticInfo.GroupedRecentLogs.Group? in
            guard let entries = groupedEntriesReversed[kind],
                  !entries.isEmpty else {
                return nil
            }

            return buildHighVolumeLogGroup(
                eventCode: kind.code,
                entries: Array(entries.reversed())
            )
        }

        guard !groups.isEmpty else {
            return FeedbackLogSnapshotResult(
                retainedLogs: retainedLogs,
                groupedLogs: nil,
                recentErrors: recentErrors
            )
        }

        let schema: [String: DiagnosticInfo.GroupedRecentLogs.SchemaEntry] = Dictionary(
            uniqueKeysWithValues: HighVolumeLogKind.allCases.compactMap { kind in
                guard groupedEntriesReversed[kind]?.isEmpty == false else {
                    return nil
                }

                return (kind.code, kind.schema)
            }
        )

        return FeedbackLogSnapshotResult(
            retainedLogs: retainedLogs,
            groupedLogs: DiagnosticInfo.GroupedRecentLogs(
                schema: schema,
                groups: groups
            ),
            recentErrors: recentErrors
        )
    }

    private static func enumerateFeedbackLogLinesInReverse(
        fileURL: URL,
        stopWhen shouldStop: (String) -> Bool
    ) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return
        }
        defer {
            try? handle.close()
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let sizeNumber = attributes[.size] as? NSNumber else {
            return
        }

        var offset = sizeNumber.uint64Value
        guard offset > 0 else {
            return
        }

        var trailingFragment = Data()

        while offset > 0 {
            let chunkSize = min(UInt64(feedbackLogTailChunkSize), offset)
            let chunkStart = offset - chunkSize

            do {
                try handle.seek(toOffset: chunkStart)
            } catch {
                return
            }

            guard let chunk = try? handle.read(upToCount: Int(chunkSize)),
                  !chunk.isEmpty else {
                return
            }

            var buffer = Data()
            buffer.reserveCapacity(chunk.count + trailingFragment.count)
            buffer.append(chunk)
            if !trailingFragment.isEmpty {
                buffer.append(trailingFragment)
            }

            let segments = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
            let completeSegments: ArraySlice<Data.SubSequence>

            if chunkStart > 0 {
                trailingFragment = Data(segments.first ?? Data())
                completeSegments = segments.dropFirst()
            } else {
                trailingFragment.removeAll(keepingCapacity: true)
                completeSegments = segments[...]
            }

            for segment in completeSegments.reversed() {
                var lineData = segment
                if lineData.last == 0x0D {
                    lineData = lineData.dropLast()
                }

                guard !lineData.isEmpty else {
                    continue
                }

                // Decode each line lossily so an in-flight multibyte write only affects the
                // damaged line instead of dropping the full feedback log tail.
                let line = String(decoding: lineData, as: UTF8.self)
                if shouldStop(line) {
                    return
                }
            }

            offset = chunkStart
        }
    }

    static func compactFeedbackLogEntries(
        _ entries: [String],
        limitPerGroup: Int = FeedbackService.groupedFeedbackLogLimitPerFamily
    ) -> (retainedLogs: [String], groupedLogs: DiagnosticInfo.GroupedRecentLogs?) {
        var retainedLogs: [String] = []
        var groupedEntries: [HighVolumeLogKind: [ParsedHighVolumeLogEntry]] = [:]

        for entry in entries {
            switch feedbackLogDisposition(for: entry) {
            case .exclude, .drop, .error:
                continue
            case let .grouped(parsedEntry):
                groupedEntries[parsedEntry.kind, default: []].append(parsedEntry)
            case .raw:
                retainedLogs.append(entry)
            }
        }

        let groups = HighVolumeLogKind.allCases.compactMap { kind -> DiagnosticInfo.GroupedRecentLogs.Group? in
            guard let entries = groupedEntries[kind],
                  !entries.isEmpty else {
                return nil
            }

            return buildHighVolumeLogGroup(
                eventCode: kind.code,
                entries: Array(entries.suffix(limitPerGroup))
            )
        }

        guard !groups.isEmpty else {
            return (retainedLogs, nil)
        }

        let schema: [String: DiagnosticInfo.GroupedRecentLogs.SchemaEntry] = Dictionary(
            uniqueKeysWithValues: HighVolumeLogKind.allCases.compactMap { kind in
                guard groupedEntries[kind]?.isEmpty == false else {
                    return nil
                }

                return (kind.code, kind.schema)
            }
        )

        return (
            retainedLogs,
            DiagnosticInfo.GroupedRecentLogs(
                schema: schema,
                groups: groups
            )
        )
    }

    private struct ParsedFeedbackLogLine {
        let rawTimestamp: Substring?
        let level: Substring?
        let category: Substring?
        let message: Substring
    }

    private enum FeedbackLogDisposition {
        case exclude
        case drop
        case error
        case grouped(ParsedHighVolumeLogEntry)
        case raw
    }

    private static func isExcludedFeedbackLogEntry(_ entry: String) -> Bool {
        let parsedLine = parseFeedbackLogLine(entry)
        return isExcludedFeedbackMessage(
            parsedLine.message,
            category: parsedLine.category
        )
            || isExcludedSQLFragmentFeedbackLogEntry(entry)
    }

    private static func isExcludedFeedbackMessage(
        _ message: Substring,
        category: Substring?
    ) -> Bool {
        if message.hasPrefix("[Filter] Got ") {
            return false
        }

        if category == "ProcessMonitor-VMMap" {
            return true
        }

        if excludedFeedbackMessagePrefixes.contains(where: { message.hasPrefix($0) }) {
            return true
        }

        return excludedFeedbackMessageContains.contains(where: { message.contains($0) })
    }

    private static func isDroppedFeedbackMessage(
        _ message: Substring
    ) -> Bool {
        droppedFeedbackMessagePrefixes.contains(where: { message.hasPrefix($0) })
    }

    private static func isFeedbackErrorLogLevel(_ level: Substring?) -> Bool {
        guard let level else {
            return false
        }

        switch level {
        case "❌ ERROR", "⚠️ WARN", "🔥 CRITICAL", "FAULT":
            return true
        default:
            return false
        }
    }

    private static func isExcludedSQLFragmentFeedbackLogEntry(_ entry: String) -> Bool {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("[") else {
            return false
        }

        let sqlPrefixes = [
            "SELECT ",
            "FROM ",
            "INNER JOIN ",
            "LEFT JOIN ",
            "WHERE ",
            "ORDER BY ",
            "LIMIT ",
            "AND ",
            "OR ",
        ]
        if sqlPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return true
        }

        if trimmed.hasSuffix(","),
           ["f.", "s.", "v.", "st_hidden."].contains(where: { trimmed.hasPrefix($0) }) {
            return true
        }

        return trimmed == ")"
    }

    private enum HighVolumeLogKind: CaseIterable {
        case frameDeduplicationAnalysis
        case regionOCR
        case hevcFragmentWritten
        case timelineScrub

        var code: String {
            switch self {
            case .frameDeduplicationAnalysis:
                return "fd"
            case .regionOCR:
                return "ro"
            case .hevcFragmentWritten:
                return "hf"
            case .timelineScrub:
                return "ts"
            }
        }

        var schema: DiagnosticInfo.GroupedRecentLogs.SchemaEntry {
            switch self {
            case .frameDeduplicationAnalysis:
                return .init(
                    event: "frame_deduplication_analysis",
                    fields: [
                        "dt": "timestamp_delta_ms",
                        "t0": "base_timestamp_epoch_ms",
                    ]
                )
            case .regionOCR:
                return .init(
                    event: "region_ocr",
                    fields: [
                        "dt": "timestamp_delta_ms",
                        "t0": "base_timestamp_epoch_ms",
                    ]
                )
            case .hevcFragmentWritten:
                return .init(
                    event: "hevc_fragment_written",
                    fields: [
                        "dt": "timestamp_delta_ms",
                        "t0": "base_timestamp_epoch_ms",
                    ]
                )
            case .timelineScrub:
                return .init(
                    event: "timeline_scrub",
                    fields: [
                        "dt": "timestamp_delta_ms",
                        "t0": "base_timestamp_epoch_ms",
                    ]
                )
            }
        }
    }

    private struct ParsedHighVolumeLogEntry {
        let kind: HighVolumeLogKind
        let timestampMs: Int64
        let fields: [String: Int64]
    }

    private static let logTimestampFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let logTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseFeedbackLogLine(_ entry: String) -> ParsedFeedbackLogLine {
        var cursor = entry.startIndex
        let rawTimestamp = extractBracketedComponent(in: entry, cursor: &cursor)

        if cursor < entry.endIndex, entry[cursor] == " " {
            cursor = entry.index(after: cursor)
        }
        let level = extractBracketedComponent(in: entry, cursor: &cursor)

        if cursor < entry.endIndex, entry[cursor] == " " {
            cursor = entry.index(after: cursor)
        }
        let category = extractBracketedComponent(in: entry, cursor: &cursor)

        if cursor < entry.endIndex, entry[cursor] == " " {
            cursor = entry.index(after: cursor)
        }

        let remainder = entry[cursor...]
        if let separatorRange = remainder.range(of: " - ") {
            let message = remainder[separatorRange.upperBound...]
            return ParsedFeedbackLogLine(
                rawTimestamp: rawTimestamp,
                level: level,
                category: category,
                message: message
            )
        }

        return ParsedFeedbackLogLine(
            rawTimestamp: rawTimestamp,
            level: level,
            category: category,
            message: remainder
        )
    }

    private static func extractBracketedComponent(
        in entry: String,
        cursor: inout String.Index
    ) -> Substring? {
        guard cursor < entry.endIndex, entry[cursor] == "[" else {
            return nil
        }

        let contentStart = entry.index(after: cursor)
        guard let closingBracket = entry[contentStart...].firstIndex(of: "]") else {
            return nil
        }

        cursor = entry.index(after: closingBracket)
        return entry[contentStart..<closingBracket]
    }

    private static func feedbackLogDisposition(
        for entry: String,
        parsedLine: ParsedFeedbackLogLine? = nil
    ) -> FeedbackLogDisposition {
        let parsedLine = parsedLine ?? parseFeedbackLogLine(entry)

        if isExcludedFeedbackMessage(
            parsedLine.message,
            category: parsedLine.category
        )
            || isExcludedSQLFragmentFeedbackLogEntry(entry) {
            return .exclude
        }

        if isDroppedFeedbackMessage(parsedLine.message) {
            return .drop
        }

        if isFeedbackErrorLogLevel(parsedLine.level) {
            return .error
        }

        if let parsedHighVolumeEntry = parseHighVolumeLogEntry(parsedLine) {
            return .grouped(parsedHighVolumeEntry)
        }

        return .raw
    }

    private static func parseHighVolumeLogEntry(
        _ parsedLine: ParsedFeedbackLogLine
    ) -> ParsedHighVolumeLogEntry? {
        let kind: HighVolumeLogKind
        if parsedLine.message.hasPrefix("Deduplication analysis (")
            || parsedLine.message.hasPrefix("Frame deduplicated (") {
            kind = .frameDeduplicationAnalysis
        } else if parsedLine.message.hasPrefix("[ProcessingManager] Region OCR:") {
            kind = .regionOCR
        } else if parsedLine.message.contains("Fragment "),
                  parsedLine.message.contains("frames now readable!") {
            kind = .hevcFragmentWritten
        } else if parsedLine.message.hasPrefix("[Timeline-Scrub] started") {
            kind = .timelineScrub
        } else {
            return nil
        }

        guard let timestampMs = parseLogTimestampMs(parsedLine.rawTimestamp) else {
            return nil
        }

        return ParsedHighVolumeLogEntry(
            kind: kind,
            timestampMs: timestampMs,
            fields: [:]
        )
    }

    private static func buildHighVolumeLogGroup(
        eventCode: String,
        entries: [ParsedHighVolumeLogEntry]
    ) -> DiagnosticInfo.GroupedRecentLogs.Group? {
        guard let baseTimestampMs = entries.first?.timestampMs else {
            return nil
        }

        var scalarFields: [String: Int64] = [:]
        var seriesFields: [String: [Int64]] = [
            "dt": entries.map { $0.timestampMs - baseTimestampMs }
        ]

        let fieldKeys = Set(entries.flatMap { $0.fields.keys }).sorted()
        for key in fieldKeys {
            let values = entries.compactMap { $0.fields[key] }
            guard values.count == entries.count else {
                continue
            }

            if let firstValue = values.first, values.dropFirst().allSatisfy({ $0 == firstValue }) {
                scalarFields[key] = firstValue
            } else {
                seriesFields[key] = values
            }
        }

        return DiagnosticInfo.GroupedRecentLogs.Group(
            eventCode: eventCode,
            baseTimestampMs: baseTimestampMs,
            scalarFields: scalarFields,
            seriesFields: seriesFields
        )
    }

    private static func parseLogTimestampMs(_ rawTimestamp: String) -> Int64? {
        let date = logTimestampFormatterWithFractional.date(from: rawTimestamp)
            ?? logTimestampFormatter.date(from: rawTimestamp)
        guard let date else {
            return nil
        }

        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func parseLogTimestampMs(_ rawTimestamp: Substring?) -> Int64? {
        guard let rawTimestamp else {
            return nil
        }

        return parseLogTimestampMs(String(rawTimestamp))
    }

}
