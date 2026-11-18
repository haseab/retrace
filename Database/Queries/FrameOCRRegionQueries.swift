import Foundation
import CoreGraphics
import SQLCipher
import Shared

/// Bounded geometry-only payload. Independent of numbered migrations; survives OCR completion.
enum FrameOCRRegionQueries {
    private struct Payload: Codable {
        let version: Int
        let windows: [CGRect]
    }

    static func ensureSchema(db: OpaquePointer) throws {
        try execute(db, """
        CREATE TABLE IF NOT EXISTS frame_ocr_regions (
          frame_id INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE,
          payload BLOB NOT NULL CHECK(length(payload)<=16384)
        );
        CREATE TRIGGER IF NOT EXISTS frame_ocr_regions_delete AFTER DELETE ON frame
        BEGIN DELETE FROM frame_ocr_regions WHERE frame_id=OLD.id; END;
        """)
    }

    static func insert(db: OpaquePointer, frameID: Int64, regions: [CGRect]?) throws {
        guard let regions, regions.count <= 16,
              let data = try? JSONEncoder().encode(Payload(version: 2, windows: regions)), data.count <= 16384 else { return }
        let sql = "INSERT INTO frame_ocr_regions(frame_id,payload) VALUES (?,?);"
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, frameID)
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    static func load(db: OpaquePointer, frameID: Int64) throws -> [CGRect]? {
        let statement = try prepare(db, "SELECT payload FROM frame_ocr_regions WHERE frame_id=?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, frameID)
        guard try SQLiteReadStep.next(statement) == SQLITE_ROW,
              sqlite3_column_bytes(statement, 0) <= 16384,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 2, payload.windows.count <= 16 else { return nil }
        return payload.windows
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private static func failure() -> DatabaseError {
        .queryFailed(query: "frame OCR regions", underlying: "Window geometry storage operation failed")
    }
}
