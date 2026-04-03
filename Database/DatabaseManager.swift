import CryptoKit
import Darwin
import Foundation
import SQLCipher
import Shared

enum SQLiteRuntimeDiagnostics {
    static func summary(db: OpaquePointer?) -> String {
        let version = String(cString: sqlite3_libversion())
        let sourceID = String(cString: sqlite3_sourceid())
        let sourcePrefix = String(sourceID.prefix(18))
        let fts5Enabled = compileOptionEnabled("ENABLE_FTS5")
        let hasCodec = compileOptionEnabled("HAS_CODEC")
        let omitLoadExtension = compileOptionEnabled("OMIT_LOAD_EXTENSION")
        let threadsafe = sqlite3_threadsafe()
        let mainDatabase = mainDatabaseFilename(db: db)
        let openImage = imagePath(forSymbolNamed: "sqlite3_open_v2")
        let prepareImage = imagePath(forSymbolNamed: "sqlite3_prepare_v2")
        let errmsgImage = imagePath(forSymbolNamed: "sqlite3_errmsg")
        let probeResult = fts5ProbeResult(db: db)

        return """
        version=\(version) source=\(sourcePrefix) \
        compile(fts5=\(fts5Enabled),codec=\(hasCodec),omitLoadExtension=\(omitLoadExtension),threadsafe=\(threadsafe)) \
        images(open=\(openImage),prepare=\(prepareImage),errmsg=\(errmsgImage)) \
        mainDb=\(mainDatabase) probe=\(probeResult)
        """
    }

    static func log(label: String, db: OpaquePointer?) {
        Log.info("[\(label)] SQLite runtime: \(summary(db: db))", category: .database)
    }

    private static func compileOptionEnabled(_ option: String) -> Bool {
        option.withCString { sqlite3_compileoption_used($0) == 1 }
    }

    private static func mainDatabaseFilename(db: OpaquePointer?) -> String {
        guard let db else { return "nil" }
        guard let filename = "main".withCString({ sqlite3_db_filename(db, $0) }) else {
            return "unknown"
        }
        return String(cString: filename)
    }

    private static func imagePath(forSymbolNamed symbolName: String) -> String {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, symbolName) else {
            return "unresolved"
        }

        var info = Dl_info()
        guard dladdr(symbol, &info) != 0, let filename = info.dli_fname else {
            return "unresolved"
        }

        return String(cString: filename)
    }

    private static func fts5ProbeResult(db: OpaquePointer?) -> String {
        guard let db else { return "no-db" }

        let tableName = "__retrace_runtime_probe_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let createSQL = "CREATE VIRTUAL TABLE temp.\(tableName) USING fts5(content);"
        var errorMessage: UnsafeMutablePointer<CChar>?

        if sqlite3_exec(db, createSQL, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            return "failed(\(message))"
        }

        sqlite3_free(errorMessage)
        errorMessage = nil

        let dropSQL = "DROP TABLE IF EXISTS temp.\(tableName);"
        if sqlite3_exec(db, dropSQL, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            return "ok/drop-failed(\(message))"
        }

        sqlite3_free(errorMessage)
        return "ok"
    }
}

public struct FrameInPageURLRow: Sendable, Equatable {
    public let order: Int
    public let url: String
    public let nodeID: Int

    public init(order: Int, url: String, nodeID: Int) {
        self.order = order
        self.url = url
        self.nodeID = nodeID
    }
}

public struct FrameInPageURLState: Sendable, Equatable {
    public let mouseX: Double?
    public let mouseY: Double?
    public let scrollX: Double?
    public let scrollY: Double?
    public let videoCurrentTime: Double?

    public init(
        mouseX: Double?,
        mouseY: Double?,
        scrollX: Double?,
        scrollY: Double?,
        videoCurrentTime: Double?
    ) {
        self.mouseX = mouseX
        self.mouseY = mouseY
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.videoCurrentTime = videoCurrentTime
    }
}

public struct PendingNodeRedactionJob: Sendable, Equatable {
    public let frameID: Int64
    public let frameIndex: Int
    public let nodeID: Int
    public let normalizedRect: CGRect

    public init(frameID: Int64, frameIndex: Int, nodeID: Int, normalizedRect: CGRect) {
        self.frameID = frameID
        self.frameIndex = frameIndex
        self.nodeID = nodeID
        self.normalizedRect = normalizedRect
    }
}

public struct PendingFrameDeletionJob: Sendable, Equatable {
    public let frameID: Int64
    public let videoID: Int64
    public let frameIndex: Int

    public init(frameID: Int64, videoID: Int64, frameIndex: Int) {
        self.frameID = frameID
        self.videoID = videoID
        self.frameIndex = frameIndex
    }
}

public struct NativeFrameDeletionResult: Sendable, Equatable {
    public let immediatelyDeletedFrameIDs: [Int64]
    public let scheduledJobs: [PendingFrameDeletionJob]

    public init(
        immediatelyDeletedFrameIDs: [Int64],
        scheduledJobs: [PendingFrameDeletionJob]
    ) {
        self.immediatelyDeletedFrameIDs = immediatelyDeletedFrameIDs
        self.scheduledJobs = scheduledJobs
    }

    public var affectedFrameIDs: [Int64] {
        immediatelyDeletedFrameIDs + scheduledJobs.map(\.frameID)
    }

    public var affectedFrameCount: Int {
        affectedFrameIDs.count
    }
}

public struct VideoFrameDeletion: Sendable, Equatable {
    public let frameID: Int64
    public let frameIndex: Int

    public init(frameID: Int64, frameIndex: Int) {
        self.frameID = frameID
        self.frameIndex = frameIndex
    }
}

public struct VideoFrameRedaction: Sendable, Equatable {
    public let frameID: Int64
    public let frameIndex: Int
    public let targets: [SegmentRedactionTarget]

    public init(frameID: Int64, frameIndex: Int, targets: [SegmentRedactionTarget]) {
        self.frameID = frameID
        self.frameIndex = frameIndex
        self.targets = targets
    }
}

public struct VideoRewritePlan: Sendable, Equatable {
    public let videoID: Int64
    public let operation: SegmentRewriteOperation
    public let deletions: [VideoFrameDeletion]
    public let redactions: [VideoFrameRedaction]

    public init(
        videoID: Int64,
        operation: SegmentRewriteOperation = .partialRewrite,
        deletions: [VideoFrameDeletion] = [],
        redactions: [VideoFrameRedaction] = []
    ) {
        self.videoID = videoID
        self.operation = operation
        self.deletions = deletions
        self.redactions = redactions
    }

    public var hasDeletionTargets: Bool {
        !deletions.isEmpty
    }

    public var hasRedactionTargets: Bool {
        !redactions.isEmpty
    }

    public var deletesWholeVideo: Bool {
        operation == .wholeVideoDelete
    }

    public var hasAnyRewrite: Bool {
        deletesWholeVideo || hasDeletionTargets || hasRedactionTargets
    }

    public var deletionFrameIDs: [Int64] {
        deletions.map(\.frameID)
    }

    public var redactionFrameIDs: [Int64] {
        redactions.map(\.frameID)
    }

    public var blackFrameIndexes: Set<Int> {
        Set(deletions.map(\.frameIndex))
    }

    public var segmentRewritePlan: SegmentRewritePlan {
        SegmentRewritePlan(
            operation: operation,
            blackFrameIndexes: blackFrameIndexes,
            redactions: redactions.map {
                SegmentFrameRedaction(
                    frameID: $0.frameID,
                    frameIndex: $0.frameIndex,
                    targets: $0.targets
                )
            }
        )
    }

    public func droppingRedactions() -> Self {
        Self(videoID: videoID, operation: operation, deletions: deletions, redactions: [])
    }
}

public struct LinkedSegmentComment: Sendable, Equatable {
    public let comment: SegmentComment
    public let preferredSegmentID: SegmentID

    public init(comment: SegmentComment, preferredSegmentID: SegmentID) {
        self.comment = comment
        self.preferredSegmentID = preferredSegmentID
    }
}

/// Task-local diagnostics propagated across actor hops so callers can stamp enqueue time.
public enum DatabaseActorTraceContext {
    @TaskLocal public static var requestEnqueuedAt: CFAbsoluteTime?
    @TaskLocal public static var operationName: String?
    @TaskLocal public static var traceID: String?
}

/// Main database manager implementing DatabaseProtocol
/// Owner: DATABASE agent
///
/// Thread Safety: Actor provides automatic serialization of all database operations
public actor DatabaseManager: DatabaseProtocol {

    // MARK: - Properties

    private var db: OpaquePointer?
    nonisolated public let readConnectionPool: SQLiteReadConnectionPool
    private let databasePath: String
    private let storageRootPath: String
    private let inMemorySharedConnection: SharedSQLiteConnection?
    private var isInitialized = false
    private var dbActorOperationSequence: UInt64 = 0
    private var dbActorOperationStack: [(id: UInt64, name: String, startedAt: CFAbsoluteTime)] = []
    private static let dbActorSlowHoldWarningMs: Double = 200

    /// Public accessor for the database connection (needed for query classes)
    public func getConnection() -> OpaquePointer? {
        db
    }

    /// Check if the database has been fully initialized
    public func isReady() -> Bool {
        isInitialized && db != nil
    }

    // MARK: - DB Actor Occupancy Tracing

    private func withTracedDatabaseOperation<T>(
        _ operation: String,
        warningMs: Double = DatabaseManager.dbActorSlowHoldWarningMs,
        _ block: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        dbActorOperationSequence &+= 1
        let operationID = dbActorOperationSequence
        let startedAt = CFAbsoluteTimeGetCurrent()
        let queueWaitMs = DatabaseActorTraceContext.requestEnqueuedAt.map {
            max(0, (startedAt - $0) * 1000)
        }
        let upstreamTraceID = DatabaseActorTraceContext.traceID ?? "none"
        let upstreamOperation = DatabaseActorTraceContext.operationName ?? operation

        if let queueWaitMs {
            Log.recordLatency(
                "dashboard.db_actor.queue_wait_ms",
                valueMs: queueWaitMs,
                category: .database,
                summaryEvery: 10,
                warningThresholdMs: 400,
                criticalThresholdMs: 2000
            )
            if queueWaitMs >= warningMs {
                Log.warning(
                    "[DB-ACTOR][\(operationID)] QUEUE op='\(operation)' trace=\(upstreamTraceID) upstream='\(upstreamOperation)' waited=\(String(format: "%.1f", queueWaitMs))ms",
                    category: .database
                )
            }
        }

        if let active = dbActorOperationStack.last {
            let activeElapsedMs = (startedAt - active.startedAt) * 1000
            Log.warning(
                "[DB-ACTOR][\(operationID)] ENTER op='\(operation)' while active='\(active.name)' activeID=\(active.id) activeElapsed=\(String(format: "%.1f", activeElapsedMs))ms",
                category: .database
            )
        }

        dbActorOperationStack.append((id: operationID, name: operation, startedAt: startedAt))
        defer {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            if let index = dbActorOperationStack.lastIndex(where: { $0.id == operationID }) {
                dbActorOperationStack.remove(at: index)
            }

            if elapsedMs >= warningMs {
                let activeAfter = dbActorOperationStack.last.map { "\($0.name)#\($0.id)" } ?? "none"
                Log.warning(
                    "[DB-ACTOR][\(operationID)] HOLD op='\(operation)' trace=\(upstreamTraceID) upstream='\(upstreamOperation)' elapsed=\(String(format: "%.1f", elapsedMs))ms activeAfter=\(activeAfter)",
                    category: .database
                )
            }
        }

        return try block(db)
    }

    private func executeImmediateSQL(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Initialization

    public init(databasePath: String, storageRootPath: String = AppPaths.expandedStorageRoot) {
        if Self.isInMemoryDatabasePath(databasePath) {
            let sharedConnection = SharedSQLiteConnection()
            self.readConnectionPool = SQLiteReadConnectionPool(
                label: "retrace",
                sharedConnection: sharedConnection
            )
            self.inMemorySharedConnection = sharedConnection
        } else {
            self.readConnectionPool = SQLiteReadConnectionPool(
                label: "retrace",
                connectionFactory: {
                    try SQLiteReadOnlyConnectionFactory.makeRetraceConnection(databasePath: databasePath)
                }
            )
            self.inMemorySharedConnection = nil
        }

        self.databasePath = databasePath
        self.storageRootPath = NSString(string: storageRootPath).expandingTildeInPath
    }

    /// Convenience initializer for in-memory database (testing)
    public init() {
        let sharedConnection = SharedSQLiteConnection()
        self.readConnectionPool = SQLiteReadConnectionPool(
            label: "retrace",
            sharedConnection: sharedConnection
        )
        self.inMemorySharedConnection = sharedConnection
        self.databasePath = ":memory:"
        self.storageRootPath = AppPaths.expandedStorageRoot
    }

    private nonisolated static func isInMemoryDatabasePath(_ databasePath: String) -> Bool {
        databasePath == ":memory:" || databasePath.contains("mode=memory")
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
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                Log.critical("[DatabaseManager] Failed to create database directory: \(directory)", category: .database, error: error)
                throw DatabaseError.connectionFailed(underlying: "Directory creation failed: \(error.localizedDescription)")
            }
        }

        // Open database
        // Use sqlite3_open_v2 with SQLITE_OPEN_URI to support URI filenames like:
        // file:memdb_xxx?mode=memory&cache=private for unique in-memory databases
        // SQLITE_OPEN_FULLMUTEX enables thread-safe serialized access mode
        Log.debug("[DatabaseManager] Opening database...", category: .database)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(expandedPath, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            Log.critical("[DatabaseManager] Failed to open database at: \(expandedPath) - \(errorMsg)", category: .database)
            throw DatabaseError.connectionFailed(underlying: errorMsg)
        }
        inMemorySharedConnection?.setConnection(db)
        Log.debug("[DatabaseManager] Database opened successfully", category: .database)
        SQLiteRuntimeDiagnostics.log(label: "DatabaseManager/open", db: db)

        // Set encryption key (SQLCipher) if encryption is enabled and not in-memory
        if !isInMemory {
            try await setEncryptionKey()
        }

        // Enable foreign keys and WAL mode
        Log.debug("[DatabaseManager] Executing pragmas...", category: .database)
        try executePragmas()
        Log.debug("[DatabaseManager] Pragmas executed", category: .database)

        Log.debug("[DatabaseManager] Verifying FTS5 runtime support...", category: .database)
        try verifyFTS5RuntimeSupport()
        Log.debug("[DatabaseManager] FTS5 runtime support verified", category: .database)

        // Run migrations
        Log.debug("[DatabaseManager] Running migrations...", category: .database)
        let migrationRunner = MigrationRunner(db: db!)
        try await migrationRunner.runMigrations()
        Log.debug("[DatabaseManager] Migrations complete", category: .database)

        try FrameQueries.ensureInPageURLSchema(db: db!)
        Log.debug("[DatabaseManager] In-page URL schema verified", category: .database)

        // Offset AUTOINCREMENT to avoid collision with Rewind's frozen data
        Log.debug("[DatabaseManager] Setting AUTOINCREMENT offset...", category: .database)
        try await offsetAutoincrementFromRewind()
        Log.debug("[DatabaseManager] AUTOINCREMENT offset complete", category: .database)

        isInitialized = true
        Log.info("[DatabaseManager] Database initialized at: \(expandedPath)", category: .database)
    }

    public func close() async throws {
        guard let db = db else { return }

        await readConnectionPool.close()

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
        inMemorySharedConnection?.setConnection(nil)
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
        try withTracedDatabaseOperation("insert_frame") { db in
            try FrameQueries.insert(db: db, frame: frame)
        }
    }

    public func getFrame(id: FrameID) async throws -> FrameReference? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByID(db: db, id: id)
    }

    public func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference] {
        try withTracedDatabaseOperation("get_frames_time_range") { db in
            try FrameQueries.getByTimeRange(db: db, from: startDate, to: endDate, limit: limit)
        }
    }

    public func getFramesBefore(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        try withTracedDatabaseOperation("get_frames_before") { db in
            try FrameQueries.getFramesBefore(db: db, timestamp: timestamp, limit: limit)
        }
    }

    public func getFramesAfter(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        try withTracedDatabaseOperation("get_frames_after") { db in
            try FrameQueries.getFramesAfter(db: db, timestamp: timestamp, limit: limit)
        }
    }

    public func getMostRecentFrames(limit: Int) async throws -> [FrameReference] {
        try withTracedDatabaseOperation("get_most_recent_frames") { db in
            try FrameQueries.getMostRecent(db: db, limit: limit)
        }
    }

    // MARK: - Optimized Frame Queries with Video Info (Rewind-inspired)

    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        try withTracedDatabaseOperation("get_frames_with_video_info") { db in
            try FrameQueries.getByTimeRangeWithVideoInfo(
                db: db,
                from: startDate,
                to: endDate,
                limit: limit,
                storageRoot: storageRootPath
            )
        }
    }

    public func getMostRecentFramesWithVideoInfo(limit: Int) async throws -> [FrameWithVideoInfo] {
        try withTracedDatabaseOperation("get_most_recent_frames_with_video_info") { db in
            try FrameQueries.getMostRecentWithVideoInfo(
                db: db,
                limit: limit,
                storageRoot: storageRootPath
            )
        }
    }

    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        try withTracedDatabaseOperation("get_frames_with_video_info_before") { db in
            try FrameQueries.getBeforeWithVideoInfo(
                db: db,
                timestamp: timestamp,
                limit: limit,
                storageRoot: storageRootPath
            )
        }
    }

    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        try withTracedDatabaseOperation("get_frames_with_video_info_after") { db in
            try FrameQueries.getAfterWithVideoInfo(
                db: db,
                timestamp: timestamp,
                limit: limit,
                storageRoot: storageRootPath
            )
        }
    }

    public func getFrameWithVideoInfoByID(id: FrameID) async throws -> FrameWithVideoInfo? {
        try withTracedDatabaseOperation("get_frame_with_video_info_by_id") { db in
            try FrameQueries.getByIDWithVideoInfo(
                db: db,
                id: id,
                storageRoot: storageRootPath
            )
        }
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
        try withTracedDatabaseOperation("get_distinct_dates") { db in
            try FrameQueries.getDistinctDates(db: db)
        }
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

    public func updateFrameMetadata(frameID: FrameID, metadataJSON: String?) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try FrameQueries.updateMetadata(db: db, frameId: frameID.value, metadataJSON: metadataJSON)
    }

    public func getFrameMetadata(frameID: FrameID) async throws -> String? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getMetadata(db: db, frameId: frameID.value)
    }

    public func replaceFrameInPageURLData(
        frameID: FrameID,
        state: FrameInPageURLState?,
        rows: [FrameInPageURLRow]
    ) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try FrameQueries.replaceInPageURLData(
            db: db,
            frameId: frameID.value,
            state: state,
            rows: rows
        )
    }

    public func getFrameInPageURLRows(frameID: FrameID) async throws -> [FrameInPageURLRow] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getInPageURLRows(db: db, frameId: frameID.value)
    }

    public func getFrameInPageURLState(frameID: FrameID) async throws -> FrameInPageURLState? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getInPageURLState(db: db, frameId: frameID.value)
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
                CASE WHEN n.encryptedText IS NOT NULL THEN 1 ELSE 0 END AS isRedacted,
                CASE
                    WHEN n.encryptedText IS NOT NULL THEN printf('%.*c', n.textLength, ' ')
                    ELSE SUBSTR(COALESCE(sc.c0, '') || COALESCE(sc.c1, ''), n.textOffset + 1, n.textLength)
                END AS nodeText,
                n.encryptedText,
                n.frameId
            FROM node n
            LEFT JOIN doc_segment ds ON n.frameId = ds.frameId
            LEFT JOIN searchRanking_content sc ON ds.docid = sc.id
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
            let nodeOrder = Int(sqlite3_column_int(statement, 1))
            let leftX = sqlite3_column_double(statement, 4)
            let topY = sqlite3_column_double(statement, 5)
            let width = sqlite3_column_double(statement, 6)
            let height = sqlite3_column_double(statement, 7)
            let isRedacted = sqlite3_column_int(statement, 8) != 0

            let text = sqlite3_column_text(statement, 9).map { String(cString: $0) } ?? ""
            let encryptedText = sqlite3_column_text(statement, 10).map { String(cString: $0) }

            // Column 11: frameId for debugging
            let nodeFrameId = sqlite3_column_int64(statement, 11)

            results.append(OCRNodeWithText(
                id: id,
                nodeOrder: nodeOrder,
                frameId: nodeFrameId,
                x: leftX,
                y: topY,
                width: width,
                height: height,
                text: text,
                encryptedText: encryptedText,
                isRedacted: isRedacted
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

    public func findVideoSegment(relativePathStem: String) async throws -> VideoSegment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.findByRelativePathStem(db: db, stem: relativePathStem)
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
        try withTracedDatabaseOperation("get_total_storage_bytes") { db in
            try SegmentQueries.getTotalStorageBytes(db: db)
        }
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
        try withTracedDatabaseOperation("insert_document") { db in
            try DocumentQueries.insert(db: db, document: document)
        }
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

    /// Update segment browserURL.
    /// - Parameter onlyIfNull: When true, updates only if browserUrl is currently NULL.
    ///   When false, allows correcting a previously-written URL.
    public func updateSegmentBrowserURL(
        id: Int64,
        browserURL: String,
        onlyIfNull: Bool = true
    ) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try AppSegmentQueries.updateBrowserURL(
            db: db,
            id: id,
            browserURL: browserURL,
            onlyIfNull: onlyIfNull
        )
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

    private nonisolated func withDashboardReadConnection<T>(
        operation: String,
        _ body: @escaping @Sendable (OpaquePointer) throws -> T
    ) async throws -> T {
        try await readConnectionPool.withConnection(operation: operation) { connection in
            guard let db = connection.getConnection() else {
                throw DatabaseError.connectionFailed(underlying: "Read connection unavailable")
            }
            return try body(db)
        }
    }

    nonisolated public func getAppUsageStats(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(bundleID: String, duration: TimeInterval, uniqueItemCount: Int)] {
        try await withDashboardReadConnection(operation: "get_app_usage_stats") { db in
            try AppSegmentQueries.getAppUsageStats(
                db: db,
                from: startDate,
                to: endDate
            )
        }
    }

    public func getWindowUsageForApp(
        bundleID: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int? = nil
    ) async throws -> [(windowName: String?, isWebsite: Bool, duration: TimeInterval, tabCount: Int?, totalCount: Int, totalDuration: TimeInterval)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getWindowUsageForApp(
            db: db,
            bundleID: bundleID,
            from: startDate,
            to: endDate,
            limit: limit
        )
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

        // Capture linked comments before deleting the segment.
        // The FK on segment_comment_link cascades link deletion; we then clean orphan comments.
        let linkedCommentIDs = try getCommentIDsForSegment(db: db, segmentId: id)
        try AppSegmentQueries.delete(db: db, id: id)

        // Best-effort orphan cleanup after this segment's links are removed.
        for commentID in linkedCommentIDs {
            try cleanupOrphanedCommentIfNeeded(db: db, commentId: commentID)
        }
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

    /// Delete a tag entirely (CASCADE will remove all segment associations)
    public func deleteTag(tagId: TagID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "DELETE FROM tag WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, tagId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Get the count of segments that have a specific tag
    public func getSegmentCountForTag(tagId: TagID) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT COUNT(*) FROM segment_tag WHERE tagId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, tagId.value)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return Int(sqlite3_column_int64(statement, 0))
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

    /// Get a map of segment IDs to linked comment counts for tape-level comment indicators.
    public func getSegmentCommentCountsMap() async throws -> [Int64: Int] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT segmentId, COUNT(*)
            FROM segment_comment_link
            GROUP BY segmentId;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var map: [Int64: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let segmentId = sqlite3_column_int64(statement, 0)
            let count = Int(sqlite3_column_int64(statement, 1))
            map[segmentId] = count
        }

        return map
    }

    // MARK: - Segment Comment Operations

    /// Create a new long-form comment
    public func createSegmentComment(
        body: String,
        author: String,
        attachments: [SegmentCommentAttachment] = [],
        frameID: FrameID? = nil
    ) async throws -> SegmentComment {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let timestamp = Schema.currentTimestamp()
        let attachmentsJSON = try encodeCommentAttachments(attachments)
        let sql = """
            INSERT INTO segment_comment (body, author, attachmentsJson, frameId, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, body, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, author, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, attachmentsJSON, -1, SQLITE_TRANSIENT)
        if let frameID {
            sqlite3_bind_int64(statement, 4, frameID.value)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_int64(statement, 5, timestamp)
        sqlite3_bind_int64(statement, 6, timestamp)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let id = sqlite3_last_insert_rowid(db)
        guard let comment = try getSegmentCommentByID(db: db, commentID: id) else {
            throw DatabaseError.recordNotFound(table: "segment_comment", id: String(id))
        }
        return comment
    }

    /// Update an existing comment body, author, and attachments
    public func updateSegmentComment(
        commentId: SegmentCommentID,
        body: String,
        author: String,
        attachments: [SegmentCommentAttachment]
    ) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let attachmentsJSON = try encodeCommentAttachments(attachments)
        let updatedAt = Schema.currentTimestamp()
        let sql = """
            UPDATE segment_comment
            SET body = ?, author = ?, attachmentsJson = ?, updatedAt = ?
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, body, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, author, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, attachmentsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 4, updatedAt)
        sqlite3_bind_int64(statement, 5, commentId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Delete a comment and all links, then best-effort cleanup attachment files
    public func deleteSegmentComment(commentId: SegmentCommentID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let attachments = try getCommentAttachments(db: db, commentId: commentId.value)
        try deleteCommentRow(db: db, commentId: commentId.value)
        cleanupAttachmentFiles(attachments)
    }

    /// Link an existing comment to a segment
    public func addCommentToSegment(segmentId: SegmentID, commentId: SegmentCommentID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "INSERT OR IGNORE INTO segment_comment_link (commentId, segmentId) VALUES (?, ?);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, commentId.value)
        sqlite3_bind_int64(statement, 2, segmentId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Remove a segment-comment link and auto-delete orphaned comments
    public func removeCommentFromSegment(segmentId: SegmentID, commentId: SegmentCommentID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "DELETE FROM segment_comment_link WHERE segmentId = ? AND commentId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, segmentId.value)
        sqlite3_bind_int64(statement, 2, commentId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        // If this was the last link, delete the now-orphaned comment and clean attachments.
        try cleanupOrphanedCommentIfNeeded(db: db, commentId: commentId.value)
    }

    /// Get all comments linked to a segment
    public func getCommentsForSegment(segmentId: SegmentID) async throws -> [SegmentComment] {
        try withTracedDatabaseOperation(
            "get_comments_for_segment",
            warningMs: 120
        ) { db in
            let sql = """
                SELECT c.id, c.body, c.author, c.attachmentsJson, c.frameId, c.createdAt, c.updatedAt
                FROM segment_comment c
                JOIN segment_comment_link scl ON c.id = scl.commentId
                WHERE scl.segmentId = ?
                ORDER BY c.createdAt ASC, c.id ASC;
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

            var comments: [SegmentComment] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                comments.append(parseSegmentComment(statement: statement!))
            }

            return comments
        }
    }

    /// Get all unique comments linked to any of the provided segments.
    /// If a comment is linked to multiple requested segments, the earliest requested segment
    /// becomes the preferred fallback segment for navigation.
    public func getCommentsForSegments(segmentIds: [SegmentID]) async throws -> [LinkedSegmentComment] {
        let orderedSegmentIDs = segmentIds.uniquePreservingOrder()
        guard !orderedSegmentIDs.isEmpty else { return [] }

        return try withTracedDatabaseOperation(
            "get_comments_for_segments",
            warningMs: 120
        ) { db in
            let valuesClause = orderedSegmentIDs
                .enumerated()
                .map { _ in "(?, ?)" }
                .joined(separator: ", ")
            let sql = """
                WITH requested_segments(segmentId, ordinal) AS (
                    VALUES \(valuesClause)
                ),
                matched_comments AS (
                    SELECT
                        c.id,
                        c.body,
                        c.author,
                        c.attachmentsJson,
                        c.frameId,
                        c.createdAt,
                        c.updatedAt,
                        rs.segmentId AS preferredSegmentId,
                        rs.ordinal AS preferredOrdinal
                    FROM requested_segments rs
                    JOIN segment_comment_link scl ON scl.segmentId = rs.segmentId
                    JOIN segment_comment c ON c.id = scl.commentId
                ),
                preferred_segments AS (
                    SELECT
                        id AS commentId,
                        MIN(preferredOrdinal) AS preferredOrdinal
                    FROM matched_comments
                    GROUP BY id
                )
                SELECT
                    mc.id,
                    mc.body,
                    mc.author,
                    mc.attachmentsJson,
                    mc.frameId,
                    mc.createdAt,
                    mc.updatedAt,
                    mc.preferredSegmentId
                FROM matched_comments mc
                JOIN preferred_segments ps
                    ON ps.commentId = mc.id
                    AND ps.preferredOrdinal = mc.preferredOrdinal
                ORDER BY mc.createdAt ASC, mc.id ASC;
                """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(
                    query: sql,
                    underlying: String(cString: sqlite3_errmsg(db))
                )
            }

            var bindIndex: Int32 = 1
            for (ordinal, segmentID) in orderedSegmentIDs.enumerated() {
                sqlite3_bind_int64(statement, bindIndex, segmentID.value)
                bindIndex += 1
                sqlite3_bind_int64(statement, bindIndex, Int64(ordinal))
                bindIndex += 1
            }

            var linkedComments: [LinkedSegmentComment] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let comment = parseSegmentComment(statement: statement!)
                let preferredSegmentID = SegmentID(value: sqlite3_column_int64(statement, 7))
                linkedComments.append(
                    LinkedSegmentComment(
                        comment: comment,
                        preferredSegmentID: preferredSegmentID
                    )
                )
            }

            return linkedComments
        }
    }

    /// Get all linked comments with a representative segment context per comment.
    /// This powers the "All Comments" timeline without frame-first fan-out queries.
    public func getAllCommentTimelineEntries() async throws -> [(
        comment: SegmentComment,
        segmentID: SegmentID,
        appBundleID: String?,
        appName: String?,
        browserURL: String?,
        referenceTimestamp: Date
    )] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            WITH chosen_segment AS (
                SELECT scl.commentId, MIN(scl.segmentId) AS segmentId
                FROM segment_comment_link scl
                GROUP BY scl.commentId
            )
            SELECT
                c.id, c.body, c.author, c.attachmentsJson, c.frameId, c.createdAt, c.updatedAt,
                cs.segmentId, s.bundleID, s.browserUrl, s.startDate
            FROM segment_comment c
            JOIN chosen_segment cs ON cs.commentId = c.id
            LEFT JOIN segment s ON s.id = cs.segmentId
            ORDER BY c.createdAt ASC, c.id ASC;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var entries: [(
            comment: SegmentComment,
            segmentID: SegmentID,
            appBundleID: String?,
            appName: String?,
            browserURL: String?,
            referenceTimestamp: Date
        )] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let comment = parseSegmentComment(statement: statement!)
            let segmentIDValue = sqlite3_column_int64(statement, 7)
            let appBundleID = sqlite3_column_text(statement, 8).map { String(cString: $0) }
            let browserURL = sqlite3_column_text(statement, 9).map { String(cString: $0) }
            let referenceTimestamp: Date
            if sqlite3_column_type(statement, 10) == SQLITE_NULL {
                referenceTimestamp = comment.createdAt
            } else {
                referenceTimestamp = Schema.timestampToDate(sqlite3_column_int64(statement, 10))
            }

            entries.append((
                comment: comment,
                segmentID: SegmentID(value: segmentIDValue),
                appBundleID: appBundleID,
                appName: nil,
                browserURL: browserURL,
                referenceTimestamp: referenceTimestamp
            ))
        }

        return entries
    }

    /// Full-text search comments by body text.
    /// Uses FTS5 index and always enforces capped pagination inputs.
    public func searchSegmentComments(query: String, limit: Int = 10, offset: Int = 0) async throws -> [SegmentComment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let cappedLimit = min(max(limit, 1), 200)
        let cappedOffset = max(offset, 0)
        let ftsQuery = buildSegmentCommentFTSQuery(from: trimmed)
        guard !ftsQuery.isEmpty else { return [] }

        let sql = """
            SELECT c.id, c.body, c.author, c.attachmentsJson, c.frameId, c.createdAt, c.updatedAt
            FROM segment_comment_fts fts
            JOIN segment_comment c ON c.id = fts.rowid
            WHERE segment_comment_fts MATCH ?
            ORDER BY bm25(segment_comment_fts), c.createdAt DESC, c.id DESC
            LIMIT ? OFFSET ?;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(cappedLimit))
        sqlite3_bind_int64(statement, 3, Int64(cappedOffset))

        var comments: [SegmentComment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            comments.append(parseSegmentComment(statement: statement!))
        }

        return comments
    }

    /// Full-text search comments with representative segment context for each comment.
    /// This is used by the All Comments search UI to avoid follow-up context queries.
    public func searchCommentTimelineEntries(
        query: String,
        limit: Int = 10,
        offset: Int = 0
    ) async throws -> [(
        comment: SegmentComment,
        segmentID: SegmentID,
        appBundleID: String?,
        appName: String?,
        browserURL: String?,
        referenceTimestamp: Date
    )] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let cappedLimit = min(max(limit, 1), 200)
        let cappedOffset = max(offset, 0)
        let ftsQuery = buildSegmentCommentFTSQuery(from: trimmed)
        guard !ftsQuery.isEmpty else { return [] }

        let sql = """
            WITH matched_comments AS (
                SELECT
                    rowid AS commentId,
                    bm25(segment_comment_fts) AS rank
                FROM segment_comment_fts
                WHERE segment_comment_fts MATCH ?
                ORDER BY bm25(segment_comment_fts), rowid DESC
                LIMIT ? OFFSET ?
            ),
            chosen_segment AS (
                SELECT scl.commentId, MIN(scl.segmentId) AS segmentId
                FROM segment_comment_link scl
                JOIN matched_comments mc ON mc.commentId = scl.commentId
                GROUP BY scl.commentId
            )
            SELECT
                c.id, c.body, c.author, c.attachmentsJson, c.frameId, c.createdAt, c.updatedAt,
                cs.segmentId, s.bundleID, s.browserUrl, s.startDate
            FROM matched_comments mc
            JOIN segment_comment c ON c.id = mc.commentId
            JOIN chosen_segment cs ON cs.commentId = c.id
            LEFT JOIN segment s ON s.id = cs.segmentId
            ORDER BY mc.rank, c.createdAt DESC, c.id DESC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(cappedLimit))
        sqlite3_bind_int64(statement, 3, Int64(cappedOffset))

        var entries: [(
            comment: SegmentComment,
            segmentID: SegmentID,
            appBundleID: String?,
            appName: String?,
            browserURL: String?,
            referenceTimestamp: Date
        )] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let comment = parseSegmentComment(statement: statement!)
            let segmentIDValue = sqlite3_column_int64(statement, 7)
            let appBundleID = sqlite3_column_text(statement, 8).map { String(cString: $0) }
            let browserURL = sqlite3_column_text(statement, 9).map { String(cString: $0) }
            let referenceTimestamp: Date
            if sqlite3_column_type(statement, 10) == SQLITE_NULL {
                referenceTimestamp = comment.createdAt
            } else {
                referenceTimestamp = Schema.timestampToDate(sqlite3_column_int64(statement, 10))
            }

            entries.append((
                comment: comment,
                segmentID: SegmentID(value: segmentIDValue),
                appBundleID: appBundleID,
                appName: nil,
                browserURL: browserURL,
                referenceTimestamp: referenceTimestamp
            ))
        }

        return entries
    }

    /// Get how many segments a comment is currently linked to
    public func getSegmentCountForComment(commentId: SegmentCommentID) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try getSegmentCountForComment(db: db, commentId: commentId.value)
    }

    /// Get the first linked segment for a comment (deterministic by link creation).
    public func getFirstLinkedSegmentForComment(commentId: SegmentCommentID) async throws -> SegmentID? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT segmentId
            FROM segment_comment_link
            WHERE commentId = ?
            ORDER BY createdAt ASC, segmentId ASC
            LIMIT 1;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, commentId.value)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return SegmentID(value: sqlite3_column_int64(statement, 0))
    }

    /// Get the first frame in a segment (oldest by timestamp).
    public func getFirstFrameForSegment(segmentId: SegmentID) async throws -> FrameID? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT id
            FROM frame
            WHERE segmentId = ?
            ORDER BY createdAt ASC, id ASC
            LIMIT 1;
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
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return FrameID(value: sqlite3_column_int64(statement, 0))
    }

    // MARK: - Segment Comment Helpers

    private func getSegmentCommentByID(db: OpaquePointer, commentID: Int64) throws -> SegmentComment? {
        let sql = """
            SELECT id, body, author, attachmentsJson, frameId, createdAt, updatedAt
            FROM segment_comment
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, commentID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return parseSegmentComment(statement: statement!)
    }

    private func parseSegmentComment(statement: OpaquePointer) -> SegmentComment {
        let id = sqlite3_column_int64(statement, 0)
        let body = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        let author = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        let attachmentsJSON = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "[]"
        let frameID: FrameID?
        if sqlite3_column_type(statement, 4) == SQLITE_NULL {
            frameID = nil
        } else {
            frameID = FrameID(value: sqlite3_column_int64(statement, 4))
        }
        let createdAt = Schema.timestampToDate(sqlite3_column_int64(statement, 5))
        let updatedAt = Schema.timestampToDate(sqlite3_column_int64(statement, 6))

        return SegmentComment(
            id: SegmentCommentID(value: id),
            body: body,
            author: author,
            attachments: decodeCommentAttachments(attachmentsJSON),
            frameID: frameID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func encodeCommentAttachments(_ attachments: [SegmentCommentAttachment]) throws -> String {
        do {
            let data = try JSONEncoder().encode(attachments)
            guard let json = String(data: data, encoding: .utf8) else {
                throw DatabaseError.queryExecutionFailed("Failed to convert encoded attachments to UTF-8 string")
            }
            return json
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.queryExecutionFailed("Failed to encode comment attachments: \(error.localizedDescription)")
        }
    }

    private func decodeCommentAttachments(_ attachmentsJSON: String) -> [SegmentCommentAttachment] {
        guard let data = attachmentsJSON.data(using: .utf8) else {
            return []
        }
        do {
            return try JSONDecoder().decode([SegmentCommentAttachment].self, from: data)
        } catch {
            Log.warning("[DB] Failed to decode comment attachments JSON: \(error.localizedDescription)", category: .database)
            return []
        }
    }

    private func getCommentAttachments(db: OpaquePointer, commentId: Int64) throws -> [SegmentCommentAttachment] {
        let sql = "SELECT attachmentsJson FROM segment_comment WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, commentId)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return []
        }

        let attachmentsJSON = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "[]"
        return decodeCommentAttachments(attachmentsJSON)
    }

    private func deleteCommentRow(db: OpaquePointer, commentId: Int64) throws {
        let sql = "DELETE FROM segment_comment WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, commentId)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func getCommentIDsForSegment(db: OpaquePointer, segmentId: Int64) throws -> [Int64] {
        let sql = "SELECT commentId FROM segment_comment_link WHERE segmentId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, segmentId)

        var commentIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            commentIDs.append(sqlite3_column_int64(statement, 0))
        }

        return commentIDs
    }

    private func getSegmentCountForComment(db: OpaquePointer, commentId: Int64) throws -> Int {
        let sql = "SELECT COUNT(*) FROM segment_comment_link WHERE commentId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, commentId)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    private func buildSegmentCommentFTSQuery(from rawQuery: String) -> String {
        rawQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }

    private func cleanupOrphanedCommentIfNeeded(db: OpaquePointer, commentId: Int64) throws {
        guard try getSegmentCountForComment(db: db, commentId: commentId) == 0 else {
            return
        }

        let attachments = try getCommentAttachments(db: db, commentId: commentId)
        try deleteCommentRow(db: db, commentId: commentId)
        cleanupAttachmentFiles(attachments)
    }

    private func cleanupAttachmentFiles(_ attachments: [SegmentCommentAttachment]) {
        guard !attachments.isEmpty else { return }

        for attachment in attachments {
            let rawPath = attachment.filePath
            let resolvedPath: String
            if rawPath.hasPrefix("/") || rawPath.hasPrefix("~") {
                resolvedPath = NSString(string: rawPath).expandingTildeInPath
            } else {
                resolvedPath = (storageRootPath as NSString).appendingPathComponent(rawPath)
            }

            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                continue
            }

            do {
                try FileManager.default.removeItem(atPath: resolvedPath)
            } catch {
                Log.warning("[DB] Failed to remove attachment file at \(resolvedPath): \(error.localizedDescription)", category: .database)
            }
        }
    }

    // MARK: - OCR Node Operations (Rewind-compatible)

    public func insertNodes(
        frameID: FrameID,
        nodes: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)],
        frameWidth: Int,
        frameHeight: Int
    ) async throws {
        try withTracedDatabaseOperation("insert_nodes_batch") { db in
            try NodeQueries.insertBatch(
                db: db,
                frameID: frameID,
                nodes: nodes,
                encryptedTexts: [:],
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )
        }
    }

    public func insertNodes(
        frameID: FrameID,
        nodes: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)],
        encryptedTexts: [Int: String],
        frameWidth: Int,
        frameHeight: Int
    ) async throws {
        try withTracedDatabaseOperation("insert_nodes_batch_encrypted") { db in
            try NodeQueries.insertBatch(
                db: db,
                frameID: frameID,
                nodes: nodes,
                encryptedTexts: encryptedTexts,
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )
        }
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

    public func getPendingFrameDeletionJobs(
        videoID: Int64,
        includeInProgressJobs: Bool = false,
        includeRetryableFailures: Bool = false
    ) async throws -> [PendingFrameDeletionJob] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let pendingStatuses = includeInProgressJobs ? [5, 6] : [5]
        let includedStatuses = includeRetryableFailures
            ? Array(Set(pendingStatuses + [8])).sorted()
            : pendingStatuses
        let statusFilter = includedStatuses.count == 1
            ? "processingStatus = \(includedStatuses[0])"
            : "processingStatus IN (\(includedStatuses.map(String.init).joined(separator: ", ")))"
        let sql = """
            SELECT id, videoId, videoFrameIndex
            FROM frame
            WHERE videoId = ?
              AND \(statusFilter)
              AND rewritePurpose = 'deletion'
            ORDER BY videoFrameIndex ASC, id ASC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, videoID)

        var jobs: [PendingFrameDeletionJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            jobs.append(
                PendingFrameDeletionJob(
                    frameID: sqlite3_column_int64(statement, 0),
                    videoID: sqlite3_column_int64(statement, 1),
                    frameIndex: Int(sqlite3_column_int(statement, 2))
                )
            )
        }

        return jobs
    }

    public func getVideoIDsWithPendingRewrites(
        includeRetryableFailures: Bool = false
    ) async throws -> [Int64] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let statuses = includeRetryableFailures ? [5, 6, 8] : [5, 6]
        let sql = """
            SELECT DISTINCT videoId
            FROM frame
            WHERE videoId IS NOT NULL
              AND processingStatus IN (\(statuses.map(String.init).joined(separator: ", ")))
              AND rewritePurpose IN ('redaction', 'deletion')
            ORDER BY videoId ASC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var videoIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            videoIDs.append(sqlite3_column_int64(statement, 0))
        }

        return videoIDs
    }

    public func buildVideoRewritePlan(
        videoID: Int64,
        includeInProgressJobs: Bool = false,
        includeRetryableFailures: Bool = false
    ) async throws -> VideoRewritePlan? {
        let deletionJobs = try await getPendingFrameDeletionJobs(
            videoID: videoID,
            includeInProgressJobs: includeInProgressJobs,
            includeRetryableFailures: includeRetryableFailures
        )
        let deletions = deletionJobs.map {
            VideoFrameDeletion(frameID: $0.frameID, frameIndex: $0.frameIndex)
        }
        let deletionFrameIDs = Set(deletions.map(\.frameID))

        let redactionJobs = try await getPendingNodeRedactionJobs(
            videoID: videoID,
            includeInProgressJobs: includeInProgressJobs,
            includeRetryableFailures: includeRetryableFailures
        )

        var redactionTargetsByFrameID: [Int64: (frameIndex: Int, targets: [SegmentRedactionTarget])] = [:]
        var seenTargets: Set<String> = []

        for job in redactionJobs {
            guard !deletionFrameIDs.contains(job.frameID) else { continue }
            let targetKey = "\(job.frameID)|\(job.nodeID)"
            guard seenTargets.insert(targetKey).inserted else { continue }
            redactionTargetsByFrameID[job.frameID, default: (job.frameIndex, [])].targets.append(
                SegmentRedactionTarget(
                    frameID: job.frameID,
                    nodeID: job.nodeID,
                    normalizedRect: job.normalizedRect
                )
            )
        }

        let redactions = redactionTargetsByFrameID
            .map { frameID, value in
                VideoFrameRedaction(
                    frameID: frameID,
                    frameIndex: value.frameIndex,
                    targets: value.targets
                )
            }
            .sorted {
                if $0.frameIndex == $1.frameIndex {
                    return $0.frameID < $1.frameID
                }
                return $0.frameIndex < $1.frameIndex
            }

        guard !deletions.isEmpty || !redactions.isEmpty else {
            return nil
        }

        let visibleFrameCount = try withTracedDatabaseOperation("get_visible_frame_count_for_video_rewrite") { db in
            let sql = """
                SELECT COUNT(*)
                FROM frame
                WHERE videoId = ?
                  AND (rewritePurpose IS NULL OR rewritePurpose != 'deletion');
                """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(
                    query: sql,
                    underlying: String(cString: sqlite3_errmsg(db))
                )
            }

            sqlite3_bind_int64(statement, 1, videoID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }

        return VideoRewritePlan(
            videoID: videoID,
            operation: !deletions.isEmpty && visibleFrameCount == 0 ? .wholeVideoDelete : .partialRewrite,
            deletions: deletions,
            redactions: redactions
        )
    }

    public func deleteOrScheduleNativeFramesForDeletion(
        frameIDs: [Int64]
    ) async throws -> NativeFrameDeletionResult {
        let uniqueFrameIDs = Array(Set(frameIDs)).sorted()
        guard !uniqueFrameIDs.isEmpty else {
            return NativeFrameDeletionResult(
                immediatelyDeletedFrameIDs: [],
                scheduledJobs: []
            )
        }

        return try withTracedDatabaseOperation("delete_or_schedule_native_frames_for_deletion_by_id") { db in
            let placeholders = uniqueFrameIDs.map { _ in "?" }.joined(separator: ", ")
            let selectSQL = """
                SELECT id, videoId, videoFrameIndex
                FROM frame
                WHERE id IN (\(placeholders))
                ORDER BY COALESCE(videoId, 0) ASC, videoFrameIndex ASC, id ASC;
                """

            return try executeNativeFrameDeletion(
                db: db,
                selectSQL: selectSQL
            ) { statement in
                for (index, frameID) in uniqueFrameIDs.enumerated() {
                    sqlite3_bind_int64(statement, Int32(index + 1), frameID)
                }
            }
        }
    }

    public func deleteOrScheduleNativeFramesForDeletion(
        newerThan date: Date
    ) async throws -> NativeFrameDeletionResult {
        return try withTracedDatabaseOperation("delete_or_schedule_native_frames_for_deletion_by_date") { db in
            let selectSQL = """
                SELECT id, videoId, videoFrameIndex
                FROM frame
                WHERE createdAt > ?
                  AND (rewritePurpose IS NULL OR rewritePurpose != 'deletion')
                ORDER BY COALESCE(videoId, 0) ASC, createdAt ASC, videoFrameIndex ASC, id ASC;
                """

            return try executeNativeFrameDeletion(
                db: db,
                selectSQL: selectSQL
            ) { statement in
                sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(date))
            }
        }
    }

    private func executeNativeFrameDeletion(
        db: OpaquePointer,
        selectSQL: String,
        bindSelection: (OpaquePointer) -> Void
    ) throws -> NativeFrameDeletionResult {
        var transactionOpen = false
        do {
            try executeImmediateSQL("BEGIN IMMEDIATE TRANSACTION;", db: db)
            transactionOpen = true

            var selectStatement: OpaquePointer?
            defer { sqlite3_finalize(selectStatement) }
            guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(query: selectSQL, underlying: String(cString: sqlite3_errmsg(db)))
            }

            bindSelection(selectStatement!)

            var immediatelyDeletedFrameIDs: [Int64] = []
            var scheduledJobs: [PendingFrameDeletionJob] = []
            while sqlite3_step(selectStatement) == SQLITE_ROW {
                let frameID = sqlite3_column_int64(selectStatement, 0)
                if sqlite3_column_type(selectStatement, 1) == SQLITE_NULL {
                    immediatelyDeletedFrameIDs.append(frameID)
                    continue
                }

                scheduledJobs.append(
                    PendingFrameDeletionJob(
                        frameID: frameID,
                        videoID: sqlite3_column_int64(selectStatement, 1),
                        frameIndex: Int(sqlite3_column_int(selectStatement, 2))
                    )
                )
            }

            if !immediatelyDeletedFrameIDs.isEmpty {
                _ = try FrameQueries.delete(
                    db: db,
                    frameIDs: immediatelyDeletedFrameIDs.map { FrameID(value: $0) }
                )
            }

            try markFramesPendingDeletion(
                db: db,
                frameIDs: scheduledJobs.map(\.frameID)
            )

            try executeImmediateSQL("COMMIT;", db: db)
            transactionOpen = false
            return NativeFrameDeletionResult(
                immediatelyDeletedFrameIDs: immediatelyDeletedFrameIDs,
                scheduledJobs: scheduledJobs
            )
        } catch {
            if transactionOpen {
                try? executeImmediateSQL("ROLLBACK;", db: db)
            }
            throw error
        }
    }

    private func markFramesPendingDeletion(
        db: OpaquePointer,
        frameIDs: [Int64]
    ) throws {
        guard !frameIDs.isEmpty else { return }

        let placeholders = frameIDs.map { _ in "?" }.joined(separator: ", ")
        let deleteQueueSQL = "DELETE FROM processing_queue WHERE frameId IN (\(placeholders));"
        let updateSQL = """
            UPDATE frame
            SET processingStatus = 5,
                rewritePurpose = 'deletion'
            WHERE id IN (\(placeholders));
            """

        var deleteQueueStatement: OpaquePointer?
        defer { sqlite3_finalize(deleteQueueStatement) }
        guard sqlite3_prepare_v2(db, deleteQueueSQL, -1, &deleteQueueStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: deleteQueueSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        for (index, frameID) in frameIDs.enumerated() {
            sqlite3_bind_int64(deleteQueueStatement, Int32(index + 1), frameID)
        }
        guard sqlite3_step(deleteQueueStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: deleteQueueSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }

        var updateStatement: OpaquePointer?
        defer { sqlite3_finalize(updateStatement) }
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: updateSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        for (index, frameID) in frameIDs.enumerated() {
            sqlite3_bind_int64(updateStatement, Int32(index + 1), frameID)
        }
        guard sqlite3_step(updateStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: updateSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func getVisibleNativeFrameIDsNewerThan(_ date: Date) async throws -> [Int64] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT id
            FROM frame
            WHERE createdAt > ?
              AND (rewritePurpose IS NULL OR rewritePurpose != 'deletion')
            ORDER BY createdAt ASC, id ASC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(date))

        var frameIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            frameIDs.append(sqlite3_column_int64(statement, 0))
        }

        return frameIDs
    }

    public func finalizeVideoRewrite(_ plan: VideoRewritePlan) async throws {
        try withTracedDatabaseOperation("finalize_video_mutation") { db in
            var transactionOpen = false
            do {
                try executeImmediateSQL("BEGIN IMMEDIATE TRANSACTION;", db: db)
                transactionOpen = true

                let deletionFrameIDs: [Int64]
                if plan.deletesWholeVideo {
                    let sql = """
                        SELECT id
                        FROM frame
                        WHERE videoId = ?
                          AND rewritePurpose = 'deletion'
                        ORDER BY id ASC;
                        """
                    var statement: OpaquePointer?
                    defer { sqlite3_finalize(statement) }

                    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                        throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
                    }
                    sqlite3_bind_int64(statement, 1, plan.videoID)

                    var collectedIDs: [Int64] = []
                    while sqlite3_step(statement) == SQLITE_ROW {
                        collectedIDs.append(sqlite3_column_int64(statement, 0))
                    }
                    deletionFrameIDs = collectedIDs
                } else {
                    deletionFrameIDs = plan.deletionFrameIDs
                }

                if !deletionFrameIDs.isEmpty {
                    _ = try FrameQueries.delete(
                        db: db,
                        frameIDs: deletionFrameIDs.map { FrameID(value: $0) }
                    )
                }

                if !plan.redactionFrameIDs.isEmpty {
                    let placeholders = plan.redactionFrameIDs.map { _ in "?" }.joined(separator: ", ")
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    let sql = """
                        UPDATE frame
                        SET processingStatus = 7,
                            rewrittenAt = \(nowMs),
                            rewritePurpose = 'redaction'
                        WHERE id IN (\(placeholders))
                          AND COALESCE(rewritePurpose, 'redaction') = 'redaction';
                        """
                    var statement: OpaquePointer?
                    defer { sqlite3_finalize(statement) }
                    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                        throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
                    }
                    for (index, frameID) in plan.redactionFrameIDs.enumerated() {
                        sqlite3_bind_int64(statement, Int32(index + 1), frameID)
                    }
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
                    }
                }

                if plan.deletesWholeVideo {
                    let sql = "DELETE FROM video WHERE id = ?;"
                    var statement: OpaquePointer?
                    defer { sqlite3_finalize(statement) }
                    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                        throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
                    }
                    sqlite3_bind_int64(statement, 1, plan.videoID)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
                    }
                }

                try executeImmediateSQL("COMMIT;", db: db)
                transactionOpen = false
            } catch {
                if transactionOpen {
                    try? executeImmediateSQL("ROLLBACK;", db: db)
                }
                throw error
            }
        }
    }

    public func resetVideoRewritePlanToPending(_ plan: VideoRewritePlan) async throws {
        try withTracedDatabaseOperation("reset_video_mutation_plan_to_pending") { db in
            func update(_ frameIDs: [Int64], purpose: String) throws {
                guard !frameIDs.isEmpty else { return }
                let placeholders = frameIDs.map { _ in "?" }.joined(separator: ", ")
                let sql = """
                    UPDATE frame
                    SET processingStatus = 5,
                        rewritePurpose = ?
                    WHERE id IN (\(placeholders));
                    """
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
                }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, purpose, -1, transient)
                for (index, frameID) in frameIDs.enumerated() {
                    sqlite3_bind_int64(statement, Int32(index + 2), frameID)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
                }
            }

            try update(plan.deletionFrameIDs, purpose: "deletion")
            try update(plan.redactionFrameIDs, purpose: "redaction")
        }
    }

    public func getPendingNodeRedactionJobs(
        videoID: Int64,
        includeInProgressJobs: Bool = false,
        includeRetryableFailures: Bool = false
    ) async throws -> [PendingNodeRedactionJob] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let pendingStatuses = includeInProgressJobs ? [5, 6] : [5]
        let includedStatuses = includeRetryableFailures
            ? Array(Set(pendingStatuses + [8])).sorted()
            : pendingStatuses
        let statusFilter = includedStatuses.count == 1
            ? "f.processingStatus = \(includedStatuses[0])"
            : "f.processingStatus IN (\(includedStatuses.map(String.init).joined(separator: ", ")))"
        let sql = """
            SELECT
                f.id,
                f.videoFrameIndex,
                n.id,
                n.leftX,
                n.topY,
                n.width,
                n.height
            FROM frame f
            JOIN node n ON n.frameId = f.id
            WHERE f.videoId = ?
              AND \(statusFilter)
              AND COALESCE(f.rewritePurpose, 'redaction') = 'redaction'
              AND n.encryptedText IS NOT NULL
            ORDER BY f.videoFrameIndex ASC, n.nodeOrder ASC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, videoID)

        var jobs: [PendingNodeRedactionJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameID = sqlite3_column_int64(statement, 0)
            let frameIndex = Int(sqlite3_column_int(statement, 1))
            let nodeID = Int(sqlite3_column_int64(statement, 2))
            let leftX = sqlite3_column_double(statement, 3)
            let topY = sqlite3_column_double(statement, 4)
            let width = sqlite3_column_double(statement, 5)
            let height = sqlite3_column_double(statement, 6)
            jobs.append(
                PendingNodeRedactionJob(
                    frameID: frameID,
                    frameIndex: frameIndex,
                    nodeID: nodeID,
                    normalizedRect: CGRect(x: leftX, y: topY, width: width, height: height)
                )
            )
        }

        return jobs
    }

    /// Return distinct video IDs that still have frame-level redaction work pending or in progress.
    public func getVideoIDsWithPendingNodeRedactions(
        includeRetryableFailures: Bool = false
    ) async throws -> [Int64] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let statuses = includeRetryableFailures ? [5, 6, 8] : [5, 6]
        let sql = """
            SELECT DISTINCT f.videoId
            FROM frame f
            JOIN node n ON n.frameId = f.id
            WHERE f.processingStatus IN (\(statuses.map(String.init).joined(separator: ", ")))
              AND COALESCE(f.rewritePurpose, 'redaction') = 'redaction'
              AND n.encryptedText IS NOT NULL
            ORDER BY f.videoId ASC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var videoIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            videoIDs.append(sqlite3_column_int64(statement, 0))
        }

        return videoIDs
    }

    public func hasProtectedPhraseRedactionData() async throws -> Bool {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT EXISTS(
                SELECT 1
                FROM node
                WHERE encryptedText IS NOT NULL
                LIMIT 1
            );
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return sqlite3_column_int(statement, 0) != 0
    }

    public func abandonPendingNodeRedactions(missingKeyRewritePurpose: String) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            UPDATE frame
            SET processingStatus = 8,
                rewritePurpose = ?
            WHERE processingStatus IN (5, 6, 8)
              AND COALESCE(rewritePurpose, 'redaction') = 'redaction'
              AND EXISTS (
                  SELECT 1
                  FROM node n
                  WHERE n.frameId = frame.id
                    AND n.encryptedText IS NOT NULL
              );
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, missingKeyRewritePurpose, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return Int(sqlite3_changes(db))
    }

    /// Returns true when a video still has frames waiting on OCR/readability before
    /// phrase-level rewrite batching should run.
    public func videoHasFramesAwaitingOCR(videoID: Int64) async throws -> Bool {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT 1
            FROM frame
            WHERE videoId = ?
              AND processingStatus IN (0, 1, 4)
            LIMIT 1;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, videoID)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public func isVideoFinalized(videoID: Int64) async throws -> Bool {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT processingState
            FROM video
            WHERE id = ?
            LIMIT 1;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, videoID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) == 0
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
        try withTracedDatabaseOperation("get_daily_metrics") { db in
            try DailyMetricsQueries.getDailyCounts(
                db: db,
                metricType: metricType,
                from: startDate,
                to: endDate
            )
        }
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

    public func getRecentMetricEvents(
        limit: Int,
        excluding metricTypes: Set<DailyMetricsQueries.MetricType> = []
    ) async throws -> [DailyMetricsQueries.RecentEvent] {
        try withTracedDatabaseOperation("get_recent_metric_events") { db in
            try DailyMetricsQueries.getRecentEvents(
                db: db,
                limit: limit,
                excluding: metricTypes
            )
        }
    }

    /// Get daily screen time totals (for graphs)
    /// Returns array of (date, totalSeconds) tuples sorted by date ascending
    nonisolated public func getDailyScreenTime(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        try await withDashboardReadConnection(operation: "get_daily_screen_time") { db in
            try AppSegmentQueries.getDailyScreenTime(
                db: db,
                from: startDate,
                to: endDate
            )
        }
    }

    // MARK: - DB Storage Snapshot Operations

    /// Record the current physical DB and WAL sizes for the local calendar day.
    /// Reuses the same row within a day and overwrites it with the latest sample.
    public func recordDBStorageSnapshot(timestamp: Date = Date()) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let isInMemory = databasePath == ":memory:" || databasePath.contains("mode=memory")
        guard !isInMemory else {
            return
        }

        let databaseURL = URL(
            fileURLWithPath: NSString(string: databasePath).expandingTildeInPath
        )
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let localDay = Self.localDayText(for: timestamp)
        let sampledAt = Int64(timestamp.timeIntervalSince1970 * 1000)
        let dbBytes = try allocatedFileSize(at: databaseURL)
        let walBytes = try allocatedFileSizeIfPresent(at: walURL)

        let sql = """
            INSERT INTO db_storage_snapshot (local_day, db_bytes, wal_bytes, sampled_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(local_day) DO UPDATE SET
                db_bytes = excluded.db_bytes,
                wal_bytes = excluded.wal_bytes,
                sampled_at = excluded.sampled_at
            WHERE excluded.sampled_at >= db_storage_snapshot.sampled_at;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, localDay, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, dbBytes)
        sqlite3_bind_int64(statement, 3, walBytes)
        sqlite3_bind_int64(statement, 4, sampledAt)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    private static func readDBStorageSnapshots(
        db: OpaquePointer,
        from startDate: Date,
        to endDate: Date
    ) throws -> [(date: Date, dbBytes: Int64, walBytes: Int64, sampledAt: Date)] {
        let sql = """
            SELECT local_day, db_bytes, wal_bytes, sampled_at
            FROM db_storage_snapshot
            WHERE local_day >= ? AND local_day <= ?
            ORDER BY local_day ASC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let startLocalDay = Self.localDayText(for: startDate)
        let endLocalDay = Self.localDayText(for: endDate)
        sqlite3_bind_text(statement, 1, startLocalDay, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, endLocalDay, -1, SQLITE_TRANSIENT)

        var snapshots: [(date: Date, dbBytes: Int64, walBytes: Int64, sampledAt: Date)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let localDayTextPointer = sqlite3_column_text(statement, 0),
                  let snapshotDate = Self.parseLocalDay(String(cString: localDayTextPointer)) else {
                continue
            }

            let dbBytes = sqlite3_column_int64(statement, 1)
            let walBytes = sqlite3_column_int64(statement, 2)
            let sampledAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)
            snapshots.append((date: snapshotDate, dbBytes: dbBytes, walBytes: walBytes, sampledAt: sampledAt))
        }

        return snapshots
    }

    /// Read daily DB/WAL size snapshots for the requested local-date range.
    nonisolated public func getDBStorageSnapshots(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, dbBytes: Int64, walBytes: Int64, sampledAt: Date)] {
        try await withDashboardReadConnection(operation: "get_db_storage_snapshots") { db in
            try Self.readDBStorageSnapshots(
                db: db,
                from: startDate,
                to: endDate
            )
        }
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

    /// Quick statistics query - single combined query for feedback diagnostics
    /// Only returns frameCount and sessionCount (what's actually displayed)
    public func getStatisticsQuick() async throws -> (frameCount: Int, sessionCount: Int) {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT
                (SELECT COUNT(*) FROM frame) as frameCount,
                (SELECT COUNT(*) FROM segment) as sessionCount
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
            throw DatabaseError.queryFailed(query: sql, underlying: "No result row")
        }

        let frameCount = Int(sqlite3_column_int64(statement, 0))
        let sessionCount = Int(sqlite3_column_int64(statement, 1))

        return (frameCount: frameCount, sessionCount: sessionCount)
    }

    // MARK: - Maintenance Operations

    /// Checkpoint the WAL file (merge WAL into main database and truncate)
    /// Call periodically to prevent WAL file from growing too large.
    /// Includes retry logic for external drives that may have slow I/O.
    public func checkpoint(maxRetries: Int = 3) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "PRAGMA wal_checkpoint(TRUNCATE);"
        var lastError: String?

        for attempt in 1...maxRetries {
            let checkpointStart = CFAbsoluteTimeGetCurrent()

            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
            let message = errorMessage.map { String(cString: $0) }
            sqlite3_free(errorMessage)

            if result == SQLITE_OK {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - checkpointStart) * 1000

                if elapsedMs > 1000 {
                    Log.warning("[DatabaseManager] Slow WAL checkpoint: \(String(format: "%.0f", elapsedMs))ms (external drive may be slow)", category: .database)
                }

                Log.info("[DatabaseManager] WAL checkpoint completed in \(String(format: "%.0f", elapsedMs))ms", category: .database)
                return
            }

            lastError = message ?? "Unknown error"
            Log.error("[DatabaseManager] WAL checkpoint failed (attempt \(attempt)/\(maxRetries)): \(lastError!)", category: .database)

            // Exponential backoff before retry
            if attempt < maxRetries {
                try await Task.sleep(for: .nanoseconds(Int64(UInt64(attempt) * 500_000_000)), clock: .continuous) // 500ms, 1s, 1.5s
            }
        }

        // All retries exhausted
        Log.critical("[DatabaseManager] WAL checkpoint failed after \(maxRetries) retries", category: .database)
        throw StorageError.walCheckpointFailed(retries: maxRetries)
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
        let expandedRewindPath = NSString(string: AppPaths.rewindUnencryptedDBPath).expandingTildeInPath

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
                Log.error("[DatabaseManager] PRAGMA execution failed: \(pragma) - \(message)", category: .database)
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

        // TODO(master-key-recovery): When DB encryption is formally integrated into the
        // missing-key UX, stop silently generating a replacement SQLCipher key here.
        // We want a startup decision tree that lets the user recover the original DB key,
        // explicitly create a new one with destructive confirmation, or abort opening the
        // encrypted database. That branch is intentionally deferred for now.

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

    private func verifyFTS5RuntimeSupport() throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let failureGuidance = "This build's SQLite/SQLCipher runtime cannot support search indexing. Verify that Xcode is using the pinned Package.resolved versions for swift-sqlcipher."
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        let createProbeSQL = "CREATE VIRTUAL TABLE temp.__retrace_fts5_probe USING fts5(content);"
        guard sqlite3_exec(db, createProbeSQL, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            let runtimeSummary = SQLiteRuntimeDiagnostics.summary(db: db)
            Log.critical(
                "[DatabaseManager] FTS5 runtime probe failed: \(message). \(failureGuidance) Runtime: \(runtimeSummary)",
                category: .database
            )
            throw DatabaseError.connectionFailed(
                underlying: "FTS5 runtime probe failed: \(message). \(failureGuidance) Runtime: \(runtimeSummary)"
            )
        }

        sqlite3_free(errorMessage)
        errorMessage = nil

        let dropProbeSQL = "DROP TABLE temp.__retrace_fts5_probe;"
        if sqlite3_exec(db, dropProbeSQL, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            Log.warning(
                "[DatabaseManager] Failed to drop temporary FTS5 probe table: \(message)",
                category: .database
            )
        }
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
    /// Atomically removes it from the queue and marks processingStatus = 1.
    /// Returns tuple of (queueID, frameID, retryCount) or nil if queue is empty
    public func dequeueFrameForProcessing() async throws -> (queueID: Int64, frameID: Int64, retryCount: Int)? {
        try withTracedDatabaseOperation("dequeue_frame_for_processing") { db in
            var transactionOpen = false
            do {
                try executeImmediateSQL("BEGIN IMMEDIATE TRANSACTION;", db: db)
                transactionOpen = true

                // Get highest priority item where frame still has processingStatus = 0.
                let selectSql = """
                    SELECT pq.id, pq.frameId, pq.retryCount
                    FROM processing_queue pq
                    INNER JOIN frame f ON pq.frameId = f.id
                    WHERE f.processingStatus = 0
                    ORDER BY pq.priority DESC, pq.enqueuedAt ASC
                    LIMIT 1;
                """

                let selection: (queueID: Int64, frameID: Int64, retryCount: Int)?
                do {
                    var selectStmt: OpaquePointer?
                    defer { sqlite3_finalize(selectStmt) }

                    guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
                        throw DatabaseError.queryFailed(query: selectSql, underlying: String(cString: sqlite3_errmsg(db)))
                    }

                    guard sqlite3_step(selectStmt) == SQLITE_ROW else {
                        selection = nil
                        try executeImmediateSQL("COMMIT;", db: db)
                        transactionOpen = false
                        return nil
                    }

                    selection = (
                        queueID: sqlite3_column_int64(selectStmt, 0),
                        frameID: sqlite3_column_int64(selectStmt, 1),
                        retryCount: Int(sqlite3_column_int(selectStmt, 2))
                    )
                }

                guard let selection else {
                    return nil
                }

                let updateSql = "UPDATE frame SET processingStatus = 1 WHERE id = ? AND processingStatus = 0;"
                do {
                    var updateStmt: OpaquePointer?
                    defer { sqlite3_finalize(updateStmt) }

                    guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else {
                        throw DatabaseError.queryFailed(query: updateSql, underlying: String(cString: sqlite3_errmsg(db)))
                    }

                    sqlite3_bind_int64(updateStmt, 1, selection.frameID)

                    guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                        throw DatabaseError.queryFailed(query: updateSql, underlying: String(cString: sqlite3_errmsg(db)))
                    }

                    guard sqlite3_changes(db) == 1 else {
                        throw DatabaseError.queryFailed(
                            query: updateSql,
                            underlying: "Frame \(selection.frameID) was not pending during dequeue"
                        )
                    }
                }

                let deleteSql = "DELETE FROM processing_queue WHERE id = ?;"
                do {
                    var deleteStmt: OpaquePointer?
                    defer { sqlite3_finalize(deleteStmt) }

                    guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else {
                        throw DatabaseError.queryFailed(query: deleteSql, underlying: String(cString: sqlite3_errmsg(db)))
                    }

                    sqlite3_bind_int64(deleteStmt, 1, selection.queueID)

                    guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                        throw DatabaseError.queryFailed(query: deleteSql, underlying: String(cString: sqlite3_errmsg(db)))
                    }

                    guard sqlite3_changes(db) == 1 else {
                        throw DatabaseError.queryFailed(
                            query: deleteSql,
                            underlying: "Queue row \(selection.queueID) disappeared during dequeue"
                        )
                    }
                }

                try executeImmediateSQL("COMMIT;", db: db)
                transactionOpen = false
                return selection
            } catch {
                if transactionOpen {
                    try? executeImmediateSQL("ROLLBACK;", db: db)
                }
                throw error
            }
        }
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

    /// Get count of frames that are pending or currently processing (status 0, 1, or rewrite-processing 6)
    public func getPendingFrameCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT COUNT(*) FROM frame WHERE processingStatus IN (0, 1, 6);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get separate counts for OCR and rewrite lanes.
    public func getFrameStatusCounts() async throws -> (
        ocrPending: Int,
        ocrProcessing: Int,
        rewritePending: Int,
        rewriteProcessing: Int
    ) {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT processingStatus, COUNT(*)
            FROM frame
            WHERE processingStatus IN (0, 1, 5, 6)
            GROUP BY processingStatus;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        var ocrPending = 0
        var ocrProcessing = 0
        var rewritePending = 0
        var rewriteProcessing = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let status = Int(sqlite3_column_int(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            if status == 0 {
                ocrPending = count
            } else if status == 1 {
                ocrProcessing = count
            } else if status == 5 {
                rewritePending = count
            } else if status == 6 {
                rewriteProcessing = count
            }
        }

        return (
            ocrPending: ocrPending,
            ocrProcessing: ocrProcessing,
            rewritePending: rewritePending,
            rewriteProcessing: rewriteProcessing
        )
    }

    /// Clear the entire processing queue (used when changing database location)
    /// WARNING: This removes all pending OCR work! Only call when intentionally switching databases.
    public func clearProcessingQueue() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "DELETE FROM processing_queue;"
        var error: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let errorMsg = error.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(error)
            throw DatabaseError.queryFailed(query: sql, underlying: errorMsg)
        }

        Log.warning("[Database] Cleared processing queue (database location changed)", category: .database)
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

    /// Get count of frames processed per minute for the last N minutes
    /// Returns dictionary of [minuteOffset: count] where offset 0 = current minute
    public func getFramesProcessedPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        try await getFrameCountsPerMinute(
            lastMinutes: lastMinutes,
            timestampColumn: "processedAt",
            extraWhereClause: "",
            logLabel: "processed"
        )
    }

    /// Get count of frames encoded/readable per minute for the last N minutes.
    /// Returns dictionary of [minuteOffset: count] where offset 0 = current minute.
    public func getFramesEncodedPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        try await getFrameCountsPerMinute(
            lastMinutes: lastMinutes,
            timestampColumn: "encodedAt",
            extraWhereClause: "",
            logLabel: "encoded"
        )
    }

    /// Get count of frames rewritten per minute for the last N minutes.
    /// Returns dictionary of [minuteOffset: count] where offset 0 = current minute.
    public func getFramesRewrittenPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        try await getFrameCountsPerMinute(
            lastMinutes: lastMinutes,
            timestampColumn: "rewrittenAt",
            extraWhereClause: "",
            logLabel: "rewritten"
        )
    }

    private func getFrameCountsPerMinute(
        lastMinutes: Int,
        timestampColumn: String,
        extraWhereClause: String,
        logLabel: String
    ) async throws -> [Int: Int] {
        // Query frames by timestampColumn (stored as INTEGER Unix timestamp in milliseconds)
        // Use clean minute boundaries (floor to start of minute) for consistent bucketing
        // e.g., 17:05:23 becomes minute key for 17:05:00
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let currentMinuteMs = (nowMs / 60000) * 60000  // Floor to start of current minute
        let cutoffMs = currentMinuteMs - Int64(lastMinutes * 60 * 1000)

        // Group by minute bucket only; ordering is unnecessary because callers merge into dictionaries.
        let sql = """
            SELECT
                CAST((?1 - ((\(timestampColumn) / 60000) * 60000)) / 60000 AS INTEGER) AS minuteOffset,
                COUNT(*) as count
            FROM frame
            WHERE \(timestampColumn) IS NOT NULL
              AND \(timestampColumn) >= ?2
              \(extraWhereClause)
            GROUP BY minuteOffset
        """

        let result = try withTracedDatabaseOperation("get_frames_\(logLabel)_per_minute", warningMs: 250) { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
            }

            sqlite3_bind_int64(stmt, 1, currentMinuteMs)
            sqlite3_bind_int64(stmt, 2, cutoffMs)

            var result: [Int: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let minuteOffset = Int(sqlite3_column_int(stmt, 0))
                let count = Int(sqlite3_column_int(stmt, 1))
                if minuteOffset >= 0 && minuteOffset < lastMinutes {
                    result[minuteOffset] = count
                }
            }
            return result
        }

        Log.debug(
            "[DatabaseManager] getFrames\(logLabel.capitalized)PerMinute returned \(result.count) minute buckets, total: \(result.values.reduce(0, +)) frames",
            category: .database
        )

        return result
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

    /// Update frame processing status.
    /// Ordinary OCR statuses clear any stored rewritePurpose.
    /// Status 2 records OCR completion in processedAt.
    /// Status 7 records rewrite completion in rewrittenAt.
    public func updateFrameProcessingStatus(frameID: Int64, status: Int) async throws {
        try await updateFrameProcessingStatus(frameID: frameID, status: status, rewritePurpose: nil)
    }

    /// Update frame processing status with an optional rewrite purpose for rewrite-lane statuses (5-8).
    public func updateFrameProcessingStatus(
        frameID: Int64,
        status: Int,
        rewritePurpose: String?
    ) async throws {
        try withTracedDatabaseOperation("update_frame_processing_status") { db in
            let isRewriteStatus = (5...8).contains(status)
            let shouldBindRewritePurpose = rewritePurpose != nil || !isRewriteStatus
            let sql: String

            if status == 2 {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                if shouldBindRewritePurpose {
                    sql = "UPDATE frame SET processingStatus = ?, processedAt = \(nowMs), rewritePurpose = ? WHERE id = ? AND (rewritePurpose IS NULL OR rewritePurpose != 'deletion');"
                } else {
                    sql = "UPDATE frame SET processingStatus = ?, processedAt = \(nowMs) WHERE id = ? AND (rewritePurpose IS NULL OR rewritePurpose != 'deletion');"
                }
            } else if !isRewriteStatus {
                if shouldBindRewritePurpose {
                    sql = "UPDATE frame SET processingStatus = ?, rewritePurpose = ? WHERE id = ? AND (rewritePurpose IS NULL OR rewritePurpose != 'deletion');"
                } else {
                    sql = "UPDATE frame SET processingStatus = ? WHERE id = ? AND (rewritePurpose IS NULL OR rewritePurpose != 'deletion');"
                }
            } else if status == 7 {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                if shouldBindRewritePurpose {
                    sql = "UPDATE frame SET processingStatus = ?, rewrittenAt = \(nowMs), rewritePurpose = ? WHERE id = ?;"
                } else {
                    sql = "UPDATE frame SET processingStatus = ?, rewrittenAt = \(nowMs) WHERE id = ?;"
                }
            } else {
                if shouldBindRewritePurpose {
                    sql = "UPDATE frame SET processingStatus = ?, rewritePurpose = ? WHERE id = ?;"
                } else {
                    sql = "UPDATE frame SET processingStatus = ? WHERE id = ?;"
                }
            }

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
            }

            sqlite3_bind_int(stmt, 1, Int32(status))
            if shouldBindRewritePurpose {
                if let rewritePurpose {
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    sqlite3_bind_text(stmt, 2, rewritePurpose, -1, transient)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                sqlite3_bind_int64(stmt, 3, frameID)
            } else {
                sqlite3_bind_int64(stmt, 2, frameID)
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
            }
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
        try withTracedDatabaseOperation("mark_frame_readable") { db in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            // Only update if status is 4 (not yet readable)
            let sql = "UPDATE frame SET processingStatus = 0, encodedAt = \(nowMs) WHERE id = ? AND processingStatus = 4;"
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
    }

    /// Count frames that are still waiting to become readable from the active video writer.
    public func getUnreadableFrameCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT COUNT(*) FROM frame WHERE processingStatus = 4;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Count recently created frames that are still waiting to become readable from disk.
    /// This is used as a short-lived encoding buffer backlog signal, not a durable queue length.
    public func getUnreadableFrameCount(withinLastMinutes windowMinutes: Int) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let clampedWindowMinutes = max(windowMinutes, 1)
        let cutoffMs = Int64(Date().timeIntervalSince1970 * 1000) - Int64(clampedWindowMinutes * 60 * 1000)
        let sql = """
            SELECT COUNT(*)
            FROM frame
            WHERE processingStatus = 4
              AND createdAt >= ?;
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, cutoffMs)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Count frames that have already been confirmed readable from the video file.
    public func getEncodedFrameCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT COUNT(*) FROM frame WHERE encodedAt IS NOT NULL;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Get processing status for multiple frames in a single query
    /// Returns dictionary of frameID -> processingStatus
    public func getFrameProcessingStatuses(frameIDs: [Int64]) async throws -> [Int64: Int] {
        guard !frameIDs.isEmpty else {
            return [:]
        }

        return try withTracedDatabaseOperation("get_frame_processing_statuses_batch") { db in
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
        return try withTracedDatabaseOperation("get_pending_frame_ids_not_in_queue") { db in
            let sql = """
                SELECT f.id
                FROM frame f
                WHERE f.processingStatus = 0
                  AND NOT EXISTS (
                      SELECT 1
                      FROM processing_queue pq
                      WHERE pq.frameId = f.id
                  )
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
    }

    /// Count frames with pending status (processingStatus=0) that are NOT in the processing queue
    public func countPendingFramesNotInQueue() async throws -> Int {
        return try withTracedDatabaseOperation("count_pending_frames_not_in_queue") { db in
            let sql = """
                SELECT COUNT(*)
                FROM frame f
                WHERE f.processingStatus = 0
                  AND NOT EXISTS (
                      SELECT 1
                      FROM processing_queue pq
                      WHERE pq.frameId = f.id
                  );
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

    // MARK: - Schema Inspection

    /// Returns a human-readable description of the database schema
    public func getSchemaDescription() async throws -> String {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        var result = "DATABASE SCHEMA\n"
        result += "===============\n\n"

        // Get all tables
        let tablesSql = "SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name;"
        var tablesStmt: OpaquePointer?
        defer { sqlite3_finalize(tablesStmt) }

        guard sqlite3_prepare_v2(db, tablesSql, -1, &tablesStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: tablesSql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        while sqlite3_step(tablesStmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(tablesStmt, 0) else { continue }
            let tableName = String(cString: namePtr)

            // Skip internal SQLite tables
            if tableName.hasPrefix("sqlite_") { continue }

            result += "TABLE: \(tableName)\n"
            result += String(repeating: "-", count: tableName.count + 7) + "\n"

            // Get column info
            let pragmaSql = "PRAGMA table_info(\(tableName));"
            var pragmaStmt: OpaquePointer?

            if sqlite3_prepare_v2(db, pragmaSql, -1, &pragmaStmt, nil) == SQLITE_OK {
                while sqlite3_step(pragmaStmt) == SQLITE_ROW {
                    let colName = sqlite3_column_text(pragmaStmt, 1).map { String(cString: $0) } ?? "?"
                    let colType = sqlite3_column_text(pragmaStmt, 2).map { String(cString: $0) } ?? "?"
                    let notNull = sqlite3_column_int(pragmaStmt, 3) != 0
                    let isPK = sqlite3_column_int(pragmaStmt, 5) != 0

                    var colDesc = "  \(colName) \(colType)"
                    if isPK { colDesc += " PRIMARY KEY" }
                    if notNull { colDesc += " NOT NULL" }
                    result += colDesc + "\n"
                }
                sqlite3_finalize(pragmaStmt)
            }

            result += "\n"
        }

        // Get indexes
        result += "INDEXES\n"
        result += "-------\n"

        let indexSql = "SELECT name, tbl_name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY tbl_name, name;"
        var indexStmt: OpaquePointer?
        defer { sqlite3_finalize(indexStmt) }

        guard sqlite3_prepare_v2(db, indexSql, -1, &indexStmt, nil) == SQLITE_OK else {
            return result + "Error loading indexes\n"
        }

        while sqlite3_step(indexStmt) == SQLITE_ROW {
            let name = sqlite3_column_text(indexStmt, 0).map { String(cString: $0) } ?? "?"
            let table = sqlite3_column_text(indexStmt, 1).map { String(cString: $0) } ?? "?"
            result += "  \(name) ON \(table)\n"
        }

        return result
    }

    private static func localDayText(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func parseLocalDay(_ localDay: String) -> Date? {
        let parts = localDay.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private func allocatedFileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ])
        if let totalAllocatedSize = values.totalFileAllocatedSize {
            return Int64(totalAllocatedSize)
        }
        if let allocatedSize = values.fileAllocatedSize {
            return Int64(allocatedSize)
        }
        if let fileSize = values.fileSize {
            return Int64(fileSize)
        }

        throw DatabaseError.queryFailed(
            query: "stat \(url.path)",
            underlying: "Unable to resolve allocated file size"
        )
    }

    private func allocatedFileSizeIfPresent(at url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }
        return try allocatedFileSize(at: url)
    }
}
