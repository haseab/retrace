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
public enum Log {

    // MARK: - Categories

    /// Log categories for different modules
    public enum Category: String {
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

    /// Whether to also print to console (always true for both DEBUG and release builds)
    /// This ensures logs are always written to stdout for export capabilities
    private static var printToConsole = true

    /// Enable console printing in release builds (for debugging)
    public static func enableConsolePrinting() {
        #if !DEBUG
        printToConsole = true
        #endif
    }

    // MARK: - Log File (for fast feedback diagnostics)

    /// Path to the log file - persists across crashes
    public static let logFilePath = NSHomeDirectory() + "/Library/Logs/Retrace/retrace.log"

    /// Get recent logs from the log file (fast file read, no OSLogStore)
    public static func getRecentLogs(maxCount: Int = 200) -> [String] {
        LogFile.shared.readLastLines(count: maxCount)
    }

    /// Get recent error logs only
    public static func getRecentErrors(maxCount: Int = 50) -> [String] {
        LogFile.shared.readLastLines(count: maxCount * 2).filter {
            $0.contains("[ERROR]") || $0.contains("[WARN]") || $0.contains("[CRITICAL]")
        }.suffix(maxCount).map { $0 }
    }

    // MARK: - Log Levels

    /// Debug level - verbose information for development
    /// Only appears in Console.app when "Include Debug Messages" is enabled
    public static func debug(
        _ message: String,
        category: Category = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let logger = category.logger
        logger.debug("\(message, privacy: .public)")

        if printToConsole {
            printFormatted(level: "DEBUG", message: message, category: category, file: file, line: line)
        }
    }

    /// Info level - general information about app operation
    public static func info(
        _ message: String,
        category: Category = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let logger = category.logger
        logger.info("\(message, privacy: .public)")

        if printToConsole {
            printFormatted(level: "INFO", message: message, category: category, file: file, line: line)
        }
    }

    /// Notice level - important events worth noting
    public static func notice(
        _ message: String,
        category: Category = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let logger = category.logger
        logger.notice("\(message, privacy: .public)")

        if printToConsole {
            printFormatted(level: "NOTICE", message: message, category: category, file: file, line: line)
        }
    }

    /// Warning level - something unexpected but recoverable
    public static func warning(
        _ message: String,
        category: Category = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let logger = category.logger
        logger.warning("\(message, privacy: .public)")

        if printToConsole {
            printFormatted(level: "⚠️ WARN", message: message, category: category, file: file, line: line)
        }
    }

    /// Error level - something failed
    public static func error(
        _ message: String,
        category: Category = .app,
        error: Error? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let logger = category.logger
        let errorDetail = error.map { " | Error: \($0.localizedDescription)" } ?? ""
        let fullMessage = "\(message)\(errorDetail)"

        logger.error("\(fullMessage, privacy: .public)")

        if printToConsole {
            printFormatted(level: "❌ ERROR", message: fullMessage, category: category, file: file, line: line)
        }
    }

    /// Critical/Fault level - app may crash or be in undefined state
    public static func critical(
        _ message: String,
        category: Category = .app,
        error: Error? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let logger = category.logger
        let errorDetail = error.map { " | Error: \($0.localizedDescription)" } ?? ""
        let fullMessage = "\(message)\(errorDetail)"

        logger.critical("\(fullMessage, privacy: .public)")

        if printToConsole {
            printFormatted(level: "🔥 CRITICAL", message: fullMessage, category: category, file: file, line: line)
        }
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

        debug("\(operation) completed in \(String(format: "%.2f", elapsed))ms", category: category)
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

        debug("\(operation) completed in \(String(format: "%.2f", elapsed))ms", category: category)
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

        let latest = String(format: "%.1f", valueMs)
        if let criticalThresholdMs, valueMs >= criticalThresholdMs {
            critical(
                "[PERF] \(metric) slow sample: \(latest)ms (critical >= \(String(format: "%.1f", criticalThresholdMs))ms)",
                category: category
            )
        } else if let warningThresholdMs, valueMs >= warningThresholdMs {
            warning(
                "[PERF] \(metric) slow sample: \(latest)ms (warning >= \(String(format: "%.1f", warningThresholdMs))ms)",
                category: category
            )
        }

        guard snapshot.shouldEmitSummary else { return }

        info(
            "[PERF] \(metric) n=\(snapshot.sampleCount) total=\(snapshot.totalCount) latest=\(String(format: "%.1f", snapshot.latestMs))ms p50=\(String(format: "%.1f", snapshot.p50Ms))ms p95=\(String(format: "%.1f", snapshot.p95Ms))ms min=\(String(format: "%.1f", snapshot.minMs))ms max=\(String(format: "%.1f", snapshot.maxMs))ms",
            category: category
        )
    }

    // MARK: - Private Helpers

    private static func printFormatted(
        level: String,
        message: String,
        category: Category,
        file: String,
        line: Int,
        consoleOnly: Bool = false
    ) {
        let filename = (file as NSString).lastPathComponent
        let formattedLog = "[\(timestamp())] [\(level)] [\(category.rawValue)] \(filename):\(line) - \(message)"
        print(formattedLog)

        if !consoleOnly {
            // Also write to log file for persistence across crashes
            LogFile.shared.append(formattedLog)
        }
    }

    /// Console-only debug log — prints to stdout but NOT to retrace.log.
    /// Use for high-frequency per-frame logs that would spam the log file.
    public static func verbose(
        _ message: String,
        category: Category = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let logger = category.logger
        logger.debug("\(message, privacy: .public)")

        if printToConsole {
            printFormatted(level: "DEBUG", message: message, category: category, file: file, line: line, consoleOnly: true)
        }
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

/// Writes logs to a file for persistence and fast retrieval
/// Used for feedback diagnostics (avoids slow OSLogStore)
private final class LogFile: @unchecked Sendable {
    static let shared = LogFile()

    private let fileURL: URL
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private let maxFileSize: Int64 = 50 * 1024 * 1024  // 50MB max, then rotate

    private init() {
        let logDir = NSHomeDirectory() + "/Library/Logs/Retrace"
        self.fileURL = URL(fileURLWithPath: logDir + "/retrace.log")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            atPath: logDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Open file handle for appending
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
    }

    func append(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let data = (entry + "\n").data(using: .utf8) else { return }

        // Check if we need to rotate
        if let handle = fileHandle {
            let currentSize = handle.offsetInFile
            if currentSize > maxFileSize {
                rotateLog()
            }
        }

        // Write to file
        if fileHandle == nil {
            fileHandle = try? FileHandle(forWritingTo: fileURL)
            fileHandle?.seekToEndOfFile()
        }
        try? fileHandle?.write(contentsOf: data)
    }

    private func rotateLog() {
        // Close current handle
        try? fileHandle?.close()
        fileHandle = nil

        // Rename current log to .old (overwrite any existing .old)
        let oldURL = fileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: fileURL, to: oldURL)

        // Create new log file
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        fileHandle = try? FileHandle(forWritingTo: fileURL)
    }

    func readLastLines(count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        // Flush any pending writes
        try? fileHandle?.synchronize()

        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let startIndex = max(0, lines.count - count)
        return Array(lines[startIndex...])
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

    public struct ComponentSnapshot: Sendable {
        public let tag: String
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

    @discardableResult
    private static func enqueuePendingWrite(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        pendingWriteLock.lock()
        let previousTail = pendingWriteTail
        let task = Task(priority: .utility) {
            if let previousTail {
                _ = await previousTail.result
            }
            await operation()
        }
        pendingWriteTail = task
        pendingWriteLock.unlock()
        return task
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
    public static func set(
        tag: String,
        bytes: Int64,
        count: Int? = nil,
        unit: String? = nil,
        function: String,
        kind: String,
        note: String? = nil,
        countsTowardTrackedMemory: Bool = true
    ) {
        guard !tag.isEmpty else { return }
        enqueuePendingWrite {
            await store.set(
                tag: tag,
                bytes: bytes,
                count: count,
                unit: unit,
                function: function,
                kind: kind,
                note: note,
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
                countsTowardTrackedMemory: countsTowardTrackedMemory
            )
        }
        _ = await task.result
    }

    /// Remove a component from the ledger.
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
        enqueuePendingWrite {
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
        enqueuePendingWrite {
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
        countsTowardTrackedMemory: Bool
    ) {
        let normalizedBytes = max(0, bytes)
        let now = Date()

        if var existing = entries[tag] {
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
