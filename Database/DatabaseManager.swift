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

    /// Check if the database has been fully initialized
    public func isReady() -> Bool {
        isInitialized && db != nil
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
        Log.debug("[DatabaseManager] initialize() started", category: .database)

        // Expand tilde in path if present
        let expandedPath = NSString(string: databasePath).expandingTildeInPath
        Log.debug("[DatabaseManager] Expanded path: \(expandedPath)", category: .database)

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
        Log.debug("[DatabaseManager] Opening database...", category: .database)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(expandedPath, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw DatabaseError.connectionFailed(underlying: errorMsg)
        }
        Log.debug("[DatabaseManager] Database opened successfully", category: .database)

        // Set encryption key (SQLCipher) if encryption is enabled and not in-memory
        if !isInMemory {
            try await setEncryptionKey()
        }

        // Enable foreign keys and WAL mode
        Log.debug("[DatabaseManager] Executing pragmas...", category: .database)
        try executePragmas()
        Log.debug("[DatabaseManager] Pragmas executed", category: .database)

        // Run migrations
        Log.debug("[DatabaseManager] Running migrations...", category: .database)
        let migrationRunner = MigrationRunner(db: db!)
        try await migrationRunner.runMigrations()
        Log.debug("[DatabaseManager] Migrations complete", category: .database)

        // Offset AUTOINCREMENT to avoid collision with Rewind's frozen data
        Log.debug("[DatabaseManager] Setting AUTOINCREMENT offset...", category: .database)
        try await offsetAutoincrementFromRewind()
        Log.debug("[DatabaseManager] AUTOINCREMENT offset complete", category: .database)

        isInitialized = true
        Log.info("[DatabaseManager] Database initialized at: \(expandedPath)", category: .database)
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
        Log.info("[DatabaseManager] Database closed", category: .database)
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

    public func getFrameWithVideoInfoByID(id: FrameID) async throws -> FrameWithVideoInfo? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByIDWithVideoInfo(db: db, id: id)
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

    /// Delete frames newer than the specified date (for quick delete feature)
    public func deleteFrames(newerThan date: Date) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.deleteNewerThan(db: db, date: date)
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

    /// Get all distinct dates that have frames (for calendar display)
    public func getDistinctDates() async throws -> [Date] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getDistinctDates(db: db)
    }

    /// Get distinct hours for a specific date that have frames
    public func getDistinctHoursForDate(_ date: Date) async throws -> [Date] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getDistinctHoursForDate(db: db, date: date)
    }

    public func frameExistsAtTimestamp(_ timestamp: Date) async throws -> Bool {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.existsAtTimestamp(db: db, timestamp: timestamp)
    }

    public func getFrameIDAtTimestamp(_ timestamp: Date) async throws -> Int64? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getFrameIDAtTimestamp(db: db, timestamp: timestamp)
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
                sc.c0,
                n.frameId
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

            // Column 9: frameId for debugging
            let nodeFrameId = sqlite3_column_int64(statement, 9)

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
                frameId: nodeFrameId,
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

    public func updateVideoSegment(id: Int64, width: Int, height: Int, fileSize: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SegmentQueries.update(db: db, id: id, width: width, height: height, fileSize: fileSize)
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

    // MARK: - Unfinalised Video Operations (Multi-Resolution Support)

    public func getUnfinalisedVideoByResolution(width: Int, height: Int) async throws -> UnfinalisedVideo? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getUnfinalisedByResolution(db: db, width: width, height: height)
    }

    public func getAllUnfinalisedVideos() async throws -> [UnfinalisedVideo] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getAllUnfinalised(db: db)
    }

    public func markVideoFinalized(id: Int64, frameCount: Int, fileSize: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SegmentQueries.markFinalized(db: db, id: id, frameCount: frameCount, fileSize: fileSize)
    }

    public func finalizeOrphanedVideos(activeVideoIDs: Set<Int64>) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.finalizeOrphanedVideos(db: db, activeVideoIDs: activeVideoIDs)
    }

    public func updateVideoSegment(id: Int64, width: Int, height: Int, fileSize: Int64, frameCount: Int) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SegmentQueries.update(db: db, id: id, width: width, height: height, fileSize: fileSize, frameCount: frameCount)
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

    public func getSegments(
        bundleID: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) async throws -> [Segment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getByBundleIDAndTimeRange(
            db: db,
            bundleID: bundleID,
            from: startDate,
            to: endDate,
            limit: limit,
            offset: offset
        )
    }

    /// Get segments filtered by bundle ID, time range, and window name or domain
    /// For browsers, filters by domain extracted from browserUrl; for other apps, filters by windowName
    public func getSegments(
        bundleID: String,
        windowNameOrDomain: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) async throws -> [Segment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getByBundleIDAndWindowName(
            db: db,
            bundleID: bundleID,
            windowNameOrDomain: windowNameOrDomain,
            from: startDate,
            to: endDate,
            limit: limit,
            offset: offset
        )
    }

    public func getAppUsageStats(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(bundleID: String, duration: TimeInterval, uniqueItemCount: Int)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getAppUsageStats(db: db, from: startDate, to: endDate)
    }

    public func getWindowUsageForApp(
        bundleID: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, duration: TimeInterval)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getWindowUsageForApp(db: db, bundleID: bundleID, from: startDate, to: endDate)
    }

    public func getBrowserTabUsage(
        bundleID: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, browserUrl: String?, duration: TimeInterval)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getBrowserTabUsage(db: db, bundleID: bundleID, from: startDate, to: endDate)
    }

    public func getBrowserTabUsageForDomain(
        bundleID: String,
        domain: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, browserUrl: String?, duration: TimeInterval)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getBrowserTabUsageForDomain(db: db, bundleID: bundleID, domain: domain, from: startDate, to: endDate)
    }

    public func deleteSegment(id: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try AppSegmentQueries.delete(db: db, id: id)
    }

    /// Get total captured duration across all segments in seconds
    public func getTotalCapturedDuration() async throws -> TimeInterval {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getTotalCapturedDuration(db: db)
    }

    /// Get captured duration for segments starting after a given date
    public func getCapturedDurationAfter(date: Date) async throws -> TimeInterval {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getCapturedDurationAfter(db: db, date: date)
    }

    // MARK: - Tag Operations

    /// Get all tags
    public func getAllTags() async throws -> [Tag] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT id, name FROM tag ORDER BY name ASC;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var tags: [Tag] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard let namePtr = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: namePtr)
            tags.append(Tag(id: TagID(value: id), name: name))
        }

        return tags
    }

    /// Create a new tag
    public func createTag(name: String) async throws -> Tag {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "INSERT INTO tag (name) VALUES (?);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let id = sqlite3_last_insert_rowid(db)
        return Tag(id: TagID(value: id), name: name)
    }

    /// Get a tag by name
    public func getTag(name: String) async throws -> Tag? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT id, name FROM tag WHERE name = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let id = sqlite3_column_int64(statement, 0)
        guard let namePtr = sqlite3_column_text(statement, 1) else { return nil }
        let tagName = String(cString: namePtr)
        return Tag(id: TagID(value: id), name: tagName)
    }

    /// Add a tag to a segment
    public func addTagToSegment(segmentId: SegmentID, tagId: TagID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "INSERT OR IGNORE INTO segment_tag (segmentId, tagId) VALUES (?, ?);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, segmentId.value)
        sqlite3_bind_int64(statement, 2, tagId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let changes = sqlite3_changes(db)
        Log.debug("[DB] addTagToSegment: segmentId=\(segmentId.value), tagId=\(tagId.value), rows affected=\(changes)", category: .database)
    }

    /// Remove a tag from a segment
    public func removeTagFromSegment(segmentId: SegmentID, tagId: TagID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "DELETE FROM segment_tag WHERE segmentId = ? AND tagId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, segmentId.value)
        sqlite3_bind_int64(statement, 2, tagId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Get all tags for a segment
    public func getTagsForSegment(segmentId: SegmentID) async throws -> [Tag] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT t.id, t.name
            FROM tag t
            JOIN segment_tag st ON t.id = st.tagId
            WHERE st.segmentId = ?
            ORDER BY t.name ASC;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, segmentId.value)

        var tags: [Tag] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard let namePtr = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: namePtr)
            tags.append(Tag(id: TagID(value: id), name: name))
        }

        return tags
    }

    /// Get all segment IDs that have the "hidden" tag
    public func getHiddenSegmentIds() async throws -> Set<SegmentID> {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT st.segmentId
            FROM segment_tag st
            JOIN tag t ON st.tagId = t.id
            WHERE t.name = 'hidden';
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var segmentIds: Set<SegmentID> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            segmentIds.insert(SegmentID(value: id))
        }

        return segmentIds
    }

    /// Get a map of segment IDs to their tag IDs for efficient filtering
    public func getSegmentTagsMap() async throws -> [Int64: Set<Int64>] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT segmentId, tagId FROM segment_tag;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var map: [Int64: Set<Int64>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let segmentId = sqlite3_column_int64(statement, 0)
            let tagId = sqlite3_column_int64(statement, 1)

            if map[segmentId] == nil {
                map[segmentId] = []
            }
            map[segmentId]!.insert(tagId)
        }

        return map
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

    // MARK: - Daily Metrics Operations

    /// Record a single metric event (timeline open, search, text copy)
    public func recordMetricEvent(
        metricType: DailyMetricsQueries.MetricType,
        timestamp: Date = Date(),
        metadata: String? = nil
    ) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try DailyMetricsQueries.recordEvent(
            db: db,
            metricType: metricType,
            timestamp: timestamp,
            metadata: metadata
        )
    }

    /// Get daily counts for a metric type (for graphs)
    /// Returns array of (date, count) tuples sorted by date ascending
    public func getDailyMetrics(
        metricType: DailyMetricsQueries.MetricType,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try DailyMetricsQueries.getDailyCounts(
            db: db,
            metricType: metricType,
            from: startDate,
            to: endDate
        )
    }

    /// Get total count of a metric over a date range
    public func getDailyMetricCount(
        metricType: DailyMetricsQueries.MetricType,
        from startDate: Date,
        to endDate: Date
    ) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try DailyMetricsQueries.getTotalCount(
            db: db,
            metricType: metricType,
            from: startDate,
            to: endDate
        )
    }

    /// Get daily screen time totals (for graphs)
    /// Returns array of (date, totalSeconds) tuples sorted by date ascending
    public func getDailyScreenTime(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getDailyScreenTime(
            db: db,
            from: startDate,
            to: endDate
        )
    }

    // MARK: - Statistics

    public func getStatistics() async throws -> DatabaseStatistics {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let frameCount = try FrameQueries.getCount(db: db)
        let segmentCount = try SegmentQueries.getCount(db: db) // Video segments
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

    /// Get app session count (from segment table, not video table)
    public func getAppSessionCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getCount(db: db)
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

        Log.info("[DatabaseManager] Database WAL checkpointed and truncated", category: .database)
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

        Log.info("[DatabaseManager] Database vacuumed successfully", category: .database)
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

        Log.info("[DatabaseManager] Database statistics analyzed successfully", category: .database)
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
                Log.debug("[DatabaseManager] AUTOINCREMENT already initialized, skipping offset", category: .database)
                return
            }
        }

        // Query Rewind's database for max IDs
        let rewindDBPath = "~/Library/Application Support/com.memoryvault.MemoryVault/rewind.db"
        let expandedRewindPath = NSString(string: rewindDBPath).expandingTildeInPath

        // Check if Rewind database exists
        guard FileManager.default.fileExists(atPath: expandedRewindPath) else {
            Log.debug("[DatabaseManager] Rewind database not found, skipping AUTOINCREMENT offset", category: .database)
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
            Log.debug("[DatabaseManager] Failed to open Rewind database, skipping AUTOINCREMENT offset", category: .database)
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

        Log.debug("[DatabaseManager] Rewind max IDs - frame: \(maxFrameID), video: \(maxVideoID)", category: .database)

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
                    Log.debug("[DatabaseManager] Set frame AUTOINCREMENT to start at \(maxFrameID + 1)", category: .database)
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
                    Log.debug("[DatabaseManager] Set video AUTOINCREMENT to start at \(maxVideoID + 1)", category: .database)
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
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let encryptionEnabled = defaults.object(forKey: "encryptionEnabled") as? Bool ?? false

        // For unencrypted databases, simply don't set any PRAGMA key.
        // SQLCipher will operate as regular SQLite when no key is provided on a new/plaintext database.
        if !encryptionEnabled {
            Log.debug("[DatabaseManager] Database encryption disabled - no key set", category: .database)
            return
        }

        // Get or generate encryption key from Keychain
        let keychainService = AppPaths.keychainService
        let keychainAccount = AppPaths.keychainAccount

        var keyData: Data
        do {
            keyData = try loadKeyFromKeychain(service: keychainService, account: keychainAccount)
            Log.debug("[DatabaseManager] Loaded existing database encryption key from Keychain", category: .database)
        } catch {
            // Generate new key
            let key = SymmetricKey(size: .bits256)
            keyData = key.withUnsafeBytes { Data($0) }
            try saveKeyToKeychain(keyData, service: keychainService, account: keychainAccount)
            Log.debug("[DatabaseManager] Generated and saved new database encryption key to Keychain", category: .database)
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
            Log.error("[DatabaseManager] Failed to set database encryption key: \(message)", category: .database)
            Log.warning("[DatabaseManager] SQLCipher may not be available - falling back to unencrypted database", category: .database)
            // Don't throw - fall back to unencrypted database
            return
        }

        Log.debug("[DatabaseManager] Database encryption key set successfully", category: .database)
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
            Log.debug("[DatabaseManager] Encryption key already exists in Keychain, skipping setup", category: .database)
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

        Log.debug("[DatabaseManager] Generated and saved new database encryption key to Keychain during onboarding", category: .database)
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
            Log.debug("[DatabaseManager] Deleted encryption key from Keychain", category: .database)
        } else if status == errSecItemNotFound {
            Log.debug("[DatabaseManager] No encryption key found in Keychain to delete", category: .database)
        } else {
            Log.error("[DatabaseManager] Failed to delete encryption key from Keychain (status: \(status))", category: .database)
        }
    }

    // MARK: - Processing Queue Operations

    /// Enqueue a frame for OCR processing
    /// Only enqueues frames with processingStatus = 0 (pending)
    public func enqueueFrameForProcessing(frameID: Int64, priority: Int = 0) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Only enqueue if processingStatus = 0 (pending)
        let sql = """
            INSERT INTO processing_queue (frameId, enqueuedAt, priority, retryCount)
            SELECT ?, ?, ?, 0
            FROM frame
            WHERE id = ? AND processingStatus = 0;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, frameID)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(priority))
        sqlite3_bind_int64(stmt, 4, frameID)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        // Check if any row was actually inserted
        let changes = sqlite3_changes(db)
        if changes == 0 {
            throw DatabaseError.queryFailed(query: sql, underlying: "Frame \(frameID) not eligible for processing (processingStatus != 0)")
        }
    }

    /// Dequeue the next frame for processing (highest priority, oldest first)
    /// Only dequeues frames with processingStatus = 0 (pending)
    /// Returns tuple of (queueID, frameID, retryCount) or nil if queue is empty
    public func dequeueFrameForProcessing() async throws -> (queueID: Int64, frameID: Int64, retryCount: Int)? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Get highest priority item where frame still has processingStatus = 0
        let selectSql = """
            SELECT pq.id, pq.frameId, pq.retryCount
            FROM processing_queue pq
            INNER JOIN frame f ON pq.frameId = f.id
            WHERE f.processingStatus = 0
            ORDER BY pq.priority DESC, pq.enqueuedAt ASC
            LIMIT 1;
        """

        var selectStmt: OpaquePointer?
        defer { sqlite3_finalize(selectStmt) }

        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: selectSql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        guard sqlite3_step(selectStmt) == SQLITE_ROW else {
            return nil // Queue empty
        }

        let queueID = sqlite3_column_int64(selectStmt, 0)
        let frameID = sqlite3_column_int64(selectStmt, 1)
        let retryCount = Int(sqlite3_column_int(selectStmt, 2))

        // Delete from queue
        let deleteSql = "DELETE FROM processing_queue WHERE id = ?;"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }

        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: deleteSql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(deleteStmt, 1, queueID)

        guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: deleteSql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return (queueID: queueID, frameID: frameID, retryCount: retryCount)
    }

    /// Get the current processing queue depth
    public func getProcessingQueueDepth() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT COUNT(*) FROM processing_queue;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get frame IDs that were in "processing" status (crashed during OCR)
    public func getCrashedProcessingFrameIDs() async throws -> [Int64] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // processingStatus = 1 means "processing" (crashed)
        let sql = "SELECT id FROM frame WHERE processingStatus = 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        var frameIDs: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            frameIDs.append(sqlite3_column_int64(stmt, 0))
        }

        return frameIDs
    }

    /// Retry a frame by re-adding it to the processing queue with incremented retry count
    public func retryFrameProcessing(frameID: Int64, retryCount: Int, errorMessage: String) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            INSERT INTO processing_queue (frameId, enqueuedAt, priority, retryCount, lastError)
            VALUES (?, ?, 0, ?, ?);
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_bind_int64(stmt, 1, frameID)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(retryCount))
        sqlite3_bind_text(stmt, 4, errorMessage, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Update frame processing status
    public func updateFrameProcessingStatus(frameID: Int64, status: Int) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "UPDATE frame SET processingStatus = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int(stmt, 1, Int32(status))
        sqlite3_bind_int64(stmt, 2, frameID)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Get the processing status for a specific frame
    /// Returns nil if the frame doesn't exist
    public func getFrameProcessingStatus(frameID: Int64) async throws -> Int? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT processingStatus FROM frame WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, frameID)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil // Frame not found
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Mark frame as readable from video file (processingStatus 4 -> 0)
    /// Called when frame is confirmed to be written to video file
    public func markFrameReadable(frameID: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Only update if status is 4 (not yet readable)
        let sql = "UPDATE frame SET processingStatus = 0 WHERE id = ? AND processingStatus = 4;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, frameID)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Get processing status for multiple frames in a single query
    /// Returns dictionary of frameID -> processingStatus (0=pending, 1=processing, 2=completed, 3=failed, 4=not yet readable)
    public func getFrameProcessingStatuses(frameIDs: [Int64]) async throws -> [Int64: Int] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        guard !frameIDs.isEmpty else {
            return [:]
        }

        // Build parameterized query for batch lookup
        let placeholders = frameIDs.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT id, processingStatus FROM frame WHERE id IN (\(placeholders));"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        // Bind all frame IDs
        for (index, frameID) in frameIDs.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), frameID)
        }

        var results: [Int64: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let frameID = sqlite3_column_int64(stmt, 0)
            let status = Int(sqlite3_column_int(stmt, 1))
            results[frameID] = status
        }

        return results
    }

    /// Check if a frame is currently in the processing queue
    public func isFrameInProcessingQueue(frameID: Int64) async throws -> Bool {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT 1 FROM processing_queue WHERE frameId = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, frameID)

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Get the queue position for a frame (1-based, where 1 = next to be processed)
    /// Returns nil if the frame is not in the queue
    /// Queue is ordered by priority DESC, then enqueuedAt ASC
    public func getFrameQueuePosition(frameID: Int64) async throws -> Int? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Get the priority and enqueuedAt for the target frame
        let targetSql = "SELECT priority, enqueuedAt FROM processing_queue WHERE frameId = ?;"
        var targetStmt: OpaquePointer?
        defer { sqlite3_finalize(targetStmt) }

        guard sqlite3_prepare_v2(db, targetSql, -1, &targetStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: targetSql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(targetStmt, 1, frameID)

        guard sqlite3_step(targetStmt) == SQLITE_ROW else {
            return nil // Frame not in queue
        }

        let priority = sqlite3_column_int(targetStmt, 0)
        let enqueuedAt = sqlite3_column_double(targetStmt, 1)

        // Count how many frames are ahead in the queue (higher priority, or same priority but earlier enqueue time)
        let positionSql = """
            SELECT COUNT(*) + 1 FROM processing_queue
            WHERE priority > ? OR (priority = ? AND enqueuedAt < ?);
        """
        var positionStmt: OpaquePointer?
        defer { sqlite3_finalize(positionStmt) }

        guard sqlite3_prepare_v2(db, positionSql, -1, &positionStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: positionSql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int(positionStmt, 1, priority)
        sqlite3_bind_int(positionStmt, 2, priority)
        sqlite3_bind_double(positionStmt, 3, enqueuedAt)

        guard sqlite3_step(positionStmt) == SQLITE_ROW else {
            return nil
        }

        return Int(sqlite3_column_int(positionStmt, 0))
    }

    /// Get all frame IDs with pending status (processingStatus=0) that are NOT in the processing queue
    /// Used to find frames that need to be re-enqueued for OCR processing
    public func getPendingFrameIDsNotInQueue(limit: Int = 1000) async throws -> [Int64] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT f.id FROM frame f
            LEFT JOIN processing_queue pq ON f.id = pq.frameId
            WHERE f.processingStatus = 0 AND pq.frameId IS NULL
            ORDER BY f.id DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var frameIDs: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            frameIDs.append(sqlite3_column_int64(stmt, 0))
        }

        return frameIDs
    }

    /// Count frames with pending status (processingStatus=0) that are NOT in the processing queue
    public func countPendingFramesNotInQueue() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT COUNT(*) FROM frame f
            LEFT JOIN processing_queue pq ON f.id = pq.frameId
            WHERE f.processingStatus = 0 AND pq.frameId IS NULL;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(stmt, 0))
    }
}
