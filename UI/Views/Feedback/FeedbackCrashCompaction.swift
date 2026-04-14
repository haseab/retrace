import Foundation

extension FeedbackService {
    static func compactEmergencyCrashReportForFeedback(_ report: String) -> String {
        let header = "=== RETRACE EMERGENCY DIAGNOSTIC ==="
        guard report.contains(header) else {
            return report
        }

        let lines = report.components(separatedBy: .newlines)
        let parsed = parseEmergencyCrashReportSections(lines)

        var preamble = trimEmptyLines(parsed.preamble)
        if let pidIndex = preamble.firstIndex(where: { $0.hasPrefix("PID: ") }) {
            preamble.insert(
                "Note: Compacted for feedback submission; omitted repetitive checkpoints and the watchdog thread stack.",
                at: pidIndex + 1
            )
        }

        var sections: [String] = []
        sections.append(preamble.joined(separator: "\n"))

        for section in parsed.sections {
            switch section.title {
            case "SYSTEM", "PERFORMANCE", "DISPLAYS", "MAIN THREAD BACKTRACE":
                let body = trimEmptyLines(section.body)
                guard !body.isEmpty else { continue }
                sections.append(([section.heading] + body).joined(separator: "\n"))
            case "HELPER WATCHDOG SAMPLE":
                if let compacted = compactHelperWatchdogSampleSection(section.body) {
                    sections.append(([section.heading] + compacted).joined(separator: "\n"))
                }
            case "MAIN THREAD ACTIVITY":
                if let compacted = compactEmergencyCrashActivitySection(section.body) {
                    sections.append((["--- MAIN THREAD ACTIVITY (COMPACTED) ---"] + compacted).joined(separator: "\n"))
                }
            case "CURRENT THREAD":
                continue
            default:
                continue
            }
        }

        return trimEmptyLines(sections.joined(separator: "\n\n").components(separatedBy: .newlines))
            .joined(separator: "\n")
    }

    static func compactDiagnosticCrashReportForFeedback(_ report: String, fileName: String) -> String {
        if let data = report.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return compactJSONDiagnosticCrashReportForFeedback(jsonObject, fileName: fileName)
        }

        return compactPlaintextDiagnosticCrashReportForFeedback(report, fileName: fileName)
    }

    private struct EmergencyCrashReportSection {
        let heading: String
        let title: String
        let body: [String]
    }

    private static func compactJSONDiagnosticCrashReportForFeedback(
        _ jsonObject: [String: Any],
        fileName: String
    ) -> String {
        var sections: [String] = [
            "=== RETRACE macOS DIAGNOSTIC CRASH REPORT ===",
            "File: \(fileName)",
            "Note: Compacted for feedback submission; kept core metadata, exception details, and the faulting thread."
        ]

        let metadataLines = compactDiagnosticCrashMetadataLines(jsonObject)
        if !metadataLines.isEmpty {
            sections.append((["--- METADATA ---"] + metadataLines).joined(separator: "\n"))
        }

        let exceptionLines = compactDiagnosticCrashExceptionLines(jsonObject)
        if !exceptionLines.isEmpty {
            sections.append((["--- EXCEPTION ---"] + exceptionLines).joined(separator: "\n"))
        }

        let crashingThreadLines = compactDiagnosticCrashThreadLines(jsonObject)
        if !crashingThreadLines.isEmpty {
            sections.append((["--- CRASHING THREAD ---"] + crashingThreadLines).joined(separator: "\n"))
        }

        if sections.count == 3 {
            sections.append((["--- RAW PREVIEW ---"] + compactDiagnosticCrashRawPreview(reportLines: reportPreviewLines(from: jsonObject))).joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    private static func compactPlaintextDiagnosticCrashReportForFeedback(
        _ report: String,
        fileName: String
    ) -> String {
        let lines = report.components(separatedBy: .newlines)
        var sections: [String] = [
            "=== RETRACE macOS DIAGNOSTIC CRASH REPORT ===",
            "File: \(fileName)",
            "Note: Compacted for feedback submission; kept core metadata, exception details, and the crashed thread."
        ]

        let metadataPrefixes = [
            "Process:",
            "Path:",
            "Identifier:",
            "Version:",
            "Code Type:",
            "Parent Process:",
            "Date/Time:",
            "OS Version:",
            "Report Version:",
            "Hardware Model:",
        ]
        let exceptionPrefixes = [
            "Exception Type:",
            "Exception Codes:",
            "Exception Note:",
            "Termination Reason:",
            "Termination Signal:",
            "Crashed Thread:",
            "Triggered by Thread:",
        ]

        let metadataLines = collectMatchingDiagnosticCrashLines(lines, prefixes: metadataPrefixes)
        if !metadataLines.isEmpty {
            sections.append((["--- METADATA ---"] + metadataLines).joined(separator: "\n"))
        }

        let exceptionLines = collectMatchingDiagnosticCrashLines(lines, prefixes: exceptionPrefixes)
        if !exceptionLines.isEmpty {
            sections.append((["--- EXCEPTION ---"] + exceptionLines).joined(separator: "\n"))
        }

        if let backtraceBlock = diagnosticCrashBlock(
            titledByAnyOf: ["Last Exception Backtrace:"],
            lines: lines,
            maxLines: 20
        ) {
            sections.append((["--- LAST EXCEPTION BACKTRACE ---"] + backtraceBlock).joined(separator: "\n"))
        }

        let crashedThreadLabel = exceptionLines
            .first(where: { $0.hasPrefix("Crashed Thread:") })
            .flatMap { diagnosticCrashThreadHeading(from: $0) }

        if let crashedThreadLabel,
           let crashedThreadBlock = diagnosticCrashBlock(
                titledByAnyOf: [crashedThreadLabel],
                lines: lines,
                maxLines: 25
           ) {
            sections.append((["--- CRASHING THREAD ---"] + crashedThreadBlock).joined(separator: "\n"))
        }

        if sections.count == 3 {
            sections.append((["--- RAW PREVIEW ---"] + compactDiagnosticCrashRawPreview(reportLines: lines)).joined(separator: "\n"))
        }

        return trimEmptyLines(sections.joined(separator: "\n\n").components(separatedBy: .newlines))
            .joined(separator: "\n")
    }

    private static func compactDiagnosticCrashMetadataLines(_ jsonObject: [String: Any]) -> [String] {
        var lines: [String] = []
        appendDiagnosticCrashLine("timestamp", value: jsonStringValue(jsonObject["timestamp"]), to: &lines)
        appendDiagnosticCrashLine("procName", value: jsonStringValue(jsonObject["procName"]), to: &lines)
        appendDiagnosticCrashLine("procPath", value: jsonStringValue(jsonObject["procPath"]), to: &lines)
        appendDiagnosticCrashLine("bundleID", value: jsonStringValue(jsonObject["bundleID"]), to: &lines)
        appendDiagnosticCrashLine("modelCode", value: jsonStringValue(jsonObject["modelCode"]), to: &lines)
        appendDiagnosticCrashLine("bug_type", value: jsonStringValue(jsonObject["bug_type"]), to: &lines)

        if let bundleInfo = jsonObject["bundleInfo"] as? [String: Any] {
            appendDiagnosticCrashLine(
                "bundleVersion",
                value: jsonStringValue(bundleInfo["CFBundleShortVersionString"]) ?? jsonStringValue(bundleInfo["CFBundleVersion"]),
                to: &lines
            )
        }

        if let osVersion = jsonObject["osVersion"] as? [String: Any] {
            var osParts: [String] = []
            if let train = jsonStringValue(osVersion["train"]) {
                osParts.append(train)
            }
            if let build = jsonStringValue(osVersion["build"]) {
                osParts.append(build)
            }
            if let releaseType = jsonStringValue(osVersion["releaseType"]) {
                osParts.append(releaseType)
            }
            if !osParts.isEmpty {
                lines.append("osVersion: \(osParts.joined(separator: " | "))")
            }
        }

        return lines
    }

    private static func compactDiagnosticCrashExceptionLines(_ jsonObject: [String: Any]) -> [String] {
        var lines: [String] = []
        if let exception = jsonObject["exception"] as? [String: Any] {
            appendDiagnosticCrashLine("type", value: jsonStringValue(exception["type"]), to: &lines)
            appendDiagnosticCrashLine("signal", value: jsonStringValue(exception["signal"]), to: &lines)
            appendDiagnosticCrashLine("codes", value: jsonStringValue(exception["codes"]), to: &lines)
        }

        if let termination = jsonObject["termination"] as? [String: Any] {
            appendDiagnosticCrashLine("termination.namespace", value: jsonStringValue(termination["namespace"]), to: &lines)
            appendDiagnosticCrashLine("termination.indicator", value: jsonStringValue(termination["indicator"]), to: &lines)
            appendDiagnosticCrashLine("termination.reason", value: jsonStringValue(termination["reasons"]), to: &lines)
            appendDiagnosticCrashLine("termination.byProc", value: jsonStringValue(termination["byProc"]), to: &lines)
        }

        if let faultingThread = jsonIntValue(jsonObject["faultingThread"]) {
            lines.append("faultingThread: \(faultingThread)")
        }

        return lines
    }

    private static func compactDiagnosticCrashThreadLines(_ jsonObject: [String: Any]) -> [String] {
        guard let threads = jsonObject["threads"] as? [[String: Any]],
              let faultingThread = jsonIntValue(jsonObject["faultingThread"]),
              faultingThread >= 0,
              faultingThread < threads.count else {
            return []
        }

        let thread = threads[faultingThread]
        let frameStrings = (thread["frames"] as? [[String: Any]] ?? [])
            .prefix(25)
            .enumerated()
            .map { index, frame -> String in
                let image = jsonStringValue(frame["imageName"])
                    ?? jsonStringValue(frame["image"])
                    ?? jsonStringValue(frame["binaryName"])
                    ?? "?"
                let symbol = jsonStringValue(frame["symbol"])
                    ?? jsonStringValue(frame["rawFrame"])
                    ?? jsonStringValue(frame["description"])
                    ?? jsonStringValue(frame["imageOffset"])
                    ?? "?"
                return "\(index) \(image) \(symbol)"
            }

        guard !frameStrings.isEmpty else {
            return ["faultingThread: \(faultingThread)"]
        }

        var lines = ["faultingThread: \(faultingThread)"]
        lines.append(contentsOf: frameStrings)
        if let totalFrames = (thread["frames"] as? [[String: Any]])?.count,
           totalFrames > frameStrings.count {
            lines.append("... \(totalFrames - frameStrings.count) additional frames omitted")
        }
        return lines
    }

    private static func reportPreviewLines(from jsonObject: [String: Any]) -> [String] {
        if let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text.components(separatedBy: .newlines)
        }
        return []
    }

    private static func compactDiagnosticCrashRawPreview(reportLines: [String]) -> [String] {
        Array(trimEmptyLines(reportLines).prefix(20))
    }

    private static func collectMatchingDiagnosticCrashLines(
        _ lines: [String],
        prefixes: [String]
    ) -> [String] {
        trimEmptyLines(lines.filter { line in
            prefixes.contains(where: { line.hasPrefix($0) })
        })
    }

    private static func diagnosticCrashThreadHeading(from crashedThreadLine: String) -> String? {
        let suffix = crashedThreadLine.dropFirst("Crashed Thread:".count).trimmingCharacters(in: .whitespaces)
        let numericPrefix = suffix.prefix { $0.isNumber }
        guard !numericPrefix.isEmpty else {
            return nil
        }
        return "Thread \(numericPrefix) Crashed:"
    }

    private static func diagnosticCrashBlock(
        titledByAnyOf headings: [String],
        lines: [String],
        maxLines: Int
    ) -> [String]? {
        guard let startIndex = lines.firstIndex(where: { line in
            headings.contains(where: { line.hasPrefix($0) })
        }) else {
            return nil
        }

        var block: [String] = []
        for line in lines[(startIndex + 1)...] {
            if line.hasPrefix("Thread "), !line.hasPrefix(headings.first ?? "") {
                break
            }
            if line.hasPrefix("Binary Images:") {
                break
            }
            if !block.isEmpty, line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            block.append(line)
            if block.count == maxLines {
                break
            }
        }

        let trimmedBlock = trimEmptyLines(block)
        guard !trimmedBlock.isEmpty else {
            return nil
        }

        if trimmedBlock.count == maxLines {
            return trimmedBlock + ["... additional lines omitted"]
        }

        return trimmedBlock
    }

    private static func appendDiagnosticCrashLine(_ key: String, value: String?, to lines: inout [String]) {
        guard let value, !value.isEmpty else {
            return
        }
        lines.append("\(key): \(value)")
    }

    private static func jsonStringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func jsonIntValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func parseEmergencyCrashReportSections(
        _ lines: [String]
    ) -> (preamble: [String], sections: [EmergencyCrashReportSection]) {
        var preamble: [String] = []
        var sections: [EmergencyCrashReportSection] = []
        var currentHeading: String?
        var currentTitle: String?
        var currentBody: [String] = []

        func flushCurrentSection() {
            guard let currentHeading, let currentTitle else { return }
            sections.append(
                EmergencyCrashReportSection(
                    heading: currentHeading,
                    title: currentTitle,
                    body: trimEmptyLines(currentBody)
                )
            )
            currentBody.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if let title = emergencyCrashSectionTitle(for: line) {
                flushCurrentSection()
                currentHeading = line
                currentTitle = title
                continue
            }

            if currentHeading == nil {
                preamble.append(line)
            } else {
                currentBody.append(line)
            }
        }

        flushCurrentSection()
        return (preamble, sections)
    }

    private static func emergencyCrashSectionTitle(for line: String) -> String? {
        guard line.hasPrefix("--- "), line.hasSuffix(" ---") else {
            return nil
        }

        return String(line.dropFirst(4).dropLast(4))
    }

    private static func compactEmergencyCrashActivitySection(_ body: [String]) -> [String]? {
        let trimmedBody = trimEmptyLines(body)
        guard !trimmedBody.isEmpty else {
            return nil
        }

        var compacted: [String] = []

        if let checkpointsHeaderIndex = trimmedBody.firstIndex(of: "Recent checkpoints (newest last):") {
            compacted.append(trimmedBody[checkpointsHeaderIndex])

            let snapshotMarkerIndex = trimmedBody.firstIndex(of: "Captured main-thread stack snapshots:")
            let checkpointBodyEndIndex = snapshotMarkerIndex ?? trimmedBody.endIndex
            let checkpointLines = Array(trimmedBody[(checkpointsHeaderIndex + 1)..<checkpointBodyEndIndex])

            let watchdogDelayLines = checkpointLines.filter { $0.hasPrefix("- ") && $0.contains("watchdog.delay") }
            let nonDelayCheckpoints = checkpointLines.filter { $0.hasPrefix("- ") && !$0.contains("watchdog.delay") }
            let selectedCheckpoints = selectRecentUniqueCheckpoints(nonDelayCheckpoints, limit: 6)

            compacted.append(contentsOf: selectedCheckpoints)
            if let lastWatchdogDelay = watchdogDelayLines.last {
                compacted.append(lastWatchdogDelay)
            }

            let omittedCount = nonDelayCheckpoints.count - selectedCheckpoints.count
            if omittedCount > 0 {
                compacted.append("- ... \(omittedCount) additional checkpoints omitted")
            }

            if let snapshotMarkerIndex {
                let snapshotLines = Array(trimmedBody[(snapshotMarkerIndex + 1)...])
                if let compactedSnapshot = compactMainThreadStackSnapshot(snapshotLines) {
                    compacted.append("")
                    compacted.append("Captured main-thread stack snapshots (latest only):")
                    compacted.append(contentsOf: compactedSnapshot)
                }
            }
        }

        let nonEmptyCompacted = trimEmptyLines(compacted)
        return nonEmptyCompacted.isEmpty ? nil : nonEmptyCompacted
    }

    private static func compactHelperWatchdogSampleSection(_ body: [String]) -> [String]? {
        let trimmedBody = trimEmptyLines(body)
        guard !trimmedBody.isEmpty else {
            return nil
        }

        let compacted = trimmedBody.compactMap { line -> String? in
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "Binary Images:" {
                return nil
            }
            if trimmedLine.range(of: #"^0x[0-9A-Fa-f]+\s*-\s*0x[0-9A-Fa-f]+"#, options: .regularExpression) != nil {
                return nil
            }

            var sanitized = line.replacingOccurrences(
                of: #"(?:file://)?/(?:[^/\s]+/)*[^/\s]+"#,
                with: "[redacted-path]",
                options: .regularExpression
            )
            sanitized = sanitized.replacingOccurrences(
                of: #"^(\s*(?:\+?\d+|\d+)\s+)\S+(\s+0x[0-9A-Fa-f]+.*)$"#,
                with: "$1[redacted-image]$2",
                options: .regularExpression
            )
            sanitized = sanitized.replacingOccurrences(
                of: #"\((in|from) [^)]+\)"#,
                with: "($1 [redacted-image])",
                options: .regularExpression
            )
            return sanitized
        }

        let nonEmptyCompacted = trimEmptyLines(compacted)
        return nonEmptyCompacted.isEmpty ? nil : nonEmptyCompacted
    }

    private static func selectRecentUniqueCheckpoints(
        _ lines: [String],
        limit: Int
    ) -> [String] {
        guard limit > 0 else {
            return []
        }

        var selectedReversed: [String] = []
        var seenLabels: Set<String> = []

        for line in lines.reversed() {
            let label = checkpointEventLabel(from: line)
            guard seenLabels.insert(label).inserted else {
                continue
            }

            selectedReversed.append(line)
            if selectedReversed.count == limit {
                break
            }
        }

        return selectedReversed.reversed()
    }

    private static func checkpointEventLabel(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else {
            return trimmed
        }

        let withoutBullet = String(trimmed.dropFirst(2))
        guard let firstSpace = withoutBullet.firstIndex(of: " ") else {
            return withoutBullet
        }

        let afterTimestamp = withoutBullet[withoutBullet.index(after: firstSpace)...]
        if let detailsSeparator = afterTimestamp.range(of: " |") {
            return String(afterTimestamp[..<detailsSeparator.lowerBound])
        }

        return String(afterTimestamp)
    }

    private static func compactMainThreadStackSnapshot(_ lines: [String]) -> [String]? {
        guard let snapshotStart = lines.firstIndex(where: { $0.hasPrefix("[") }) else {
            return nil
        }

        var block: [String] = []
        for (offset, line) in lines[snapshotStart...].enumerated() {
            if offset > 0 && line.hasPrefix("[") {
                break
            }
            block.append(line)
        }

        let trimmedBlock = trimEmptyLines(block)
        guard let header = trimmedBlock.first else {
            return nil
        }

        let frameLines = trimmedBlock.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let keptFrameCount = min(frameLines.count, 12)
        var compacted = [header]
        compacted.append(contentsOf: frameLines.prefix(keptFrameCount))

        let omittedFrameCount = frameLines.count - keptFrameCount
        if omittedFrameCount > 0 {
            compacted.append("... \(omittedFrameCount) additional stack frames omitted")
        }

        return compacted
    }

    private static func trimEmptyLines(_ lines: [String]) -> [String] {
        var start = 0
        var end = lines.count

        while start < end && lines[start].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            start += 1
        }

        while end > start && lines[end - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }

        return Array(lines[start..<end])
    }
}
