import Foundation
import SQLCipher
import Shared

/// Auxiliary, idempotent schema: deliberately independent of numbered migrations
/// so the in-flight encrypted-database migration can still apply its V21 identity step.
enum AccessibilitySnapshotQueries {
    static func ensureSchema(db: OpaquePointer) throws {
        try execute(db, """
        CREATE TABLE IF NOT EXISTS frame_accessibility (
          frame_id INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE,
          payload BLOB CHECK(payload IS NULL OR length(payload)<=131100),
          state TEXT NOT NULL CHECK(state IN ('saved','unavailable','key_unavailable','processed')),
          processed INTEGER NOT NULL DEFAULT 0
        );
        CREATE TRIGGER IF NOT EXISTS frame_ax_delete AFTER DELETE ON frame
        BEGIN DELETE FROM frame_accessibility WHERE frame_id=OLD.id; END;
        CREATE TRIGGER IF NOT EXISTS frame_ax_finish AFTER UPDATE OF processingStatus ON frame
        WHEN NEW.processingStatus IN (2,3,5,7)
        BEGIN
          UPDATE frame_accessibility SET payload=NULL,state='processed',processed=1 WHERE frame_id=NEW.id;
        END;
        """)
    }
    static func insert(db: OpaquePointer, frameID: Int64, snapshot: AccessibilitySnapshot?, keyProvider: () throws -> Data = captureKey) throws {
        var payload: Data?
        var state = "unavailable"
        if let snapshot {
            do {
                // The same recoverable key used by protected OCR; never write AX plaintext.
                payload = try snapshot.sealed(masterKey: keyProvider(), identity: "frame:\(frameID)")
                state = "saved"
            } catch { state = "key_unavailable" }
        }
        let sql = "INSERT INTO frame_accessibility(frame_id,payload,state) VALUES (?,?,?);"
        let stmt = try prepare(db,sql); defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt,1,frameID)
        if let payload { _ = payload.withUnsafeBytes { sqlite3_bind_blob(stmt,2,$0.baseAddress,Int32(payload.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) } }
        else { sqlite3_bind_null(stmt,2) }
        sqlite3_bind_text(stmt,3,state,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    static func load(db: OpaquePointer, frameID: Int64, keyProvider: () throws -> Data = MasterKeyManager.loadMasterKey) throws -> AccessibilitySnapshot? {
        let stmt = try prepare(db,"SELECT payload FROM frame_accessibility WHERE frame_id=?;")
        defer { sqlite3_finalize(stmt) }; sqlite3_bind_int64(stmt,1,frameID)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw failure() }
        guard let bytes = sqlite3_column_blob(stmt,0) else { return nil }
        let data = Data(bytes:bytes,count:Int(sqlite3_column_bytes(stmt,0)))
        return try AccessibilitySnapshot.open(data,masterKey:keyProvider(),identity:"frame:\(frameID)")
    }
    static func captureKey() throws -> Data {
        _ = try MasterKeyManager.createMasterKeyIfNeeded()
        return try MasterKeyManager.loadMasterKey()
    }
    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw failure() }
    }
    private static func prepare(_ db: OpaquePointer,_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    private static func failure() -> DatabaseError { .queryFailed(query:"accessibility snapshot",underlying:"Snapshot storage operation failed") }
}
