import Foundation
import SQLCipher
import Shared

/// Configuration for database operations, encapsulating source-specific differences
/// Allows UnifiedDatabaseAdapter to work uniformly across different data sources
public struct DatabaseConfig: Sendable {
    /// Date formatter for TEXT-based timestamps (nil = use INTEGER milliseconds)
    public let dateFormatter: DateFormatter?

    /// Base directory for video/media files
    public let storageRoot: String

    /// Frame source identifier
    public let source: FrameSource

    /// Optional cutoff date - data is only available before this date
    public let cutoffDate: Date?

    public init(
        dateFormatter: DateFormatter?,
        storageRoot: String,
        source: FrameSource,
        cutoffDate: Date?
    ) {
        self.dateFormatter = dateFormatter
        self.storageRoot = storageRoot
        self.source = source
        self.cutoffDate = cutoffDate
    }
}

// MARK: - Preset Configurations

extension DatabaseConfig {
    /// Configuration for native Retrace data source
    /// - INTEGER timestamps (milliseconds since epoch)
    /// - No cutoff date (current/future data)
    /// - Storage in ~/Library/Application Support/retrace
    /// Note: DB stores paths like "chunks/202601/17/...", so storageRoot should NOT include "chunks"
    public static var retrace: DatabaseConfig {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let storageRoot = "\(homeDirectory)/Library/Application Support/retrace"

        return DatabaseConfig(
            dateFormatter: nil, // Use INTEGER milliseconds
            storageRoot: storageRoot,
            source: .native,
            cutoffDate: nil // No cutoff
        )
    }

    /// Configuration for Rewind AI data source
    /// - TEXT timestamps (ISO8601 format)
    /// - Cutoff date: December 20, 2025 00:00:00 UTC (frozen historical data)
    /// - Storage in ~/Library/Application Support/com.memoryvault.MemoryVault/chunks
    public static var rewind: DatabaseConfig {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let storageRoot = "\(homeDirectory)/Library/Application Support/com.memoryvault.MemoryVault/chunks"

        // ISO8601 formatter for Rewind's TEXT timestamps
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(secondsFromGMT: 0) // UTC
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Rewind cutoff: December 20, 2025 00:00:00 UTC
        // Unix timestamp: 1766217600
        let cutoffDate = Date(timeIntervalSince1970: 1766217600)

        return DatabaseConfig(
            dateFormatter: formatter,
            storageRoot: storageRoot,
            source: .rewind,
            cutoffDate: cutoffDate
        )
    }
}

// MARK: - Helper Methods

extension DatabaseConfig {
    /// Convert Date to database-specific format for binding
    /// - Returns: Either Int64 (INTEGER) or String (TEXT ISO8601)
    public func formatDate(_ date: Date) -> Any {
        if let formatter = dateFormatter {
            // TEXT binding (Rewind)
            return formatter.string(from: date)
        } else {
            // INTEGER binding (Retrace) - milliseconds since epoch
            return Int64(date.timeIntervalSince1970 * 1000)
        }
    }

    /// Bind a date parameter to a prepared statement
    public func bindDate(_ date: Date, to statement: OpaquePointer, at index: Int32) {
        if let formatter = dateFormatter {
            // TEXT binding (Rewind)
            let iso = formatter.string(from: date)
            sqlite3_bind_text(statement, index, (iso as NSString).utf8String, -1, nil)
        } else {
            // INTEGER binding (Retrace)
            let ms = Int64(date.timeIntervalSince1970 * 1000)
            sqlite3_bind_int64(statement, index, ms)
        }
    }

    /// Parse a date from a database column
    public func parseDate(from statement: OpaquePointer, column: Int32) -> Date? {
        if let formatter = dateFormatter {
            // TEXT column (Rewind)
            guard let cString = sqlite3_column_text(statement, column) else { return nil }
            let iso = String(cString: cString)
            return formatter.date(from: iso)
        } else {
            // INTEGER column (Retrace)
            let ms = sqlite3_column_int64(statement, column)
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
    }

    /// Apply cutoff date to a query end date (if applicable)
    public func applyCutoff(to endDate: Date) -> Date {
        guard let cutoffDate = cutoffDate else { return endDate }
        return min(endDate, cutoffDate)
    }
}
