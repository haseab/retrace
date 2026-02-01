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

    // MARK: - Private Helpers

    private static func printFormatted(
        level: String,
        message: String,
        category: Category,
        file: String,
        line: Int
    ) {
        let filename = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formattedLog = "[\(timestamp)] [\(level)] [\(category.rawValue)] \(filename):\(line) - \(message)"
        print(formattedLog)

        // Also write to log file for persistence across crashes
        LogFile.shared.append(formattedLog)
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
    private let maxFileSize: Int64 = 5 * 1024 * 1024  // 5MB max, then rotate

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
