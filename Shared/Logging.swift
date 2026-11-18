import Foundation
import os.log

// MARK: - Retrace Logger

/// Unified logging wrapper for Retrace
/// - Uses os.log (Apple's unified logging) for production
/// - Also prints to console in DEBUG builds for development visibility
/// - Logs persist to system log and can be viewed in Console.app
///
/// Usage:
/// ```swift
/// Log.debug("Starting capture", category: .capture)
/// Log.info("Frame processed", category: .processing)
/// Log.error("Failed to encode", category: .storage, error: someError)
/// ```
/// Logging interpolation removes free-form values before they reach any logging sink.
/// Counts and booleans remain available for diagnostics; strings, collections, URLs and errors do not.
public struct PrivacyLogMessage: ExpressibleByStringInterpolation, Sendable {
    public let text: String
    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
    public init(redacting value: String) { text = "[private message]" }

    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var text = ""
        public init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { text += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            switch value {
            case let v as Bool: text += v ? "true" : "false"
            case let v as Int: text += String(v)
            case let v as Int64: text += String(v)
            case let v as UInt64: text += String(v)
            case let v as Int32: text += String(v)
            case let v as UInt32: text += String(v)
            case let v as UInt: text += String(v)
            case let v as Double: text += v.isFinite ? String(v) : "nonfinite"
            case let v as Float: text += v.isFinite ? String(v) : "nonfinite"
            default: text += "[private]"
            }
        }
    }
}

public enum Log {

    // MARK: - Categories

    /// Log categories for different modules
    public enum Category: String, Sendable {
        case app = "App"
        case capture = "Capture"
        case storage = "Storage"
        case database = "Database"
        case processing = "Processing"
        case search = "Search"
        case ui = "UI"

        fileprivate var logger: Logger {
            Logger(subsystem: Log.subsystem, category: self.rawValue)
        }
    }

    // MARK: - Configuration

    /// Subsystem for os.log
    private static let subsystem = "io.retrace.app"

    /// Shared ISO8601 formatter for timestamps (avoids expensive allocations per log call)
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Thread-safe timestamp formatting
    public static func timestamp(from date: Date = Date()) -> String {
        // ISO8601DateFormatter is thread-safe for string(from:) operations
        return iso8601Formatter.string(from: date)
    }

    /// Console output is opt-in in release builds and runs on the background writer.
    public static func enableConsolePrinting() {
        LogFile.shared.enableConsolePrinting()
    }

    /// Fixed event names keep aggregation bounded and prevent captured content entering summaries.
    public enum RoutineEvent: String, Sendable, CaseIterable {
        case ocrProcessed = "OCR processed"
        case ocrExcluded = "OCR excluded"
        case captureKept = "Capture kept"
        case captureDeduplicated = "Capture deduplicated"
        case captureArraySucceeded = "Array capture succeeded"
        case captureMasked = "Capture masked"
        case captureMaskNotNeeded = "Capture masking not needed"

        fileprivate var category: Category {
            switch self {
            case .ocrProcessed, .ocrExcluded: return .processing
            default: return .capture
            }
        }
    }

    /// Count repetitive successes in memory; one summary per active event each minute.
    public static func recordRoutine(_ event: RoutineEvent, count: Int = 1, durationMs: Double? = nil) {
        LogFile.shared.recordRoutine(event, count: count, durationMs: durationMs)
    }

    // MARK: - Log File (for fast feedback diagnostics)

    /// Path to the log file - persists across crashes
    public static let logFilePath = ProcessInfo.processInfo.environment["RETRACE_LOG_PATH"]
        ?? NSHomeDirectory() + "/Library/Logs/\(AppPaths.applicationSupportName)/retrace.log"
    public static func isPrivacySafeLogEntry(_ line: String) -> Bool {
        line.range(of: #"^\[[0-9TZ:.+\-]+\] \[[^\]\r\n]+\] \[[^\]\r\n]+\] [^\r\n:]+:[0-9]+ - \[privacy-v1\] "#,
                   options: .regularExpression) != nil
    }

    /// Flush without blocking the caller's executor, e.g. before feedback export or quit.
    public static func flush() async {
        await LogFile.shared.flush()
    }

    public static func getRecentLogs(maxCount: Int = 200) async -> [String] {
        await LogFile.shared.readLastLines(count: maxCount)
    }

    public static func getRecentErrors(maxCount: Int = 50) async -> [String] {
        await LogFile.shared.readLastLines(count: maxCount, errorsOnly: true)
    }

    // MARK: - Log Levels

    public static func debug(
        _ message: @autoclosure () -> PrivacyLogMessage,
        category: Category = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        #if DEBUG
        enqueue(level: .debug, message: message().text, category: category, file: file, line: line)
        #endif
    }

    public static func info(
        _ message: PrivacyLogMessage,
        category: Category = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        enqueue(level: .info, message: message.text, category: category, file: file, line: line)
    }

    public static func notice(
        _ message: PrivacyLogMessage,
        category: Category = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        enqueue(level: .notice, message: message.text, category: category, file: file, line: line)
    }

    public static func warning(
        _ message: PrivacyLogMessage,
        category: Category = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        enqueue(level: .warning, message: message.text, category: category, file: file, line: line)
    }

    public static func error(
        _ message: PrivacyLogMessage,
        category: Category = .app,
        error: Error? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let detail = error.map { " | errorCode=\(($0 as NSError).code)" } ?? ""
        enqueue(level: .error, message: message.text + detail, category: category, file: file, line: line)
    }

    public static func critical(
        _ message: PrivacyLogMessage,
        category: Category = .app,
        error: Error? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let detail = error.map { " | errorCode=\(($0 as NSError).code)" } ?? ""
        enqueue(level: .critical, message: message.text + detail, category: category, file: file, line: line)
    }

    @_disfavoredOverload
    public static func debug(
        _ message: @autoclosure () -> String, category: Category = .app,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        #if DEBUG
        debug(PrivacyLogMessage(redacting: message()), category: category, file: file, function: function, line: line)
        #endif
    }

    @_disfavoredOverload
    public static func info(
        _ message: String, category: Category = .app,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        info(PrivacyLogMessage(redacting: message), category: category, file: file, function: function, line: line)
    }

    @_disfavoredOverload
    public static func notice(
        _ message: String, category: Category = .app,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        notice(PrivacyLogMessage(redacting: message), category: category, file: file, function: function, line: line)
    }

    @_disfavoredOverload
    public static func warning(
        _ message: String, category: Category = .app,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        warning(PrivacyLogMessage(redacting: message), category: category, file: file, function: function, line: line)
    }

    @_disfavoredOverload
    public static func error(
        _ message: String, category: Category = .app, error: Error? = nil,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        Self.error(PrivacyLogMessage(redacting: message), category: category, error: error, file: file, function: function, line: line)
    }

    @_disfavoredOverload
    public static func critical(
        _ message: String, category: Category = .app, error: Error? = nil,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        critical(PrivacyLogMessage(redacting: message), category: category, error: error, file: file, function: function, line: line)
    }

    @_disfavoredOverload
    public static func verbose(
        _ message: @autoclosure () -> String, category: Category = .app,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        #if DEBUG
        verbose(PrivacyLogMessage(redacting: message()), category: category, file: file, function: function, line: line)
        #endif
    }

    // MARK: - Performance Logging

    /// Log with timing - useful for performance measurement
    public static func measure<T>(
        _ operation: String,
        category: Category = .app,
        block: () throws -> T
    ) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        debug("\(operation) completed in \(elapsed)ms", category: category)
        return result
    }

    /// Async version of measure
    public static func measureAsync<T>(
        _ operation: String,
        category: Category = .app,
        block: () async throws -> T
    ) async rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        debug("\(operation) completed in \(elapsed)ms", category: category)
        return result
    }

    // MARK: - Latency Distribution Tracking

    public struct LatencySnapshot: Sendable {
        public let metric: String
        public let sampleCount: Int
        public let totalCount: Int
        public let latestMs: Double
        public let p50Ms: Double
        public let p95Ms: Double
        public let minMs: Double
        public let maxMs: Double
        public let shouldEmitSummary: Bool
    }

    private static let latencyRecorder = LatencyRecorder()

    /// Record a latency sample and periodically emit p50/p95 summaries.
    /// Keeps a bounded in-memory window per metric for low overhead.
    public static func recordLatency(
        _ metric: String,
        valueMs: Double,
        category: Category = .app,
        summaryEvery: Int = 10,
        warningThresholdMs: Double? = nil,
        criticalThresholdMs: Double? = nil
    ) {
        let snapshot = latencyRecorder.record(
            metric: metric,
            sampleMs: valueMs,
            summaryEvery: max(1, summaryEvery)
        )

        let latest = valueMs
        if let criticalThresholdMs, valueMs >= criticalThresholdMs {
            critical(
                "[PERF] \(metric) slow sample: \(latest)ms (critical >= \(criticalThresholdMs)ms)",
                category: category
            )
        } else if let warningThresholdMs, valueMs >= warningThresholdMs {
            warning(
                "[PERF] \(metric) slow sample: \(latest)ms (warning >= \(warningThresholdMs)ms)",
                category: category
            )
        }

        guard snapshot.shouldEmitSummary else { return }

        info(
            "[PERF] \(metric) n=\(snapshot.sampleCount) total=\(snapshot.totalCount) latest=\(snapshot.latestMs)ms p50=\(snapshot.p50Ms)ms p95=\(snapshot.p95Ms)ms min=\(snapshot.minMs)ms max=\(snapshot.maxMs)ms",
            category: category
        )
    }

    // MARK: - Private Helpers

    private static func enqueue(
        level: LogLevel, message: String, category: Category, file: String, line: Int,
        consoleOnly: Bool = false
    ) {
        LogFile.shared.append(LogEntry(
            level: level, message: message, category: category, file: file, line: line,
            consoleOnly: consoleOnly
        ))
    }

    /// Detailed development diagnostics are compiled out of release builds, including interpolation.
    public static func verbose(
        _ message: @autoclosure () -> PrivacyLogMessage,
        category: Category = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        #if DEBUG
        enqueue(level: .debug, message: message().text, category: category, file: file, line: line, consoleOnly: true)
        #endif
    }
}

// MARK: - Latency Recorder

private final class LatencyRecorder: @unchecked Sendable {
    private struct Bucket {
        var samples: [Double] = []
        var totalCount = 0
    }

    private let lock = NSLock()
    private var buckets: [String: Bucket] = [:]
    private let maxSamplesPerMetric = 200

    func record(metric: String, sampleMs: Double, summaryEvery: Int) -> Log.LatencySnapshot {
        lock.lock()
        defer { lock.unlock() }

        var bucket = buckets[metric] ?? Bucket()
        bucket.totalCount += 1
        bucket.samples.append(sampleMs)

        if bucket.samples.count > maxSamplesPerMetric {
            bucket.samples.removeFirst(bucket.samples.count - maxSamplesPerMetric)
        }

        buckets[metric] = bucket

        let sorted = bucket.samples.sorted()
        let p50 = percentile(sorted, p: 0.50)
        let p95 = percentile(sorted, p: 0.95)
        let minMs = sorted.first ?? sampleMs
        let maxMs = sorted.last ?? sampleMs
        let shouldEmitSummary = bucket.totalCount % summaryEvery == 0

        return Log.LatencySnapshot(
            metric: metric,
            sampleCount: bucket.samples.count,
            totalCount: bucket.totalCount,
            latestMs: sampleMs,
            p50Ms: p50,
            p95Ms: p95,
            minMs: minMs,
            maxMs: maxMs,
            shouldEmitSummary: shouldEmitSummary
        )
    }

    private func percentile(_ sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clampedP = min(max(p, 0), 1)
        let index = Int(round(clampedP * Double(sorted.count - 1)))
        return sorted[index]
    }
}

// MARK: - Log File

enum LogLevel: String, Sendable {
    case debug = "DEBUG", info = "INFO", notice = "NOTICE", warning = "WARN", error = "ERROR", critical = "CRITICAL"
    var isUrgent: Bool { self == .error || self == .critical }
}

struct LogEntry: Sendable {
    let date = Date()
    let level: LogLevel
    var message: String
    let category: Log.Category
    var file: String = #file
    var line: Int = #line
    var consoleOnly = false

    var formatted: String {
        let filename = (file as NSString).lastPathComponent
        return "[\(Log.timestamp(from: date))] [\(level.rawValue)] [\(category.rawValue)] \(filename):\(line) - [privacy-v1] \(message)"
    }
}

/// One serial worker owns all sinks and file handles. The ingress lock only protects
/// a bounded memory buffer; file I/O, formatting and console output never hold it.
final class LogFile: @unchecked Sendable {
    static let shared = LogFile(fileURL: URL(fileURLWithPath: Log.logFilePath))

    private let fileURL: URL
    private let queue: DispatchQueue
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private let maximumFileBytes: Int
    private let maximumBufferedBytes: Int
    private let flushInterval: TimeInterval
    private let emitToSystemLog: Bool
    private var pending: [LogEntry] = []
    private var pendingBytes = 0
    private var dropped = 0
    private var immediateDrainScheduled = false
    private var consoleEnabled = false
    private struct RoutineBucket {
        var events = 0
        var units = 0
        var durationSamples = 0
        var totalMs = 0.0
        var maximumMs = 0.0
    }
    private var routineBuckets: [Log.RoutineEvent: RoutineBucket] = [:]
    private var routineDeadline: TimeInterval?
    private let routineInterval: TimeInterval

    // Accessed exclusively on queue:
    private var initialized = false
    private var fileHandle: FileHandle?
    private var fileBytes = 0

    init(
        fileURL: URL,
        queue: DispatchQueue = DispatchQueue(label: "io.retrace.diagnostic-writer", qos: .utility),
        maximumFileBytes: Int = 50 * 1024 * 1024,
        maximumBufferedBytes: Int = 1024 * 1024,
        flushInterval: TimeInterval = 2,
        routineInterval: TimeInterval = 60,
        emitToSystemLog: Bool = true
    ) {
        self.fileURL = fileURL
        self.queue = queue
        self.maximumFileBytes = maximumFileBytes
        self.maximumBufferedBytes = maximumBufferedBytes
        self.flushInterval = flushInterval
        self.routineInterval = routineInterval
        self.emitToSystemLog = emitToSystemLog
        self.timer = DispatchSource.makeTimerSource(queue: queue)
        #if DEBUG
        consoleEnabled = true
        #endif
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
    }

    deinit {
        timer.cancel()
        try? fileHandle?.close()
    }

    func enableConsolePrinting() {
        lock.lock()
        consoleEnabled = true
        lock.unlock()
    }

    var bufferState: (bytes: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (pendingBytes, dropped)
    }

    func append(_ entry: LogEntry) {
        // Bound each message as well as the backlog. No unsanitized values enter this buffer.
        var bounded = entry
        bounded.message = String(decoding: entry.message.utf8.prefix(16 * 1024), as: UTF8.self)
        let cost = bounded.message.utf8.count + bounded.file.utf8.count + 256
        lock.lock()
        defer { lock.unlock() }
        let wasEmpty = pending.isEmpty && dropped == 0
        // Reserve a quarter of the budget for errors and critical events during routine-log floods.
        let budget = bounded.level.isUrgent ? maximumBufferedBytes : maximumBufferedBytes * 3 / 4
        if pendingBytes + cost <= budget && pending.count < (bounded.level.isUrgent ? 2048 : 1536) {
            pending.append(bounded)
            pendingBytes += cost
        } else {
            dropped += 1
        }
        if wasEmpty {
            timer.schedule(deadline: .now() + flushInterval, leeway: .milliseconds(100))
        }
        if (bounded.level.isUrgent || pendingBytes >= min(64 * 1024, maximumBufferedBytes * 3 / 4)) && !immediateDrainScheduled {
            immediateDrainScheduled = true
            queue.async { [weak self] in self?.drain() }
        }
    }

    func recordRoutine(_ event: Log.RoutineEvent, count: Int, durationMs: Double?) {
        lock.lock()
        defer { lock.unlock() }
        var bucket = routineBuckets[event, default: RoutineBucket()]
        bucket.events += 1
        bucket.units += max(0, count)
        if let durationMs, durationMs.isFinite, durationMs >= 0 {
            bucket.durationSamples += 1
            bucket.totalMs += durationMs
            bucket.maximumMs = max(bucket.maximumMs, durationMs)
        }
        routineBuckets[event] = bucket
        if routineDeadline == nil {
            routineDeadline = ProcessInfo.processInfo.systemUptime + routineInterval
            if pending.isEmpty && dropped == 0 {
                timer.schedule(deadline: .now() + routineInterval, leeway: .seconds(1))
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.drain(includeRoutineSummary: true)
                try? self.fileHandle?.synchronize()
                continuation.resume()
            }
        }
    }

    private func initializeFile() throws {
        guard !initialized else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Preserve the privacy migration: discard unsafe current AND rotated legacy logs.
        for url in [fileURL, oldURL] {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let prefix = try? handle.read(upToCount: 512)
            try? handle.close()
            if let prefix, !prefix.isEmpty,
               !Log.isPrivacySafeLogEntry(String(decoding: prefix, as: UTF8.self).components(separatedBy: "\n").first ?? "") {
                try FileManager.default.removeItem(at: url)
            }
        }
        initialized = true
    }

    private var oldURL: URL { fileURL.deletingPathExtension().appendingPathExtension("old.log") }

    private func openFile() throws {
        try initializeFile()
        guard fileHandle == nil else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        fileBytes = Int(try handle.seekToEnd())
        fileHandle = handle
    }

    private func rotate() throws {
        try fileHandle?.close()
        fileHandle = nil
        if FileManager.default.fileExists(atPath: oldURL.path) { try FileManager.default.removeItem(at: oldURL) }
        try FileManager.default.moveItem(at: fileURL, to: oldURL)
        try openFile()
    }

    private func drain(includeRoutineSummary: Bool = false) {
        lock.lock()
        var entries = pending
        let omitted = dropped
        let printToConsole = consoleEnabled
        pending = []
        pendingBytes = 0
        dropped = 0
        immediateDrainScheduled = false
        let now = ProcessInfo.processInfo.systemUptime
        var summaries: [Log.RoutineEvent: RoutineBucket] = [:]
        if let deadline = routineDeadline, includeRoutineSummary || now >= deadline {
            summaries = routineBuckets
            routineBuckets = [:]
            routineDeadline = nil
        }
        if let deadline = routineDeadline {
            timer.schedule(deadline: .now() + max(0, deadline - now), leeway: .seconds(1))
        } else {
            timer.schedule(deadline: .distantFuture)
        }
        lock.unlock()
        for event in Log.RoutineEvent.allCases {
            guard let bucket = summaries[event] else { continue }
            var message = "[Routine] \(event.rawValue): events=\(bucket.events) units=\(bucket.units)"
            if bucket.durationSamples > 0 {
                message += " averageMs=\(bucket.totalMs / Double(bucket.durationSamples)) maximumMs=\(bucket.maximumMs)"
            }
            entries.append(LogEntry(level: .info, message: message, category: event.category))
        }
        if omitted > 0 {
            entries.append(LogEntry(level: .warning, message: "[Logging] Dropped \(omitted) messages because the diagnostic buffer was full", category: .app))
        }
        guard !entries.isEmpty else { return }
        let formattedEntries = entries.map { ($0, $0.formatted) }
        for (entry, formatted) in formattedEntries {
            if emitToSystemLog {
                let logger = entry.category.logger
                switch entry.level {
                case .debug: logger.debug("\(entry.message, privacy: .private)")
                case .info: logger.info("\(entry.message, privacy: .private)")
                case .notice: logger.notice("\(entry.message, privacy: .private)")
                case .warning: logger.warning("\(entry.message, privacy: .private)")
                case .error: logger.error("\(entry.message, privacy: .private)")
                case .critical: logger.critical("\(entry.message, privacy: .private)")
                }
            }
            if printToConsole { print(formatted) }
        }
        var batch = Data()
        do {
            try openFile()
            for (entry, formatted) in formattedEntries {
                guard !entry.consoleOnly else { continue }
                let data = Data((formatted + "\n").utf8)
                // Never split a line between rotated files.
                if fileBytes + batch.count + data.count > maximumFileBytes {
                    if !batch.isEmpty {
                        try fileHandle?.write(contentsOf: batch)
                        fileBytes += batch.count
                        batch.removeAll(keepingCapacity: true)
                    }
                    try rotate()
                }
                batch.append(data)
            }
            if !batch.isEmpty {
                try fileHandle?.write(contentsOf: batch)
                fileBytes += batch.count
            }
        } catch {
            try? fileHandle?.close()
            fileHandle = nil
            // Never recursively log a writer failure. Unified logging is still available.
            Logger(subsystem: "io.retrace.app", category: "Logging").error("Diagnostic file write failed; errorCode=\((error as NSError).code)")
        }
    }

    func readLastLines(count: Int, errorsOnly: Bool = false) async -> [String] {
        guard count > 0 else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async {
                self.drain(includeRoutineSummary: true)
                do {
                    try self.initializeFile()
                    // Read bounded chunks backwards, rather than loading a 50 MiB file for 200 lines.
                    var lines: [String] = []
                    for url in [self.fileURL, self.oldURL] {
                        guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                        defer { try? handle.close() }
                        var offset = try handle.seekToEnd()
                        var fragment = Data()
                        while offset > 0 && lines.count < count {
                            let size = min(offset, 64 * 1024)
                            offset -= size
                            try handle.seek(toOffset: offset)
                            var chunk = try handle.read(upToCount: Int(size)) ?? Data()
                            chunk.append(fragment)
                            let parts = chunk.split(separator: 10, omittingEmptySubsequences: false)
                            fragment = offset > 0 ? Data(parts.first ?? Data()) : Data()
                            let complete = offset > 0 ? parts.dropFirst() : parts[...]
                            for part in complete.reversed() where !part.isEmpty {
                                let line = String(decoding: part, as: UTF8.self)
                                guard Log.isPrivacySafeLogEntry(line) else { continue }
                                if errorsOnly && !["[ERROR]", "[WARN]", "[CRITICAL]", "[❌ ERROR]", "[⚠️ WARN]", "[🔥 CRITICAL]", "[FAULT]"].contains(where: line.contains) { continue }
                                lines.append(line)
                                if lines.count == count { break }
                            }
                        }
                        if lines.count == count { break }
                    }
                    continuation.resume(returning: Array(lines.reversed()))
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }
}

// MARK: - Convenience Extensions

extension Log {
    /// Log frame capture event
    public static func frameCapture(
        width: Int,
        height: Int,
        app: String?,
        deduplicated: Bool = false
    ) {
        let status = deduplicated ? "deduped" : "captured"
        debug("Frame \(status): \(width)x\(height) from \(app ?? "unknown")", category: .capture)
    }

    /// Log OCR completion
    public static func ocrComplete(
        frameID: String,
        wordCount: Int,
        timeMs: Double
    ) {
        debug("OCR complete: \(wordCount) words in \(String(format: "%.1f", timeMs))ms [frame: \(frameID.prefix(8))]", category: .processing)
    }

    /// Log search query
    public static func searchQuery(
        query: String,
        resultCount: Int,
        timeMs: Int
    ) {
        info("Search '\(query)' returned \(resultCount) results in \(timeMs)ms", category: .search)
    }

    /// Log storage operation
    public static func storageWrite(
        segmentID: String,
        bytes: Int64
    ) {
        debug("Wrote segment \(segmentID.prefix(8)): \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", category: .storage)
    }
}

// MARK: - Memory Ledger

/// Function-level memory attribution ledger.
///
/// This is intentionally explicit and app-defined. It reports what Retrace knows about
/// its own caches/windows/queues and compares that to process-level footprint/resident.
/// The remainder is reported as "unattributed" so allocator buckets are no longer the only view.
public enum MemoryLedger {
    private static let store = MemoryLedgerStore()
    private static let pendingWriteLock = NSLock()
    private static var pendingWriteTail: Task<Void, Never>?
    /// Enqueued writes that have not finished yet. Guarded by `pendingWriteLock`.
    private static var pendingWriteDepth = 0
    /// Writes refused because the backlog was already at `pendingWriteDepthLimit`.
    private static var pendingWriteDropCount = 0
    /// Backlog depth past which fire-and-forget writes are refused.
    ///
    /// Every write chains itself onto its predecessor, so each pending write keeps a
    /// live `Task` alive that retains the one before it. A producer that outruns the
    /// drain therefore grows an unbounded chain, and `flushPendingUpdates()` -- which
    /// awaits the tail -- has to wait for all of it. An unthrottled writer loop grew
    /// that chain until the test process died with signal 10.
    ///
    /// Ordered writes cannot run away, because their caller awaits each one before
    /// issuing the next, so the cap applies only to the fire-and-forget entry points.
    /// Production sits a handful of writes deep; this only engages on pathological
    /// write rates, where dropping telemetry beats killing the process.
    private static let pendingWriteDepthLimit = 256
    private static let summaryLoggingDefaultsKey = "retrace.debug.memoryLedgerSummaryLoggingEnabled"

    public struct ResidualEpoch: Sendable {
        fileprivate let id: UInt64
    }

    public enum ResidualClaimTarget: String, Sendable {
        case owner
        case concurrent
        case none
    }

    public struct ResidualClaim: Sendable {
        public let target: ResidualClaimTarget
        public let bytes: Int64
        public let activeConcurrentFunctions: [String]
        public let processSnapshotGeneration: UInt64
    }

    public struct FunctionSnapshot: Sendable {
        public let function: String
        public let trackedBytes: Int64
        public let contextualBytes: Int64
        public let componentCount: Int
    }

    public enum ComponentCategory: String, Sendable, Codable {
        case explicit
        case inferred
        case unattributed
    }

    public struct ComponentSnapshot: Sendable {
        public let tag: String
        public let category: ComponentCategory
        public let bytes: Int64
        public let count: Int?
        public let unit: String?
        public let function: String
        public let kind: String
        public let note: String?
        public let countsTowardTrackedMemory: Bool
    }

    public struct Snapshot: Sendable {
        public let componentCount: Int
        public let trackedMemoryBytes: Int64
        public let contextualBytes: Int64
        public let trackedAllBytes: Int64
        public let footprintBytes: UInt64
        public let residentBytes: UInt64
        public let internalBytes: UInt64
        public let compressedBytes: UInt64
        public let unattributedBytes: UInt64
        public let components: [ComponentSnapshot]
        public let functions: [FunctionSnapshot]
    }

    public static func beginResidualEpoch(
        ownerFunction: String,
        candidateConcurrentFunctions: [String] = []
    ) async -> ResidualEpoch {
        await store.beginResidualEpoch(
            ownerFunction: ownerFunction,
            candidateConcurrentFunctions: candidateConcurrentFunctions
        )
    }

    public static func endResidualEpoch(_ epoch: ResidualEpoch) async {
        await store.endResidualEpoch(epoch)
    }

    public static func claimCurrentUnattributed(
        epoch: ResidualEpoch,
        requestedBytes: Int64? = nil
    ) async -> ResidualClaim {
        await store.claimCurrentUnattributed(
            epoch: epoch,
            requestedBytes: requestedBytes
        )
    }

    public static func flushPendingUpdates() async {
        _ = await pendingWriteSnapshot()?.result
    }

    /// Backlog depth, writes dropped because the backlog was full, and the cap itself.
    public static var pendingWriteDiagnostics: (depth: Int, dropped: Int, limit: Int) {
        pendingWriteLock.lock()
        defer { pendingWriteLock.unlock() }
        return (pendingWriteDepth, pendingWriteDropCount, pendingWriteDepthLimit)
    }

    /// Chain `operation` onto the current tail. The caller must hold `pendingWriteLock`.
    @discardableResult
    private static func appendPendingWriteLocked(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previousTail = pendingWriteTail
        pendingWriteDepth += 1
        let task = Task(priority: .utility) {
            if let previousTail {
                _ = await previousTail.result
            }
            await operation()
            retirePendingWrite()
        }
        pendingWriteTail = task
        return task
    }

    /// Account for a finished write. Synchronous because `NSLock` may not be taken
    /// from an async context.
    private static func retirePendingWrite() {
        pendingWriteLock.lock()
        pendingWriteDepth -= 1
        // Nobody can be waiting on this chain any more, so stop retaining its tail.
        if pendingWriteDepth == 0 {
            pendingWriteTail = nil
        }
        pendingWriteLock.unlock()
    }

    /// Enqueue a write whose completion the caller awaits.
    ///
    /// Uncapped on purpose: an awaiting caller cannot outrun the drain, so the depth
    /// these contribute is bounded by the number of concurrent callers.
    @discardableResult
    private static func enqueuePendingWrite(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        pendingWriteLock.lock()
        defer { pendingWriteLock.unlock() }
        return appendPendingWriteLocked(operation)
    }

    /// Enqueue a fire-and-forget write, refusing it once the backlog is saturated.
    ///
    /// These entry points are not `async`, so they have no way to apply backpressure;
    /// refusing a telemetry write is the only bound available to them.
    private static func enqueueDroppablePendingWrite(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        pendingWriteLock.lock()
        guard pendingWriteDepth < pendingWriteDepthLimit else {
            pendingWriteDropCount += 1
            let dropped = pendingWriteDropCount
            pendingWriteLock.unlock()
            // Report on crossing each multiple of the limit, so a saturated ledger is
            // visible without the report itself becoming the flood.
            if dropped.isMultiple(of: pendingWriteDepthLimit) {
                Log.warning(
                    "[MemoryLedger] Dropped \(dropped) telemetry writes; pending-write backlog is at its \(pendingWriteDepthLimit) limit",
                    category: .app
                )
            }
            return
        }
        appendPendingWriteLocked(operation)
        pendingWriteLock.unlock()
    }

    private static func pendingWriteSnapshot() -> Task<Void, Never>? {
        pendingWriteLock.lock()
        let pendingWrite = pendingWriteTail
        pendingWriteLock.unlock()
        return pendingWrite
    }

    fileprivate static func isSummaryLoggingEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: summaryLoggingDefaultsKey)
    }

    /// Set/update a memory component snapshot.
    ///
    /// - Parameters:
    ///   - tag: Stable identifier (e.g. `ui.search.thumbnailCache`)
    ///   - bytes: Measured/estimated bytes for this component (clamped to >= 0)
    ///   - count: Optional item count (frames, images, workers, etc.)
    ///   - unit: Optional count unit label
    ///   - function: Functional area (e.g. `ui.search`, `processing.ocr`)
    ///   - kind: Component type (e.g. `images`, `queue`, `telemetry-window`)
    ///   - note: Optional qualifier (e.g. `estimated`, `on-disk`)
    ///   - category: Attribution bucket used by downstream memory views
    public static func set(
        tag: String,
        bytes: Int64,
        count: Int? = nil,
        unit: String? = nil,
        function: String,
        kind: String,
        note: String? = nil,
        category: ComponentCategory = .explicit,
        countsTowardTrackedMemory: Bool = true
    ) {
        guard !tag.isEmpty else { return }
        enqueueDroppablePendingWrite {
            await store.set(
                tag: tag,
                bytes: bytes,
                count: count,
                unit: unit,
                function: function,
                kind: kind,
                note: note,
                category: category,
                countsTowardTrackedMemory: countsTowardTrackedMemory
            )
        }
    }

    public static func setOrdered(
        tag: String,
        bytes: Int64,
        count: Int? = nil,
        unit: String? = nil,
        function: String,
        kind: String,
        note: String? = nil,
        category: ComponentCategory = .explicit,
        countsTowardTrackedMemory: Bool = true
    ) async {
        guard !tag.isEmpty else { return }
        let task = enqueuePendingWrite {
            await store.set(
                tag: tag,
                bytes: bytes,
                count: count,
                unit: unit,
                function: function,
                kind: kind,
                note: note,
                category: category,
                countsTowardTrackedMemory: countsTowardTrackedMemory
            )
        }
        _ = await task.result
    }

    /// Remove a component from the ledger.
    ///
    /// Deliberately not droppable. A dropped `set` self-corrects on the next write of
    /// the same tag, but a dropped `remove` would strand a component in the ledger
    /// permanently and overstate tracked memory from then on. Removes are driven by
    /// teardown rather than per-frame work, so they cannot be the runaway producer.
    public static func remove(tag: String) {
        guard !tag.isEmpty else { return }
        enqueuePendingWrite {
            await store.remove(tag: tag)
        }
    }

    public static func removeOrdered(tag: String) async {
        guard !tag.isEmpty else { return }
        let task = enqueuePendingWrite {
            await store.remove(tag: tag)
        }
        _ = await task.result
    }

    /// Update process-level memory snapshot for tracked-vs-unattributed calculations.
    public static func setProcessSnapshot(
        footprintBytes: UInt64?,
        residentBytes: UInt64?,
        internalBytes: UInt64?,
        compressedBytes: UInt64?
    ) {
        enqueueDroppablePendingWrite {
            await store.setProcessSnapshot(
                footprintBytes: footprintBytes,
                residentBytes: residentBytes,
                internalBytes: internalBytes,
                compressedBytes: compressedBytes
            )
        }
    }

    public static func setProcessSnapshotOrdered(
        footprintBytes: UInt64?,
        residentBytes: UInt64?,
        internalBytes: UInt64?,
        compressedBytes: UInt64?
    ) async {
        let task = enqueuePendingWrite {
            await store.setProcessSnapshot(
                footprintBytes: footprintBytes,
                residentBytes: residentBytes,
                internalBytes: internalBytes,
                compressedBytes: compressedBytes
            )
        }
        _ = await task.result
    }

    /// Emit a unified ledger summary if enough time has elapsed.
    public static func emitSummary(
        reason: String,
        category: Log.Category = .app,
        minIntervalSeconds: TimeInterval = 30,
        force: Bool = false
    ) {
        enqueueDroppablePendingWrite {
            await store.emitSummaryIfNeeded(
                reason: reason,
                category: category,
                minIntervalSeconds: minIntervalSeconds,
                force: force
            )
        }
    }

    public static func emitSummaryOrdered(
        reason: String,
        category: Log.Category = .app,
        minIntervalSeconds: TimeInterval = 30,
        force: Bool = false
    ) async {
        let task = enqueuePendingWrite {
            await store.emitSummaryIfNeeded(
                reason: reason,
                category: category,
                minIntervalSeconds: minIntervalSeconds,
                force: force
            )
        }
        _ = await task.result
    }

    public static func snapshot(waitForPendingUpdates: Bool = false) async -> Snapshot {
        if waitForPendingUpdates {
            await flushPendingUpdates()
        }
        return await store.snapshot()
    }
}

private actor MemoryLedgerStore {
    private struct FunctionSummary: Sendable {
        let function: String
        let trackedBytes: Int64
        let contextualBytes: Int64
        let componentCount: Int
    }

    private struct ComponentEntry: Sendable {
        let tag: String
        var category: MemoryLedger.ComponentCategory
        var bytes: Int64
        var count: Int?
        var unit: String?
        var function: String
        var kind: String
        var note: String?
        var countsTowardTrackedMemory: Bool
        var updatedAt: Date
        var updateCount: Int
    }

    private struct ProcessSnapshot: Sendable {
        let footprintBytes: UInt64
        let residentBytes: UInt64
        let internalBytes: UInt64
        let compressedBytes: UInt64
        let updatedAt: Date
    }

    private struct ResidualEpochState: Sendable {
        let ownerFunction: String
        let candidateConcurrentFunctions: [String]
    }

    private var entries: [String: ComponentEntry] = [:]
    private var processSnapshot: ProcessSnapshot?
    private var processSnapshotGeneration: UInt64 = 0
    private var lastSummaryAt: Date?
    private var nextResidualEpochID: UInt64 = 1
    private var residualEpochs: [UInt64: ResidualEpochState] = [:]
    private var activeFunctionCount: [String: Int] = [:]
    private var claimedUnattributedBytesByGeneration: [UInt64: Int64] = [:]
    private static let maxBreakdownComponents = 12
    private static let maxFunctionBreakdownComponents = 8

    func set(
        tag: String,
        bytes: Int64,
        count: Int?,
        unit: String?,
        function: String,
        kind: String,
        note: String?,
        category: MemoryLedger.ComponentCategory,
        countsTowardTrackedMemory: Bool
    ) {
        let normalizedBytes = max(0, bytes)
        let now = Date()

        if var existing = entries[tag] {
            existing.category = category
            existing.bytes = normalizedBytes
            existing.count = count
            existing.unit = unit
            existing.function = function
            existing.kind = kind
            existing.note = note
            existing.countsTowardTrackedMemory = countsTowardTrackedMemory
            existing.updatedAt = now
            existing.updateCount += 1
            entries[tag] = existing
        } else {
            entries[tag] = ComponentEntry(
                tag: tag,
                category: category,
                bytes: normalizedBytes,
                count: count,
                unit: unit,
                function: function,
                kind: kind,
                note: note,
                countsTowardTrackedMemory: countsTowardTrackedMemory,
                updatedAt: now,
                updateCount: 1
            )
        }
    }

    func remove(tag: String) {
        entries.removeValue(forKey: tag)
    }

    func setProcessSnapshot(
        footprintBytes: UInt64?,
        residentBytes: UInt64?,
        internalBytes: UInt64?,
        compressedBytes: UInt64?
    ) {
        processSnapshotGeneration &+= 1
        processSnapshot = ProcessSnapshot(
            footprintBytes: footprintBytes ?? 0,
            residentBytes: residentBytes ?? 0,
            internalBytes: internalBytes ?? 0,
            compressedBytes: compressedBytes ?? 0,
            updatedAt: Date()
        )
        let minimumGenerationToKeep = processSnapshotGeneration > 4 ? processSnapshotGeneration - 4 : 0
        claimedUnattributedBytesByGeneration = claimedUnattributedBytesByGeneration.filter { generation, _ in
            generation >= minimumGenerationToKeep
        }
    }

    func beginResidualEpoch(
        ownerFunction: String,
        candidateConcurrentFunctions: [String]
    ) -> MemoryLedger.ResidualEpoch {
        let epochID = nextResidualEpochID
        nextResidualEpochID &+= 1

        residualEpochs[epochID] = ResidualEpochState(
            ownerFunction: ownerFunction,
            candidateConcurrentFunctions: candidateConcurrentFunctions
        )
        activeFunctionCount[ownerFunction, default: 0] += 1

        return MemoryLedger.ResidualEpoch(id: epochID)
    }

    func endResidualEpoch(_ epoch: MemoryLedger.ResidualEpoch) {
        guard let state = residualEpochs.removeValue(forKey: epoch.id) else { return }

        let currentCount = activeFunctionCount[state.ownerFunction] ?? 0
        if currentCount <= 1 {
            activeFunctionCount.removeValue(forKey: state.ownerFunction)
        } else {
            activeFunctionCount[state.ownerFunction] = currentCount - 1
        }
    }

    func claimCurrentUnattributed(
        epoch: MemoryLedger.ResidualEpoch,
        requestedBytes: Int64?
    ) -> MemoryLedger.ResidualClaim {
        guard let state = residualEpochs[epoch.id] else {
            return MemoryLedger.ResidualClaim(
                target: .none,
                bytes: 0,
                activeConcurrentFunctions: [],
                processSnapshotGeneration: processSnapshotGeneration
            )
        }

        let rankedEntries = entries.values.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes {
                return lhs.bytes > rhs.bytes
            }
            return lhs.tag < rhs.tag
        }

        let trackedMemoryBytes = rankedEntries
            .filter(\.countsTowardTrackedMemory)
            .reduce(into: Int64(0)) { runningTotal, entry in
                if runningTotal > Int64.max - entry.bytes {
                    runningTotal = Int64.max
                } else {
                    runningTotal += entry.bytes
                }
            }
        let trackedMemoryBytesUInt64 = UInt64(max(trackedMemoryBytes, 0))
        let footprintBytes = processSnapshot?.footprintBytes ?? 0
        let unattributedBytes = footprintBytes > trackedMemoryBytesUInt64
            ? footprintBytes - trackedMemoryBytesUInt64
            : 0
        let totalUnattributedBytes = Int64(min(unattributedBytes, UInt64(Int64.max)))
        let generation = processSnapshotGeneration
        let claimedBytes = claimedUnattributedBytesByGeneration[generation] ?? 0
        let availableBytes = max(0, totalUnattributedBytes - claimedBytes)
        let requestedBytesOrAvailable = requestedBytes.map { max(0, $0) } ?? availableBytes
        let allocatedBytes = min(availableBytes, requestedBytesOrAvailable)

        let activeConcurrentFunctions = state.candidateConcurrentFunctions
            .filter { function in
                function != state.ownerFunction && (activeFunctionCount[function] ?? 0) > 0
            }
            .sorted()

        if allocatedBytes > 0 {
            claimedUnattributedBytesByGeneration[generation] = claimedBytes + allocatedBytes
        }

        let target: MemoryLedger.ResidualClaimTarget
        if allocatedBytes <= 0 {
            target = .none
        } else if activeConcurrentFunctions.isEmpty {
            target = .owner
        } else {
            target = .concurrent
        }

        return MemoryLedger.ResidualClaim(
            target: target,
            bytes: allocatedBytes,
            activeConcurrentFunctions: activeConcurrentFunctions,
            processSnapshotGeneration: generation
        )
    }

    func emitSummaryIfNeeded(
        reason: String,
        category: Log.Category,
        minIntervalSeconds: TimeInterval,
        force: Bool
    ) {
        guard MemoryLedger.isSummaryLoggingEnabled() else { return }
        let now = Date()
        if !force, let lastSummaryAt, now.timeIntervalSince(lastSummaryAt) < max(1, minIntervalSeconds) {
            return
        }
        lastSummaryAt = now

        let rankedEntries = entries.values.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes {
                return lhs.bytes > rhs.bytes
            }
            return lhs.tag < rhs.tag
        }

        let trackedMemoryBytes = rankedEntries
            .filter(\.countsTowardTrackedMemory)
            .reduce(into: Int64(0)) { runningTotal, entry in
                if runningTotal > Int64.max - entry.bytes {
                    runningTotal = Int64.max
                } else {
                    runningTotal += entry.bytes
                }
            }
        let contextualBytes = rankedEntries
            .filter { !$0.countsTowardTrackedMemory }
            .reduce(into: Int64(0)) { runningTotal, entry in
                if runningTotal > Int64.max - entry.bytes {
                    runningTotal = Int64.max
                } else {
                    runningTotal += entry.bytes
                }
            }

        let trackedMemoryBytesUInt64 = UInt64(max(trackedMemoryBytes, 0))
        let contextualBytesUInt64 = UInt64(max(contextualBytes, 0))

        let trackedBytesForCompatibility = rankedEntries.reduce(into: Int64(0)) { runningTotal, entry in
            if runningTotal > Int64.max - entry.bytes {
                runningTotal = Int64.max
            } else {
                runningTotal += entry.bytes
            }
        }
        let trackedBytesForCompatibilityUInt64 = UInt64(max(trackedBytesForCompatibility, 0))

        let footprintBytes = processSnapshot?.footprintBytes ?? 0
        let residentBytes = processSnapshot?.residentBytes ?? 0
        let internalBytes = processSnapshot?.internalBytes ?? 0
        let compressedBytes = processSnapshot?.compressedBytes ?? 0
        let unattributedBytes = footprintBytes > trackedMemoryBytesUInt64
            ? footprintBytes - trackedMemoryBytesUInt64
            : 0

        let topEntries = rankedEntries.prefix(Self.maxBreakdownComponents)
        let breakdown = topEntries.map(Self.formatEntry).joined(separator: " | ")
        let omittedCount = max(0, rankedEntries.count - topEntries.count)
        let functionSummaries = Self.summarizeByFunction(rankedEntries)
        let topFunctions = functionSummaries.prefix(Self.maxFunctionBreakdownComponents)
        let functionBreakdown = topFunctions.map(Self.formatFunctionSummary).joined(separator: " | ")
        let omittedFunctionCount = max(0, functionSummaries.count - topFunctions.count)

        var message = "[Memory-Ledger] reason=\(reason) components=\(rankedEntries.count) tracked=\(Self.formatBytes(trackedMemoryBytesUInt64)) contextual=\(Self.formatBytes(contextualBytesUInt64)) trackedAll=\(Self.formatBytes(trackedBytesForCompatibilityUInt64)) footprint=\(Self.formatBytes(footprintBytes)) resident=\(Self.formatBytes(residentBytes)) internal=\(Self.formatBytes(internalBytes)) compressed=\(Self.formatBytes(compressedBytes)) unattributed=\(Self.formatBytes(unattributedBytes)) breakdown=[\(breakdown)] functions=[\(functionBreakdown)]"
        if omittedCount > 0 {
            message += " omitted=\(omittedCount)"
        }
        if omittedFunctionCount > 0 {
            message += " functionOmitted=\(omittedFunctionCount)"
        }

        Log.info(message, category: category)
    }

    func snapshot() -> MemoryLedger.Snapshot {
        let rankedEntries = entries.values.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes {
                return lhs.bytes > rhs.bytes
            }
            return lhs.tag < rhs.tag
        }

        let trackedMemoryBytes = rankedEntries
            .filter(\.countsTowardTrackedMemory)
            .reduce(into: Int64(0)) { runningTotal, entry in
                if runningTotal > Int64.max - entry.bytes {
                    runningTotal = Int64.max
                } else {
                    runningTotal += entry.bytes
                }
            }
        let contextualBytes = rankedEntries
            .filter { !$0.countsTowardTrackedMemory }
            .reduce(into: Int64(0)) { runningTotal, entry in
                if runningTotal > Int64.max - entry.bytes {
                    runningTotal = Int64.max
                } else {
                    runningTotal += entry.bytes
                }
            }
        let trackedAllBytes = rankedEntries.reduce(into: Int64(0)) { runningTotal, entry in
            if runningTotal > Int64.max - entry.bytes {
                runningTotal = Int64.max
            } else {
                runningTotal += entry.bytes
            }
        }

        let footprintBytes = processSnapshot?.footprintBytes ?? 0
        let residentBytes = processSnapshot?.residentBytes ?? 0
        let internalBytes = processSnapshot?.internalBytes ?? 0
        let compressedBytes = processSnapshot?.compressedBytes ?? 0
        let trackedMemoryBytesUInt64 = UInt64(max(trackedMemoryBytes, 0))
        let unattributedBytes = footprintBytes > trackedMemoryBytesUInt64
            ? footprintBytes - trackedMemoryBytesUInt64
            : 0

        return MemoryLedger.Snapshot(
            componentCount: rankedEntries.count,
            trackedMemoryBytes: trackedMemoryBytes,
            contextualBytes: contextualBytes,
            trackedAllBytes: trackedAllBytes,
            footprintBytes: footprintBytes,
            residentBytes: residentBytes,
            internalBytes: internalBytes,
            compressedBytes: compressedBytes,
            unattributedBytes: unattributedBytes,
            components: rankedEntries.map {
                MemoryLedger.ComponentSnapshot(
                    tag: $0.tag,
                    category: $0.category,
                    bytes: $0.bytes,
                    count: $0.count,
                    unit: $0.unit,
                    function: $0.function,
                    kind: $0.kind,
                    note: $0.note,
                    countsTowardTrackedMemory: $0.countsTowardTrackedMemory
                )
            },
            functions: Self.summarizeByFunction(rankedEntries).map {
                MemoryLedger.FunctionSnapshot(
                    function: $0.function,
                    trackedBytes: $0.trackedBytes,
                    contextualBytes: $0.contextualBytes,
                    componentCount: $0.componentCount
                )
            }
        )
    }

    private static func formatEntry(_ entry: ComponentEntry) -> String {
        var parts: [String] = []
        parts.reserveCapacity(6)
        parts.append("fn=\(entry.function)")
        parts.append("kind=\(entry.kind)")
        if let count = entry.count {
            let unit = entry.unit ?? "items"
            parts.append("count=\(count) \(unit)")
        }
        if let note = entry.note, !note.isEmpty {
            parts.append("note=\(note)")
        }
        parts.append("scope=\(entry.countsTowardTrackedMemory ? "memory" : "context")")
        return "\(entry.tag):\(formatBytes(UInt64(max(entry.bytes, 0)))) {\(parts.joined(separator: ","))}"
    }

    private static func summarizeByFunction(_ entries: [ComponentEntry]) -> [FunctionSummary] {
        let summariesByFunction = entries.reduce(into: [String: FunctionSummary]()) { partialResult, entry in
            let existing = partialResult[entry.function] ?? FunctionSummary(
                function: entry.function,
                trackedBytes: 0,
                contextualBytes: 0,
                componentCount: 0
            )

            let trackedBytes = existing.trackedBytes + (entry.countsTowardTrackedMemory ? entry.bytes : 0)
            let contextualBytes = existing.contextualBytes + (entry.countsTowardTrackedMemory ? 0 : entry.bytes)

            partialResult[entry.function] = FunctionSummary(
                function: entry.function,
                trackedBytes: trackedBytes,
                contextualBytes: contextualBytes,
                componentCount: existing.componentCount + 1
            )
        }

        return summariesByFunction.values.sorted { lhs, rhs in
            let lhsTotal = lhs.trackedBytes + lhs.contextualBytes
            let rhsTotal = rhs.trackedBytes + rhs.contextualBytes
            if lhsTotal != rhsTotal {
                return lhsTotal > rhsTotal
            }
            if lhs.trackedBytes != rhs.trackedBytes {
                return lhs.trackedBytes > rhs.trackedBytes
            }
            return lhs.function < rhs.function
        }
    }

    private static func formatFunctionSummary(_ summary: FunctionSummary) -> String {
        let tracked = formatBytes(UInt64(max(summary.trackedBytes, 0)))
        let contextual = formatBytes(UInt64(max(summary.contextualBytes, 0)))
        return "\(summary.function){tracked=\(tracked),context=\(contextual),components=\(summary.componentCount)}"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}

// MARK: - Main Thread Watchdog

/// Detects when the main thread is blocked for too long (potential UI freeze)
/// Enable this in production to catch UI freeze issues before users report them
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()

    private var watchdogThread: Thread?
    private var isRunning = false
    private let lock = NSLock()

    /// Monotonic timestamp of last main-thread heartbeat.
    /// Uses uptime nanoseconds to avoid counting time spent in system sleep.
    private var lastHeartbeatUptimeNanos: UInt64 = DispatchTime.now().uptimeNanoseconds

    /// Threshold for warning (in seconds)
    private let warningThreshold: TimeInterval = 0.5

    /// Threshold for critical alert (in seconds)
    private let criticalThreshold: TimeInterval = 2.0

    /// Threshold where the app is considered frozen long enough to auto-quit.
    private let autoQuitThreshold: TimeInterval = 10.0

    /// Require repeated failed probes before triggering auto-quit.
    /// This avoids one-off false positives during power/display transitions.
    private let requiredConsecutiveFailedProbes = 5

    /// How often to emit suppression logs while auto-quit is suspended.
    private let suppressionLogInterval: TimeInterval = 5.0

    /// Number of times we've detected blocking
    private var blockingCount = 0

    /// Ensures auto-quit is only triggered once per freeze event.
    private var autoQuitTriggered = false

    /// Number of consecutive failed auto-quit probes once threshold is reached.
    private var consecutiveFailedAutoQuitProbes = 0

    /// Monotonic uptime timestamp until which auto-quit is suspended.
    /// `UInt64.max` means indefinite suspension.
    private var autoQuitSuppressedUntilUptimeNanos: UInt64?

    /// Human-readable reason for current suspension state.
    private var autoQuitSuppressionReason: String?

    /// Last time we logged suppression in the watchdog loop.
    private var lastSuppressionLogUptimeNanos: UInt64 = 0

    /// Callback invoked when the auto-quit threshold is reached.
    private var autoQuitHandler: (@Sendable (_ blockedSeconds: TimeInterval) -> Void)?

    private init() {}

    /// Configure behavior when the watchdog detects an unrecoverable UI freeze.
    /// The callback is executed on the watchdog background thread.
    public func setAutoQuitHandler(_ handler: @escaping @Sendable (_ blockedSeconds: TimeInterval) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        autoQuitHandler = handler
    }

    /// Suspend watchdog-triggered auto-quit indefinitely.
    public func suspendAutoQuit(reason: String) {
        lock.lock()
        defer { lock.unlock() }

        autoQuitSuppressedUntilUptimeNanos = UInt64.max
        autoQuitSuppressionReason = reason
        autoQuitTriggered = false
        consecutiveFailedAutoQuitProbes = 0
        lastSuppressionLogUptimeNanos = DispatchTime.now().uptimeNanoseconds
        Log.info("[Watchdog] Auto-quit suspended indefinitely (\(reason))", category: .ui)
    }

    /// Suspend watchdog-triggered auto-quit for a bounded grace period.
    public func suspendAutoQuit(for duration: TimeInterval, reason: String) {
        guard duration > 0 else {
            resumeAutoQuit(reason: "\(reason) (duration elapsed)")
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let now = DispatchTime.now().uptimeNanoseconds
        let durationNanos = UInt64(duration * 1_000_000_000)
        let suppressedUntil = durationNanos > (UInt64.max - now) ? UInt64.max : now + durationNanos

        autoQuitSuppressedUntilUptimeNanos = suppressedUntil
        autoQuitSuppressionReason = reason
        autoQuitTriggered = false
        consecutiveFailedAutoQuitProbes = 0
        lastSuppressionLogUptimeNanos = now
        Log.info(
            "[Watchdog] Auto-quit suspended for \(String(format: "%.1f", duration))s (\(reason))",
            category: .ui
        )
    }

    /// Resume watchdog-triggered auto-quit immediately.
    public func resumeAutoQuit(reason: String) {
        lock.lock()
        defer { lock.unlock() }

        autoQuitSuppressedUntilUptimeNanos = nil
        autoQuitSuppressionReason = nil
        consecutiveFailedAutoQuitProbes = 0
        lastSuppressionLogUptimeNanos = 0
        Log.info("[Watchdog] Auto-quit resumed (\(reason))", category: .ui)
    }

    /// Resume watchdog-triggered auto-quit after a bounded grace period.
    public func resumeAutoQuit(after delay: TimeInterval, reason: String) {
        guard delay > 0 else {
            resumeAutoQuit(reason: reason)
            return
        }
        suspendAutoQuit(for: delay, reason: "\(reason) grace")
    }

    /// Start the watchdog - call this once at app startup
    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        isRunning = true

        // Heartbeat on main thread every 100ms
        let heartbeatTimer = DispatchSource.makeTimerSource(queue: .main)
        heartbeatTimer.schedule(deadline: .now(), repeating: 0.1)
        heartbeatTimer.setEventHandler { [weak self] in
            self?.recordHeartbeat()
        }
        heartbeatTimer.resume()
        objc_setAssociatedObject(self, "heartbeatTimer", heartbeatTimer, .OBJC_ASSOCIATION_RETAIN)

        // Watchdog on background thread checks for missed heartbeats
        watchdogThread = Thread { [weak self] in
            while self?.isRunningSnapshot() == true {
                Thread.sleep(forTimeInterval: 0.2)
                self?.checkHeartbeat()
            }
        }
        watchdogThread?.name = "MainThreadWatchdog"
        watchdogThread?.start()

        Log.info("[Watchdog] Main thread watchdog started", category: .ui)
    }

    /// Stop the watchdog
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
    }

    private func isRunningSnapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    private func recordHeartbeat() {
        lock.lock()
        defer { lock.unlock() }
        lastHeartbeatUptimeNanos = DispatchTime.now().uptimeNanoseconds
        autoQuitTriggered = false
        consecutiveFailedAutoQuitProbes = 0
    }

    private func checkHeartbeat() {
        guard isRunningSnapshot() else { return }

        lock.lock()
        let nowUptimeNanos = DispatchTime.now().uptimeNanoseconds
        let elapsed = elapsedSecondsSinceLastHeartbeatLocked(nowUptimeNanos: nowUptimeNanos)
        let suppression = autoQuitSuppressionStatusLocked(nowUptimeNanos: nowUptimeNanos)
        let shouldLogSuppression = shouldLogSuppressionLocked(
            nowUptimeNanos: nowUptimeNanos,
            isSuppressed: suppression.isSuppressed,
            elapsed: elapsed
        )
        if suppression.isSuppressed {
            autoQuitTriggered = false
            consecutiveFailedAutoQuitProbes = 0
        }
        lock.unlock()

        if suppression.isSuppressed {
            if shouldLogSuppression {
                let reason = suppression.reason ?? "unspecified reason"
                Log.info(
                    "[Watchdog] Auto-quit suppressed (\(reason)); main-thread delay currently \(String(format: "%.1f", elapsed))s",
                    category: .ui
                )
            }
            return
        }

        var didBlock = false
        if elapsed > criticalThreshold {
            didBlock = true
        } else if elapsed > warningThreshold {
            didBlock = true
        }

        guard didBlock else { return }

        lock.lock()
        blockingCount += 1
        let currentCount = blockingCount
        lock.unlock()

        if elapsed > criticalThreshold {
            Log.critical("[Watchdog] Main thread BLOCKED for \(String(format: "%.1f", elapsed))s! UI may be frozen. (count=\(currentCount))", category: .ui)
        } else if elapsed > warningThreshold {
            Log.warning("[Watchdog] Main thread delayed \(String(format: "%.1f", elapsed * 1000))ms (count=\(currentCount))", category: .ui)
        }

        guard elapsed >= autoQuitThreshold else { return }
        guard !mainThreadRespondedToProbe(timeout: 0.25) else {
            Log.warning(
                "[Watchdog] Skipping auto-quit: main thread responded to probe after \(String(format: "%.1f", elapsed))s elapsed (likely sleep/wake timing).",
                category: .ui
            )
            recordHeartbeat()
            return
        }

        lock.lock()
        consecutiveFailedAutoQuitProbes += 1
        let failedProbeCount = consecutiveFailedAutoQuitProbes
        lock.unlock()

        guard failedProbeCount >= requiredConsecutiveFailedProbes else {
            Log.warning(
                "[Watchdog] Auto-quit probe failed (\(failedProbeCount)/\(requiredConsecutiveFailedProbes)) after \(String(format: "%.1f", elapsed))s blocked; waiting for confirmation.",
                category: .ui
            )
            return
        }

        let handler: (@Sendable (_ blockedSeconds: TimeInterval) -> Void)?
        lock.lock()
        if autoQuitTriggered {
            handler = nil
        } else {
            autoQuitTriggered = true
            consecutiveFailedAutoQuitProbes = 0
            handler = autoQuitHandler
        }
        lock.unlock()

        handler?(elapsed)
    }

    /// Get current blocking statistics
    public var statistics: (blockingCount: Int, isHealthy: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = elapsedSecondsSinceLastHeartbeatLocked(nowUptimeNanos: DispatchTime.now().uptimeNanoseconds)
        return (blockingCount, elapsed < warningThreshold)
    }

    private func elapsedSecondsSinceLastHeartbeatLocked(nowUptimeNanos: UInt64) -> TimeInterval {
        guard nowUptimeNanos >= lastHeartbeatUptimeNanos else {
            return 0
        }

        return TimeInterval(nowUptimeNanos - lastHeartbeatUptimeNanos) / 1_000_000_000
    }

    private func autoQuitSuppressionStatusLocked(nowUptimeNanos: UInt64) -> (isSuppressed: Bool, reason: String?) {
        guard let suppressedUntil = autoQuitSuppressedUntilUptimeNanos else {
            return (false, nil)
        }

        if suppressedUntil == UInt64.max || nowUptimeNanos < suppressedUntil {
            return (true, autoQuitSuppressionReason)
        }

        autoQuitSuppressedUntilUptimeNanos = nil
        autoQuitSuppressionReason = nil
        lastSuppressionLogUptimeNanos = 0
        return (false, nil)
    }

    private func shouldLogSuppressionLocked(
        nowUptimeNanos: UInt64,
        isSuppressed: Bool,
        elapsed: TimeInterval
    ) -> Bool {
        guard isSuppressed, elapsed >= warningThreshold else {
            return false
        }

        if lastSuppressionLogUptimeNanos == 0 {
            lastSuppressionLogUptimeNanos = nowUptimeNanos
            return true
        }

        guard nowUptimeNanos >= lastSuppressionLogUptimeNanos else {
            lastSuppressionLogUptimeNanos = nowUptimeNanos
            return true
        }

        let sinceLast = TimeInterval(nowUptimeNanos - lastSuppressionLogUptimeNanos) / 1_000_000_000
        guard sinceLast >= suppressionLogInterval else {
            return false
        }

        lastSuppressionLogUptimeNanos = nowUptimeNanos
        return true
    }

    private func mainThreadRespondedToProbe(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            semaphore.signal()
        }

        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}
