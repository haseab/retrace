import Foundation
import Shared
import Database
import Storage
import Search

/// Manages data retention policy enforcement
/// Periodically cleans up old frames, video segments, and related data based on user settings
/// Owner: APP integration
public actor RetentionManager {

    // MARK: - Properties

    private let database: DatabaseManager
    private let storage: StorageManager
    private let search: SearchManager

    private var cleanupTask: Task<Void, Never>?
    private var isRunning = false

    /// Interval between cleanup checks (default: 1 hour)
    private let cleanupInterval: TimeInterval = 3600

    /// Last cleanup timestamp for rate limiting
    private var lastCleanupTime: Date?

    /// Minimum interval between cleanups (10 minutes)
    private let minimumCleanupInterval: TimeInterval = 600

    // MARK: - Initialization

    public init(
        database: DatabaseManager,
        storage: StorageManager,
        search: SearchManager
    ) {
        self.database = database
        self.storage = storage
        self.search = search
    }

    // MARK: - Lifecycle

    /// Start the retention manager (runs cleanup periodically)
    public func start() async {
        guard !isRunning else {
            Log.warning("[RetentionManager] Already running", category: .app)
            return
        }

        isRunning = true
        Log.info("[RetentionManager] Started", category: .app)

        // Run initial cleanup
        await runCleanupIfNeeded()

        // Start periodic cleanup task
        cleanupTask = Task {
            while !Task.isCancelled {
                // Wait for cleanup interval
                try? await Task.sleep(nanoseconds: UInt64(cleanupInterval * 1_000_000_000))

                if Task.isCancelled { break }

                await runCleanupIfNeeded()
            }
        }
    }

    /// Stop the retention manager
    public func stop() async {
        guard isRunning else { return }

        cleanupTask?.cancel()
        cleanupTask = nil
        isRunning = false

        Log.info("[RetentionManager] Stopped", category: .app)
    }

    // MARK: - Cleanup Logic

    /// Get the current retention policy from user settings
    /// Returns nil if retention is set to "Forever" (0 days)
    public nonisolated func getRetentionDays() -> Int? {
        let days = UserDefaults.standard.integer(forKey: "retentionDays")
        return days == 0 ? nil : days
    }

    /// Calculate the cutoff date based on retention settings
    /// Returns nil if retention is set to "Forever"
    public nonisolated func getCutoffDate() -> Date? {
        guard let retentionDays = getRetentionDays() else {
            return nil // Forever - no cleanup
        }

        let cutoffDate = Date().addingTimeInterval(-TimeInterval(retentionDays) * 86400)
        return cutoffDate
    }

    /// Run cleanup if enough time has passed since the last cleanup
    public func runCleanupIfNeeded() async {
        // Check if we've cleaned up recently
        if let lastCleanup = lastCleanupTime {
            let timeSinceLastCleanup = Date().timeIntervalSince(lastCleanup)
            if timeSinceLastCleanup < minimumCleanupInterval {
                Log.debug("[RetentionManager] Skipping cleanup - last cleanup was \(Int(timeSinceLastCleanup))s ago", category: .app)
                return
            }
        }

        await runCleanup()
    }

    /// Run the cleanup process
    @discardableResult
    public func runCleanup() async -> RetentionCleanupResult {
        guard let cutoffDate = getCutoffDate() else {
            Log.debug("[RetentionManager] Retention set to Forever - no cleanup needed", category: .app)
            return RetentionCleanupResult(
                deletedFrames: 0,
                deletedVideoSegments: 0,
                deletedAppSegments: 0,
                reclaimedBytes: 0,
                cutoffDate: nil,
                success: true,
                error: nil
            )
        }

        Log.info("[RetentionManager] Starting cleanup for data older than \(cutoffDate)", category: .app)
        lastCleanupTime = Date()

        do {
            // Step 1: Get video segments that will be affected (for cleanup)
            let videoSegmentsToDelete = try await getVideoSegmentsOlderThan(cutoffDate)

            // Step 2: Delete frames from database (this cascades to FTS entries via triggers)
            let deletedFrameCount = try await database.deleteFrames(olderThan: cutoffDate)
            Log.info("[RetentionManager] Deleted \(deletedFrameCount) frames from database", category: .app)

            // Step 3: Delete old app segments (sessions)
            let deletedSegmentCount = try await deleteAppSegmentsOlderThan(cutoffDate)
            Log.info("[RetentionManager] Deleted \(deletedSegmentCount) app segments", category: .app)

            // Step 4: Delete orphaned video segments and their files
            var reclaimedBytes: Int64 = 0
            var deletedVideoCount = 0

            for videoSegment in videoSegmentsToDelete {
                do {
                    // Get file size before deletion
                    let segmentPath = try await storage.getSegmentPath(id: videoSegment)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: segmentPath.path),
                       let size = attrs[.size] as? Int64 {
                        reclaimedBytes += size
                    }

                    // Delete from storage (file)
                    try await storage.deleteSegment(id: videoSegment)

                    // Delete from database
                    try await database.deleteVideoSegment(id: videoSegment)

                    deletedVideoCount += 1
                } catch {
                    Log.warning("[RetentionManager] Failed to delete video segment \(videoSegment.value): \(error)", category: .app)
                }
            }
            Log.info("[RetentionManager] Deleted \(deletedVideoCount) video segments, reclaimed \(formatBytes(reclaimedBytes))", category: .app)

            // Step 5: Clean up orphaned nodes (OCR data) for deleted frames
            let deletedNodesCount = try await cleanupOrphanedNodes()
            if deletedNodesCount > 0 {
                Log.info("[RetentionManager] Cleaned up \(deletedNodesCount) orphaned OCR nodes", category: .app)
            }

            // Step 6: Vacuum database to reclaim space (do this less frequently)
            if deletedFrameCount > 1000 || deletedVideoCount > 10 {
                try await database.vacuum()
                Log.info("[RetentionManager] Database vacuumed", category: .app)
            }

            Log.info("[RetentionManager] Cleanup complete. Frames: \(deletedFrameCount), Videos: \(deletedVideoCount), Segments: \(deletedSegmentCount), Reclaimed: \(formatBytes(reclaimedBytes))", category: .app)

            return RetentionCleanupResult(
                deletedFrames: deletedFrameCount,
                deletedVideoSegments: deletedVideoCount,
                deletedAppSegments: deletedSegmentCount,
                reclaimedBytes: reclaimedBytes,
                cutoffDate: cutoffDate,
                success: true,
                error: nil
            )

        } catch {
            Log.error("[RetentionManager] Cleanup failed: \(error)", category: .app)
            return RetentionCleanupResult(
                deletedFrames: 0,
                deletedVideoSegments: 0,
                deletedAppSegments: 0,
                reclaimedBytes: 0,
                cutoffDate: cutoffDate,
                success: false,
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Private Helpers

    /// Get video segments that have no frames newer than the cutoff date
    private func getVideoSegmentsOlderThan(_ cutoffDate: Date) async throws -> [VideoSegmentID] {
        // Video segments where all frames are older than cutoff
        // We use the storage cleanup method which checks file modification dates
        return try await storage.cleanupOldSegments(olderThan: cutoffDate)
    }

    /// Delete app segments (sessions) older than the cutoff date
    private func deleteAppSegmentsOlderThan(_ cutoffDate: Date) async throws -> Int {
        // Use database's segment deletion method
        // App segments are stored in the 'segment' table with startDate/endDate
        guard let db = await database.getConnection() else {
            throw RetentionError.databaseNotConnected
        }

        let sql = "DELETE FROM segment WHERE endDate < ?;"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        // Convert date to milliseconds since epoch
        let cutoffMs = Int64(cutoffDate.timeIntervalSince1970 * 1000)
        sqlite3_bind_int64(statement, 1, cutoffMs)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    /// Clean up OCR nodes that reference deleted frames
    private func cleanupOrphanedNodes() async throws -> Int {
        guard let db = await database.getConnection() else {
            throw RetentionError.databaseNotConnected
        }

        // Delete nodes where frameId doesn't exist in frame table
        let sql = """
            DELETE FROM node WHERE frameId NOT IN (SELECT id FROM frame);
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    /// Format bytes into human-readable string
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Supporting Types

/// Result of a retention cleanup operation
public struct RetentionCleanupResult: Sendable {
    public let deletedFrames: Int
    public let deletedVideoSegments: Int
    public let deletedAppSegments: Int
    public let reclaimedBytes: Int64
    public let cutoffDate: Date?
    public let success: Bool
    public let error: String?
}

/// Retention manager errors
public enum RetentionError: Error {
    case databaseNotConnected
    case queryFailed(String)
}

// Need SQLite for direct queries
import SQLCipher
