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
    private static let subsystem = AppPaths.logSubsystem

    /// Whether to also print to console (always true in DEBUG, configurable in release)
    #if DEBUG
    private static let printToConsole = true
    #else
    private static var printToConsole = false
    #endif

    /// Enable console printing in release builds (for debugging)
    public static func enableConsolePrinting() {
        #if !DEBUG
        printToConsole = true
        #endif
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
        print("[\(timestamp)] [\(level)] [\(category.rawValue)] \(filename):\(line) - \(message)")
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
