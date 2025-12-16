import Foundation
import SQLite3
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
        print("[DEBUG] Opening database...")
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI
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

    // MARK: - Frame Operations

    public func insertFrame(_ frame: FrameReference) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try FrameQueries.insert(db: db, frame: frame)
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

    public func getFrameCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getCount(db: db)
    }

    // MARK: - Segment Operations

    public func insertSegment(_ segment: VideoSegment) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SegmentQueries.insert(db: db, segment: segment)
    }

    public func getSegment(id: SegmentID) async throws -> VideoSegment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getByID(db: db, id: id)
    }

    public func getSegment(containingTimestamp date: Date) async throws -> VideoSegment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getByTimestamp(db: db, timestamp: date)
    }

    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [VideoSegment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getByTimeRange(db: db, from: startDate, to: endDate)
    }

    public func deleteSegment(id: SegmentID) async throws {
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

    // MARK: - App Session Operations

    public func insertSession(_ session: AppSession) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SessionQueries.insert(db: db, session: session)
    }

    public func updateSessionEndTime(id: AppSessionID, endTime: Date) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SessionQueries.updateEndTime(db: db, id: id, endTime: endTime)
    }

    public func getSession(id: AppSessionID) async throws -> AppSession? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SessionQueries.getByID(db: db, id: id)
    }

    public func getSessions(from startDate: Date, to endDate: Date) async throws -> [AppSession] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SessionQueries.getByTimeRange(db: db, from: startDate, to: endDate)
    }

    public func getActiveSession() async throws -> AppSession? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SessionQueries.getActive(db: db)
    }

    public func getSessions(appBundleID: String, limit: Int) async throws -> [AppSession] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SessionQueries.getByApp(db: db, appBundleID: appBundleID, limit: limit)
    }

    public func deleteSession(id: AppSessionID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SessionQueries.delete(db: db, id: id)
    }

    // MARK: - Text Region Operations

    public func insertTextRegion(_ region: TextRegion) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try TextRegionQueries.insert(db: db, region: region)
    }

    public func getTextRegions(frameID: FrameID) async throws -> [TextRegion] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try TextRegionQueries.getByFrameID(db: db, frameID: frameID)
    }

    public func getTextRegions(frameID: FrameID, inRect rect: CGRect) async throws -> [TextRegion] {
        // Get all regions for the frame, then filter by intersection
        let allRegions = try await getTextRegions(frameID: frameID)
        return allRegions.filter { region in
            region.bounds.intersects(rect)
        }
    }

    public func deleteTextRegions(frameID: FrameID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try TextRegionQueries.deleteByFrameID(db: db, frameID: frameID)
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
            SELECT MIN(timestamp), MAX(timestamp)
            FROM frames;
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
        let encryptionEnabled = UserDefaults.standard.object(forKey: "encryptionEnabled") as? Bool ?? true
        guard encryptionEnabled else {
            print("[DEBUG] Database encryption disabled")
            return
        }

        // Get or generate encryption key from Keychain
        let keychainService = "com.retrace.database"
        let keychainAccount = "sqlcipher-key"

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DatabaseError.connectionFailed(underlying: "Failed to save encryption key to Keychain")
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
}
