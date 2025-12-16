import Foundation
import SQLite3
import Shared
import CoreGraphics

// MARK: - Text Region Queries

/// SQL queries for text_regions table
/// Owner: DATABASE agent
enum TextRegionQueries {

    // MARK: - Insert

    static func insert(db: OpaquePointer, region: TextRegion) throws {
        let sql = """
            INSERT INTO text_regions (
                frame_id, text, x, y, width, height, confidence
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
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

        sqlite3_bind_text(statement, 1, region.frameID.stringValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, region.text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 3, Int64(region.x))
        sqlite3_bind_int64(statement, 4, Int64(region.y))
        sqlite3_bind_int64(statement, 5, Int64(region.width))
        sqlite3_bind_int64(statement, 6, Int64(region.height))
        if let confidence = region.confidence {
            sqlite3_bind_double(statement, 7, confidence)
        } else {
            sqlite3_bind_null(statement, 7)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Select

    static func getByFrameID(db: OpaquePointer, frameID: FrameID) throws -> [TextRegion] {
        let sql = """
            SELECT id, frame_id, text, x, y, width, height, confidence, created_at
            FROM text_regions
            WHERE frame_id = ?
            ORDER BY y ASC, x ASC
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

        sqlite3_bind_text(statement, 1, frameID.stringValue, -1, SQLITE_TRANSIENT)

        var results: [TextRegion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseTextRegion(statement: statement!))
        }
        return results
    }

    // MARK: - Delete

    static func deleteByFrameID(db: OpaquePointer, frameID: FrameID) throws {
        let sql = "DELETE FROM text_regions WHERE frame_id = ?"

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

        sqlite3_bind_text(statement, 1, frameID.stringValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Helper

    private static func parseTextRegion(statement: OpaquePointer) throws -> TextRegion {
        let id = sqlite3_column_int64(statement, 0)
        let frameID = FrameID(string: String(cString: sqlite3_column_text(statement, 1)))!
        let text = String(cString: sqlite3_column_text(statement, 2))
        let x = Int(sqlite3_column_int64(statement, 3))
        let y = Int(sqlite3_column_int64(statement, 4))
        let width = Int(sqlite3_column_int64(statement, 5))
        let height = Int(sqlite3_column_int64(statement, 6))
        let confidence = sqlite3_column_type(statement, 7) != SQLITE_NULL
            ? sqlite3_column_double(statement, 7)
            : nil
        let createdAt = Schema.timestampToDate(sqlite3_column_int64(statement, 8))

        return TextRegion(
            id: id,
            frameID: frameID,
            text: text,
            x: x,
            y: y,
            width: width,
            height: height,
            confidence: confidence,
            createdAt: createdAt
        )
    }
}
