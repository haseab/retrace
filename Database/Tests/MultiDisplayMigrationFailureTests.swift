import Foundation
import XCTest
import SQLCipher
@testable import Database

final class MultiDisplayMigrationFailureTests: XCTestCase {
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw NSError(domain: "MigrationRegression", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "MigrationRegression", code: 1)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func seedV20(_ db: OpaquePointer, rows: Int) throws {
        try execute(db, """
            CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER);
            INSERT INTO schema_migrations VALUES(20, 1000);
            CREATE TABLE frame(id INTEGER PRIMARY KEY, createdAt INTEGER, redactionReason TEXT,
                               capture_trigger TEXT, encodedAt INTEGER);
            CREATE TABLE video(id INTEGER PRIMARY KEY, width INTEGER, height INTEGER, processingState INTEGER);
            INSERT INTO video VALUES(1, 1920, 1080, 1);
            WITH RECURSIVE numbers(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM numbers WHERE id < \(rows))
            INSERT INTO frame SELECT id, id*2000, 'private window', 'mouse', id*2000+100 FROM numbers;
            """)
    }

    private func assertRolledBack(_ db: OpaquePointer, rows: Int) throws {
        XCTAssertEqual(try scalar(db, "SELECT MAX(version) FROM schema_migrations"), 20)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM pragma_table_info('frame') WHERE name IN ('displayID','isFocused')"), 0)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM pragma_table_info('video') WHERE name='displayID'"), 0)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'idx_frame_display%' OR name='display_session'"), 0)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM frame WHERE redactionReason='private window' AND capture_trigger='mouse' AND encodedAt=createdAt+100"), Int64(rows))
    }

    func testEncryptedDiskFullUpgradeRollsBackAndRetriesAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("migration.db")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        var db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        // Invented fixture key, unrelated to any application/user key material.
        try execute(db, "PRAGMA key='migration-regression-fixture';")
        let rows = 100_000
        try seedV20(db, rows: rows)
        let pages = try scalar(db, "PRAGMA page_count")
        try execute(db, "PRAGMA max_page_count=\(pages)")
        do {
            try await MigrationRunner(db: db).runMigrations()
            XCTFail("Expected SQLITE_FULL while building display indexes")
        } catch {
            XCTAssertTrue(String(describing: error).lowercased().contains("full"))
        }
        try assertRolledBack(db, rows: rows)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        connection = nil
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        db = try XCTUnwrap(connection)
        try execute(db, "PRAGMA key='migration-regression-fixture'; PRAGMA max_page_count=2147483646;")
        try assertRolledBack(db, rows: rows)
        let start = ContinuousClock.now
        try await MigrationRunner(db: db).runMigrations()
        let duration = start.duration(to: .now)
        XCTAssertEqual(try scalar(db, "SELECT MAX(version) FROM schema_migrations"), 21)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM frame WHERE displayID=0 AND isFocused=1 AND redactionReason='private window' AND encodedAt=createdAt+100"), Int64(rows))
        try await MigrationRunner(db: db).runMigrations()
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM schema_migrations WHERE version=21"), 1)
        let growth = try scalar(db, "PRAGMA page_count") - pages
        print("[Migration regression] encryptedRows=\(rows) duration=\(duration) additionalPages=\(growth)")
        XCTAssertNotEqual(try Data(contentsOf: url).prefix(16), Data("SQLite format 3\0".utf8))
    }

    func testInterruptedSecondIndexRollsBackEarlierColumnsAndIndex() async throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        try seedV20(db, rows: 5_000)
        let gate = IndexInterruptGate()
        let context = Unmanaged.passUnretained(gate).toOpaque()
        sqlite3_set_authorizer(db, { context, action, name, _, _, _ in
            guard let context else { return SQLITE_OK }
            let gate = Unmanaged<IndexInterruptGate>.fromOpaque(context).takeUnretainedValue()
            if action == SQLITE_CREATE_INDEX, let name,
               String(cString: name) == "idx_frame_isfocused_createdat" { gate.armed = true }
            return SQLITE_OK
        }, context)
        sqlite3_progress_handler(db, 1000, { context in
            guard let context else { return 0 }
            let gate = Unmanaged<IndexInterruptGate>.fromOpaque(context).takeUnretainedValue()
            if gate.armed { gate.ticks += 1 }
            return gate.ticks >= 5 ? 1 : 0
        }, context)
        do {
            try await MigrationRunner(db: db).runMigrations()
            XCTFail("Expected interrupted index creation")
        } catch {
            XCTAssertTrue(String(describing: error).lowercased().contains("interrupt"))
        }
        sqlite3_progress_handler(db, 0, nil, nil)
        sqlite3_set_authorizer(db, nil, nil)
        XCTAssertGreaterThanOrEqual(gate.ticks, 5)
        try assertRolledBack(db, rows: 5_000)
        try await MigrationRunner(db: db).runMigrations()
        XCTAssertEqual(try scalar(db, "SELECT MAX(version) FROM schema_migrations"), 21)
    }
}

private final class IndexInterruptGate {
    var armed = false
    var ticks = 0
}
