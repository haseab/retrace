import Foundation
import SQLCipher
import Shared
import CryptoKit

/// Main database manager implementing DatabaseProtocol
/// Owner: DATABASE agent
///
/// Thread Safety: Actor provides automatic serialization of all database operations
public actor DatabaseManager: DatabaseProtocol {

    // MARK: - Properties

    private var db: OpaquePointer?
    private let databasePath: String
    private var isInitialized = false

    /// Public accessor for the database connection (needed for query classes)
    public func getConnection() -> OpaquePointer? {
        db
    }

    // MARK: - Initialization

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    /// Convenience initializer for in-memory database (testing)
    public init() {
        self.databasePath = ":memory:"
    }

    // MARK: - Lifecycle

    public func initialize() async throws {
        guard !isInitialized else { return }
        print("[DEBUG] DatabaseManager.initialize() started")

        // Expand tilde in path if present
        let expandedPath = NSString(string: databasePath).expandingTildeInPath
        print("[DEBUG] Expanded path: \(expandedPath)")

        // Create parent directory if needed (unless in-memory)
        // Check for both ":memory:" and URI-based in-memory databases (file:xxx?mode=memory)
        let isInMemory = databasePath == ":memory:" || databasePath.contains("mode=memory")
        if !isInMemory {
            let directory = (expandedPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        // Open database
        // Use sqlite3_open_v2 with SQLITE_OPEN_URI to support URI filenames like:
        // file:memdb_xxx?mode=memory&cache=private for unique in-memory databases
        // SQLITE_OPEN_FULLMUTEX enables thread-safe serialized access mode
        print("[DEBUG] Opening database...")
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(expandedPath, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw DatabaseError.connectionFailed(underlying: errorMsg)
        }
        print("[DEBUG] Database opened successfully")

        // Set encryption key (SQLCipher) if encryption is enabled and not in-memory
        if !isInMemory {
            try await setEncryptionKey()
        }

        // Enable foreign keys and WAL mode
        print("[DEBUG] Executing pragmas...")
        try executePragmas()
        print("[DEBUG] Pragmas executed")

        // Run migrations
        print("[DEBUG] Running migrations...")
        let migrationRunner = MigrationRunner(db: db!)
        try await migrationRunner.runMigrations()
        print("[DEBUG] Migrations complete")

        // Offset AUTOINCREMENT to avoid collision with Rewind's frozen data
        print("[DEBUG] Setting AUTOINCREMENT offset...")
        try await offsetAutoincrementFromRewind()
        print("[DEBUG] AUTOINCREMENT offset complete")

        isInitialized = true
        print("Database initialized at: \(expandedPath)")
    }

    public func close() async throws {
        guard let db = db else { return }

        // Checkpoint WAL before closing (if not in-memory)
        let isInMemory = databasePath == ":memory:" || databasePath.contains("mode=memory")
        if !isInMemory {
            try await checkpoint()
        }

        // Close connection.
        //
        // IMPORTANT: Do not manually finalize all outstanding statements here.
        // FTS5 maintains internal cached statements; finalizing them directly can corrupt
        // the virtual table state and crash during close (seen as SIGSEGV in sqlite3_finalize).
        // `sqlite3_close_v2` safely performs a deferred close if anything is still in use.
        let rc = sqlite3_close_v2(db)
        guard rc == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.connectionFailed(underlying: "Failed to close database (\(rc)): \(errorMsg)")
        }

        self.db = nil
        isInitialized = false
        print("Database closed")
    }

    // MARK: - Audio Transcription Operations
    // ⚠️ RELEASE 2 ONLY - Audio transcription methods commented out for Release 1

    /*
    /// Insert audio transcription with word-level timestamps
    public func insertAudioTranscription(
        sessionID: String?,
        text: String,
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        confidence: Double?,
        words: [TranscriptionWord]
    ) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.insertTranscription(
            sessionID: sessionID,
            text: text,
            startTime: startTime,
            endTime: endTime,
            source: source,
            confidence: confidence,
            words: words
        )
    }

    /// Get audio transcriptions within a time range
    public func getAudioTranscriptions(
        from startDate: Date,
        to endDate: Date,
        source: AudioSource? = nil,
        limit: Int = 100
    ) async throws -> [AudioTranscription] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.getTranscriptions(from: startDate, to: endDate, source: source, limit: limit)
    }

    /// Search audio transcriptions by text
    public func searchAudioTranscriptions(
        query: String,
        from startDate: Date? = nil,
        to endDate: Date? = nil,
        limit: Int = 50
    ) async throws -> [AudioTranscription] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.searchTranscriptions(query: query, from: startDate, to: endDate, limit: limit)
    }

    /// Get transcriptions for a specific session
    public func getAudioTranscriptions(forSession sessionID: String) async throws -> [AudioTranscription] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.getTranscriptions(forSession: sessionID)
    }

    /// Delete old audio transcriptions
    public func deleteAudioTranscriptions(olderThan date: Date) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.deleteTranscriptions(olderThan: date)
    }

    /// Get total audio transcription count
    public func getAudioTranscriptionCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.getTranscriptionCount()
    }
    */

    // MARK: - Frame Operations

    public func insertFrame(_ frame: FrameReference) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.insert(db: db, frame: frame)
    }

    public func getFrame(id: FrameID) async throws -> FrameReference? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByID(db: db, id: id)
    }

    public func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByTimeRange(db: db, from: startDate, to: endDate, limit: limit)
    }

    public func getFramesBefore(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getFramesBefore(db: db, timestamp: timestamp, limit: limit)
    }

    public func getFramesAfter(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getFramesAfter(db: db, timestamp: timestamp, limit: limit)
    }

    public func getMostRecentFrames(limit: Int) async throws -> [FrameReference] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getMostRecent(db: db, limit: limit)
    }

    // MARK: - Optimized Frame Queries with Video Info (Rewind-inspired)

    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByTimeRangeWithVideoInfo(db: db, from: startDate, to: endDate, limit: limit)
    }

    public func getMostRecentFramesWithVideoInfo(limit: Int) async throws -> [FrameWithVideoInfo] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getMostRecentWithVideoInfo(db: db, limit: limit)
    }

    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getBeforeWithVideoInfo(db: db, timestamp: timestamp, limit: limit)
    }

    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getAfterWithVideoInfo(db: db, timestamp: timestamp, limit: limit)
    }

    public func getFrames(appBundleID: String, limit: Int, offset: Int) async throws -> [FrameReference] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByApp(db: db, appBundleID: appBundleID, limit: limit, offset: offset)
    }

    public func deleteFrames(olderThan date: Date) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.deleteOlderThan(db: db, date: date)
    }

    public func deleteFrame(id: FrameID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try FrameQueries.delete(db: db, id: id)
    }

    public func getFrameCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getCount(db: db)
    }

    public func updateFrameVideoLink(frameID: FrameID, videoID: VideoSegmentID, frameIndex: Int) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try FrameQueries.updateVideoLink(db: db, frameId: frameID.value, videoId: videoID.value, videoFrameIndex: frameIndex)
    }

    // MARK: - OCR Node Operations

    /// Get all OCR nodes with their text for a specific frame
    /// Returns nodes with normalized coordinates (0.0-1.0) and extracted text
    public func getOCRNodesWithText(frameID: FrameID) async throws -> [OCRNodeWithText] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Query nodes with text directly - keep coordinates normalized (0-1)
        let sql = """
            SELECT
                n.id,
                n.nodeOrder,
                n.textOffset,
                n.textLength,
                n.leftX,
                n.topY,
                n.width,
                n.height,
                sc.c0
            FROM node n
            JOIN doc_segment ds ON n.frameId = ds.frameId
            JOIN searchRanking_content sc ON ds.docid = sc.id
            WHERE n.frameId = ?
            ORDER BY n.nodeOrder ASC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, frameID.value)

        var results: [OCRNodeWithText] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(statement, 0))
            let textOffset = Int(sqlite3_column_int(statement, 2))
            let textLength = Int(sqlite3_column_int(statement, 3))
            let leftX = sqlite3_column_double(statement, 4)
            let topY = sqlite3_column_double(statement, 5)
            let width = sqlite3_column_double(statement, 6)
            let height = sqlite3_column_double(statement, 7)

            // Extract text substring
            guard let fullTextCStr = sqlite3_column_text(statement, 8) else { continue }
            let fullText = String(cString: fullTextCStr)

            let startIndex = fullText.index(
                fullText.startIndex,
                offsetBy: textOffset,
                limitedBy: fullText.endIndex
            ) ?? fullText.endIndex

            let endIndex = fullText.index(
                startIndex,
                offsetBy: textLength,
                limitedBy: fullText.endIndex
            ) ?? fullText.endIndex

            let text = String(fullText[startIndex..<endIndex])

            results.append(OCRNodeWithText(
                id: id,
                x: leftX,
                y: topY,
                width: width,
                height: height,
                text: text
            ))
        }

        return results
    }

    // MARK: - Video Segment Operations (Video Files)

    public func insertVideoSegment(_ segment: VideoSegment) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.insert(db: db, segment: segment)
    }

    public func getVideoSegment(id: VideoSegmentID) async throws -> VideoSegment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getByID(db: db, id: id)
    }

    public func getVideoSegment(containingTimestamp date: Date) async throws -> VideoSegment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getByTimestamp(db: db, timestamp: date)
    }

    public func getVideoSegments(from startDate: Date, to endDate: Date) async throws -> [VideoSegment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getByTimeRange(db: db, from: startDate, to: endDate)
    }

    public func deleteVideoSegment(id: VideoSegmentID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SegmentQueries.delete(db: db, id: id)
    }

    public func getTotalStorageBytes() async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getTotalStorageBytes(db: db)
    }

    // MARK: - Document Operations

    public func insertDocument(_ document: IndexedDocument) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try DocumentQueries.insert(db: db, document: document)
    }

    public func updateDocument(id: Int64, content: String) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try DocumentQueries.update(db: db, id: id, content: content)
    }

    public func deleteDocument(id: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try DocumentQueries.delete(db: db, id: id)
    }

    public func getDocument(frameID: FrameID) async throws -> IndexedDocument? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try DocumentQueries.getByFrameID(db: db, frameID: frameID)
    }

    // MARK: - Segment Operations (App Focus Sessions - Rewind Compatible)

    public func insertSegment(
        bundleID: String,
        startDate: Date,
        endDate: Date,
        windowName: String?,
        browserUrl: String?,
        type: Int
    ) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.insert(
            db: db,
            bundleID: bundleID,
            startDate: startDate,
            endDate: endDate,
            windowName: windowName,
            browserUrl: browserUrl,
            type: type
        )
    }

    public func updateSegmentEndDate(id: Int64, endDate: Date) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try AppSegmentQueries.updateEndDate(db: db, id: id, endDate: endDate)
    }

    /// Update segment's browserURL if currently null
    /// Used to backfill URLs extracted from OCR
    public func updateSegmentBrowserURL(id: Int64, browserURL: String) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try AppSegmentQueries.updateBrowserURL(db: db, id: id, browserURL: browserURL)
    }

    public func getSegment(id: Int64) async throws -> Segment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getByID(db: db, id: id)
    }

    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getByTimeRange(db: db, from: startDate, to: endDate)
    }

    public func getMostRecentSegment() async throws -> Segment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getMostRecent(db: db)
    }

    public func getSegments(bundleID: String, limit: Int) async throws -> [Segment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getByBundleID(db: db, bundleID: bundleID, limit: limit)
    }

    public func deleteSegment(id: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try AppSegmentQueries.delete(db: db, id: id)
    }

    // MARK: - OCR Node Operations (Rewind-compatible)

    public func insertNodes(
        frameID: FrameID,
        nodes: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)],
        frameWidth: Int,
        frameHeight: Int
    ) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try NodeQueries.insertBatch(
            db: db,
            frameID: frameID,
            nodes: nodes,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    public func getNodes(frameID: FrameID, frameWidth: Int, frameHeight: Int) async throws -> [OCRNode] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try NodeQueries.getByFrameID(
            db: db,
            frameID: frameID,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    public func getNodesWithText(frameID: FrameID, frameWidth: Int, frameHeight: Int) async throws -> [(node: OCRNode, text: String)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try NodeQueries.getNodesWithText(
            db: db,
            frameID: frameID,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    public func deleteNodes(frameID: FrameID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try NodeQueries.deleteByFrameID(db: db, frameID: frameID)
    }

    // MARK: - FTS Content Operations (Rewind-compatible)

    public func indexFrameText(
        mainText: String,
        chromeText: String?,
        windowTitle: String?,
        segmentId: Int64,
        frameId: Int64
    ) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FTSQueries.indexFrame(
            db: db,
            mainText: mainText,
            chromeText: chromeText,
            windowTitle: windowTitle,
            segmentId: segmentId,
            frameId: frameId
        )
    }

    public func getDocidForFrame(frameId: Int64) async throws -> Int64? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FTSQueries.getDocidForFrame(db: db, frameId: frameId)
    }

    public func getFTSContent(docid: Int64) async throws -> (mainText: String, chromeText: String?, windowTitle: String?)? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FTSQueries.getContent(db: db, docid: docid)
    }

    public func deleteFTSContent(frameId: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try FTSQueries.deleteForFrame(db: db, frameId: frameId)
    }

    // MARK: - Statistics

    public func getStatistics() async throws -> DatabaseStatistics {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let frameCount = try FrameQueries.getCount(db: db)
        let segmentCount = try SegmentQueries.getCount(db: db)
        let documentCount = try DocumentQueries.getCount(db: db)

        // Get database file size (doesn't work for in-memory)
        var databaseSizeBytes: Int64 = 0
        let isInMemory = databasePath == ":memory:" || databasePath.contains("mode=memory")
        if !isInMemory {
            let expandedPath = NSString(string: databasePath).expandingTildeInPath
            if let attributes = try? FileManager.default.attributesOfItem(atPath: expandedPath) {
                databaseSizeBytes = attributes[.size] as? Int64 ?? 0
            }
        }

        // Get oldest and newest frame dates
        let (oldestDate, newestDate) = try getFrameDateRange(db: db)

        return DatabaseStatistics(
            frameCount: frameCount,
            segmentCount: segmentCount,
            documentCount: documentCount,
            databaseSizeBytes: databaseSizeBytes,
            oldestFrameDate: oldestDate,
            newestFrameDate: newestDate
        )
    }

    // MARK: - Maintenance Operations

    /// Checkpoint the WAL file (merge WAL into main database and truncate)
    /// Call periodically to prevent WAL file from growing too large
    public func checkpoint() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "PRAGMA wal_checkpoint(TRUNCATE);"
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }

        print("Database WAL checkpointed and truncated")
    }

    /// Rebuild database file to reclaim space from deleted records
    /// WARNING: Can be slow on large databases. Run during idle time.
    public func vacuum() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "VACUUM;"
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }

        print("Database vacuumed successfully")
    }

    /// Update query planner statistics for better performance
    /// Run weekly or after significant data changes
    public func analyze() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "ANALYZE;"
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }

        print("Database statistics analyzed successfully")
    }

    // MARK: - Private Helpers

    /// Offset Retrace's AUTOINCREMENT to avoid ID collisions with Rewind's frozen data
    /// Queries Rewind's database for max IDs and sets Retrace's sequences to start after them
    private func offsetAutoincrementFromRewind() async throws {
        // Check if offset has already been applied (check sqlite_sequence table)
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Check if we've already set the offset (look for our marker)
        let checkSQL = "SELECT COUNT(*) FROM sqlite_sequence WHERE name = 'frame';"
        var checkStmt: OpaquePointer?
        defer { sqlite3_finalize(checkStmt) }

        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return }

        // If we already have entries in sqlite_sequence, we've already inserted data - don't offset
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let count = sqlite3_column_int(checkStmt, 0)
            if count > 0 {
                print("[DatabaseManager] AUTOINCREMENT already initialized, skipping offset")
                return
            }
        }

        // Query Rewind's database for max IDs
        let rewindDBPath = "~/Library/Application Support/com.memoryvault.MemoryVault/rewind.db"
        let expandedRewindPath = NSString(string: rewindDBPath).expandingTildeInPath

        // Check if Rewind database exists
        guard FileManager.default.fileExists(atPath: expandedRewindPath) else {
            print("[DatabaseManager] Rewind database not found, skipping AUTOINCREMENT offset")
            return
        }

        var rewindDB: OpaquePointer?
        defer {
            if let rewindDB = rewindDB {
                sqlite3_close(rewindDB)
            }
        }

        // Open Rewind database (read-only)
        guard sqlite3_open_v2(expandedRewindPath, &rewindDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            print("[DatabaseManager] Failed to open Rewind database, skipping AUTOINCREMENT offset")
            return
        }

        // Get max frame ID from Rewind
        let maxFrameSQL = "SELECT COALESCE(MAX(id), 0) FROM frame;"
        var maxFrameStmt: OpaquePointer?
        defer { sqlite3_finalize(maxFrameStmt) }

        var maxFrameID: Int64 = 0
        if sqlite3_prepare_v2(rewindDB, maxFrameSQL, -1, &maxFrameStmt, nil) == SQLITE_OK,
           sqlite3_step(maxFrameStmt) == SQLITE_ROW {
            maxFrameID = sqlite3_column_int64(maxFrameStmt, 0)
        }

        // Get max video ID from Rewind
        let maxVideoSQL = "SELECT COALESCE(MAX(id), 0) FROM video;"
        var maxVideoStmt: OpaquePointer?
        defer { sqlite3_finalize(maxVideoStmt) }

        var maxVideoID: Int64 = 0
        if sqlite3_prepare_v2(rewindDB, maxVideoSQL, -1, &maxVideoStmt, nil) == SQLITE_OK,
           sqlite3_step(maxVideoStmt) == SQLITE_ROW {
            maxVideoID = sqlite3_column_int64(maxVideoStmt, 0)
        }

        print("[DatabaseManager] Rewind max IDs - frame: \(maxFrameID), video: \(maxVideoID)")

        // Set Retrace's AUTOINCREMENT to start after Rewind's max IDs
        // We do this by inserting/updating the sqlite_sequence table

        if maxFrameID > 0 {
            let updateFrameSeq = """
                INSERT OR REPLACE INTO sqlite_sequence (name, seq) VALUES ('frame', ?);
                """
            var updateFrameStmt: OpaquePointer?
            defer { sqlite3_finalize(updateFrameStmt) }

            if sqlite3_prepare_v2(db, updateFrameSeq, -1, &updateFrameStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(updateFrameStmt, 1, maxFrameID)
                if sqlite3_step(updateFrameStmt) == SQLITE_DONE {
                    print("[DatabaseManager] Set frame AUTOINCREMENT to start at \(maxFrameID + 1)")
                }
            }
        }

        if maxVideoID > 0 {
            let updateVideoSeq = """
                INSERT OR REPLACE INTO sqlite_sequence (name, seq) VALUES ('video', ?);
                """
            var updateVideoStmt: OpaquePointer?
            defer { sqlite3_finalize(updateVideoStmt) }

            if sqlite3_prepare_v2(db, updateVideoSeq, -1, &updateVideoStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(updateVideoStmt, 1, maxVideoID)
                if sqlite3_step(updateVideoStmt) == SQLITE_DONE {
                    print("[DatabaseManager] Set video AUTOINCREMENT to start at \(maxVideoID + 1)")
                }
            }
        }
    }

    private func executePragmas() throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        for pragma in Schema.initializationPragmas {
            var errorMessage: UnsafeMutablePointer<CChar>?
            defer {
                sqlite3_free(errorMessage)
            }

            guard sqlite3_exec(db, pragma, nil, nil, &errorMessage) == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
                throw DatabaseError.queryFailed(query: pragma, underlying: message)
            }
        }
    }

    private func getFrameDateRange(db: OpaquePointer) throws -> (oldest: Date?, newest: Date?) {
        let sql = """
            SELECT MIN(createdAt), MAX(createdAt)
            FROM frame;
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return (nil, nil)
        }

        var oldest: Date?
        var newest: Date?

        // Check if MIN is not NULL
        if sqlite3_column_type(statement, 0) != SQLITE_NULL {
            let oldestMs = sqlite3_column_int64(statement, 0)
            oldest = Schema.timestampToDate(oldestMs)
        }

        // Check if MAX is not NULL
        if sqlite3_column_type(statement, 1) != SQLITE_NULL {
            let newestMs = sqlite3_column_int64(statement, 1)
            newest = Schema.timestampToDate(newestMs)
        }

        return (oldest, newest)
    }

    /// Set encryption key for database using SQLCipher PRAGMA key
    /// NOTE: This requires SQLCipher to be compiled into the SQLite3 library
    private func setEncryptionKey() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Check if encryption is enabled in UserDefaults
        // Default to false (disabled) - user must explicitly enable it during onboarding
        let encryptionEnabled = UserDefaults.standard.object(forKey: "encryptionEnabled") as? Bool ?? false

        // For unencrypted databases, simply don't set any PRAGMA key.
        // SQLCipher will operate as regular SQLite when no key is provided on a new/plaintext database.
        if !encryptionEnabled {
            print("[DEBUG] Database encryption disabled - no key set")
            return
        }

        // Get or generate encryption key from Keychain
        let keychainService = AppPaths.keychainService
        let keychainAccount = AppPaths.keychainAccount

        var keyData: Data
        do {
            keyData = try loadKeyFromKeychain(service: keychainService, account: keychainAccount)
            print("[DEBUG] Loaded existing database encryption key from Keychain")
        } catch {
            // Generate new key
            let key = SymmetricKey(size: .bits256)
            keyData = key.withUnsafeBytes { Data($0) }
            try saveKeyToKeychain(keyData, service: keychainService, account: keychainAccount)
            print("[DEBUG] Generated and saved new database encryption key to Keychain")
        }

        // Set key using PRAGMA key (SQLCipher)
        // Convert key data to hex string for PRAGMA
        let keyHex = keyData.map { String(format: "%02hhx", $0) }.joined()
        let pragma = "PRAGMA key = \"x'\(keyHex)'\";"

        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, pragma, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            print("[ERROR] Failed to set database encryption key: \(message)")
            print("[WARNING] SQLCipher may not be available - falling back to unencrypted database")
            // Don't throw - fall back to unencrypted database
            return
        }

        print("[DEBUG] Database encryption key set successfully")
    }

    /// Save encryption key to Keychain
    private func saveKeyToKeychain(_ key: Data, service: String, account: String) throws {
        // Use kSecAttrAccessibleAfterFirstUnlock with kSecAttrSynchronizable = false
        // This prevents the keychain password prompt on every app launch
        // kSecAttrSynchronizable = false ensures it stays local and doesn't prompt for iCloud Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false  // Don't sync to iCloud, stay local
        ]

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DatabaseError.connectionFailed(underlying: "Failed to save encryption key to Keychain (status: \(status))")
        }
    }

    /// Load encryption key from Keychain
    private func loadKeyFromKeychain(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw DatabaseError.connectionFailed(underlying: "Failed to load encryption key from Keychain")
        }
        return data
    }

    // MARK: - Static Keychain Setup (for onboarding)

    /// Setup encryption key in Keychain during onboarding
    /// Call this when user selects "Yes" for encryption and clicks Continue
    public static func setupEncryptionKeychain() throws {
        let keychainService = AppPaths.keychainService
        let keychainAccount = AppPaths.keychainAccount

        // Check if key already exists (without retrieving data to avoid prompts)
        let checkQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let checkStatus = SecItemCopyMatching(checkQuery as CFDictionary, &result)

        if checkStatus == errSecSuccess {
            // Key already exists, no need to create again
            print("[DEBUG] Encryption key already exists in Keychain, skipping setup")
            return
        }

        // Generate new key
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        // Use kSecAttrAccessibleAfterFirstUnlock directly (without SecAccessControlCreateWithFlags)
        // This allows access without prompting after the device is unlocked
        // kSecAttrSynchronizable = false ensures it stays local and doesn't prompt for iCloud Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false  // Don't sync to iCloud, stay local
        ]

        // Delete existing item first (in case of partial state)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "com.retrace.keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to save encryption key to Keychain (status: \(status))"])
        }

        print("[DEBUG] Generated and saved new database encryption key to Keychain during onboarding")
    }

    /// Verify we can read the encryption key from Keychain
    /// This triggers the keychain access prompt if needed, so it's best called immediately after setup
    public static func verifyEncryptionKeychain() throws -> Bool {
        let keychainService = AppPaths.keychainService
        let keychainAccount = AppPaths.keychainAccount

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let _ = result as? Data else {
            throw NSError(domain: "com.retrace.keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to verify encryption key in Keychain (status: \(status))"])
        }

        return true
    }

    /// Delete the encryption key from Keychain (useful for resetting)
    public static func deleteEncryptionKeychain() {
        let keychainService = AppPaths.keychainService
        let keychainAccount = AppPaths.keychainAccount

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        let status = SecItemDelete(deleteQuery as CFDictionary)
        if status == errSecSuccess {
            print("[DEBUG] Deleted encryption key from Keychain")
        } else if status == errSecItemNotFound {
            print("[DEBUG] No encryption key found in Keychain to delete")
        } else {
            print("[ERROR] Failed to delete encryption key from Keychain (status: \(status))")
        }
    }
}
