import Foundation
import SQLCipher
import Shared

/// Service for mapping between UUID-based IDs (Swift models) and INTEGER IDs (database)
/// This enables backward compatibility during the Rewind schema migration
///
/// Strategy:
/// - Swift models continue using UUID-based IDs (FrameID, SegmentID, etc.)
/// - Database uses INTEGER auto-increment IDs (Rewind schema)
/// - This service maintains the mapping between the two
///
/// Owner: DATABASE agent
public actor IDMappingService {

    // MARK: - Properties

    private let db: OpaquePointer

    /// In-memory caches for fast lookups
    private var frameUUIDToInt: [UUID: Int64] = [:]
    private var frameIntToUUID: [Int64: UUID] = [:]

    private var segmentUUIDToInt: [UUID: Int64] = [:]
    private var segmentIntToUUID: [Int64: UUID] = [:]

    private var sessionUUIDToInt: [UUID: Int64] = [:]
    private var sessionIntToUUID: [Int64: UUID] = [:]

    // MARK: - Initialization

    public init(db: OpaquePointer) {
        self.db = db
    }

    /// Load mappings from database into memory cache
    public func initialize() throws {
        print("[IDMappingService] Loading UUID mappings into cache...")
        try loadMappings(entityType: "frame", uuidToInt: &frameUUIDToInt, intToUUID: &frameIntToUUID)
        try loadMappings(entityType: "segment", uuidToInt: &segmentUUIDToInt, intToUUID: &segmentIntToUUID)
        try loadMappings(entityType: "session", uuidToInt: &sessionUUIDToInt, intToUUID: &sessionIntToUUID)
        print("[IDMappingService] Loaded \(frameUUIDToInt.count) frame, \(segmentUUIDToInt.count) segment, \(sessionUUIDToInt.count) session mappings")
    }

    // MARK: - Frame Mappings

    /// Register a new frame UUID → INTEGER mapping
    public func registerFrame(uuid: UUID, dbID: Int64) throws {
        frameUUIDToInt[uuid] = dbID
        frameIntToUUID[dbID] = uuid
        try persistMapping(entityType: "frame", uuid: uuid, dbID: dbID)
    }

    /// Get database ID for a frame UUID
    public func getFrameDBID(for uuid: UUID) -> Int64? {
        frameUUIDToInt[uuid]
    }

    /// Get UUID for a frame database ID
    public func getFrameUUID(for dbID: Int64) -> UUID? {
        frameIntToUUID[dbID]
    }

    // MARK: - Segment Mappings

    /// Register a new segment UUID → INTEGER mapping
    public func registerSegment(uuid: UUID, dbID: Int64) throws {
        segmentUUIDToInt[uuid] = dbID
        segmentIntToUUID[dbID] = uuid
        try persistMapping(entityType: "segment", uuid: uuid, dbID: dbID)
    }

    /// Get database ID for a segment UUID
    public func getSegmentDBID(for uuid: UUID) -> Int64? {
        segmentUUIDToInt[uuid]
    }

    /// Get UUID for a segment database ID
    public func getSegmentUUID(for dbID: Int64) -> UUID? {
        segmentIntToUUID[dbID]
    }

    // MARK: - Session Mappings

    /// Register a new session UUID → INTEGER mapping
    public func registerSession(uuid: UUID, dbID: Int64) throws {
        sessionUUIDToInt[uuid] = dbID
        sessionIntToUUID[dbID] = uuid
        try persistMapping(entityType: "session", uuid: uuid, dbID: dbID)
    }

    /// Get database ID for a session UUID
    public func getSessionDBID(for uuid: UUID) -> Int64? {
        sessionUUIDToInt[uuid]
    }

    /// Get UUID for a session database ID
    public func getSessionUUID(for dbID: Int64) -> UUID? {
        sessionIntToUUID[dbID]
    }

    // MARK: - Bulk Operations

    /// Remove old mappings for cleanup
    public func purgeMappings(olderThan date: Date) throws {
        let timestamp = Int64(date.timeIntervalSince1970 * 1000)
        let sql = "DELETE FROM uuid_mappings WHERE created_at < ?;"

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

        sqlite3_bind_int64(statement, 1, timestamp)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        print("[IDMappingService] Purged old mappings before \(date)")
    }

    /// Get statistics about mapping cache
    public func getStatistics() -> (frames: Int, segments: Int, sessions: Int) {
        (frameUUIDToInt.count, segmentUUIDToInt.count, sessionUUIDToInt.count)
    }

    // MARK: - Private Helpers

    private func loadMappings(
        entityType: String,
        uuidToInt: inout [UUID: Int64],
        intToUUID: inout [Int64: UUID]
    ) throws {
        let sql = "SELECT uuid, db_id FROM uuid_mappings WHERE entity_type = ?;"

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

        sqlite3_bind_text(statement, 1, entityType, -1, SQLITE_TRANSIENT)

        while sqlite3_step(statement) == SQLITE_ROW {
            let uuidString = String(cString: sqlite3_column_text(statement, 0))
            let dbID = sqlite3_column_int64(statement, 1)

            guard let uuid = UUID(uuidString: uuidString) else {
                print("[IDMappingService] Warning: Invalid UUID in mapping: \(uuidString)")
                continue
            }

            uuidToInt[uuid] = dbID
            intToUUID[dbID] = uuid
        }
    }

    private func persistMapping(entityType: String, uuid: UUID, dbID: Int64) throws {
        let sql = """
            INSERT OR REPLACE INTO uuid_mappings (entity_type, uuid, db_id, created_at)
            VALUES (?, ?, ?, ?);
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

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        sqlite3_bind_text(statement, 1, entityType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, uuid.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 3, dbID)
        sqlite3_bind_int64(statement, 4, timestamp)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }
}

// MARK: - Convenience Extensions

extension IDMappingService {

    /// Register frame using FrameID type
    public func registerFrame(id: FrameID, dbID: Int64) throws {
        try registerFrame(uuid: id.value, dbID: dbID)
    }

    /// Get database ID using FrameID type
    public func getFrameDBID(for id: FrameID) -> Int64? {
        getFrameDBID(for: id.value)
    }

    /// Register segment using SegmentID type
    public func registerSegment(id: SegmentID, dbID: Int64) throws {
        try registerSegment(uuid: id.value, dbID: dbID)
    }

    /// Get database ID using SegmentID type
    public func getSegmentDBID(for id: SegmentID) -> Int64? {
        getSegmentDBID(for: id.value)
    }

    /// Register session using AppSessionID type
    public func registerSession(id: AppSessionID, dbID: Int64) throws {
        try registerSession(uuid: id.value, dbID: dbID)
    }

    /// Get database ID using AppSessionID type
    public func getSessionDBID(for id: AppSessionID) -> Int64? {
        getSessionDBID(for: id.value)
    }
}
