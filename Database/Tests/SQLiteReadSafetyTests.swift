import Foundation
import XCTest
import SQLCipher
import Shared
@testable import Database

final class SQLiteReadSafetyTests: XCTestCase {
    func testRewindDateBindingsSurviveAutoreleasePool() async throws {
        try await withDatabase { db in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT ?, ?;", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let config = DatabaseConfig.rewind(cutoffDate: .distantFuture)
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let end = start.addingTimeInterval(86_400)
            let expected = [config.dateFormatter!.string(from: start), config.dateFormatter!.string(from: end)]
            autoreleasepool {
                config.bindDate(start, to: statement!, at: 1)
                config.bindDate(end, to: statement!, at: 2)
            }
            // Exercise reuse of Foundation's released string buffers before SQLite reads them.
            autoreleasepool {
                let strings = (0..<100).map { NSString(format: "%023d", $0) }
                _ = strings.map { $0.utf8String }
                XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
                XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), expected[0])
                XCTAssertEqual(String(cString: sqlite3_column_text(statement, 1)), expected[1])
            }
        }
    }

    func testLookupsDistinguishMissingRowsFromInterruptedReads() async throws {
        try await withDatabase { db in
            let videoID = try SegmentQueries.insert(db: db, segment: VideoSegment(
                id: VideoSegmentID(value: 0), startTime: Date(), endTime: Date(),
                frameCount: 1, fileSizeBytes: 100, relativePath: "chunks/test/123", width: 64, height: 64
            ))
            XCTAssertNotNil(try SegmentQueries.getByID(db: db, id: VideoSegmentID(value: videoID)))
            XCTAssertNil(try SegmentQueries.getByID(db: db, id: VideoSegmentID(value: -1)))
            XCTAssertNil(try FrameQueries.getByID(db: db, id: FrameID(value: -1)))
            XCTAssertNil(try AppSegmentQueries.getByID(db: db, id: -1))

            sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_STMT), { _, context, _, _ in
                sqlite3_interrupt(OpaquePointer(context!))
                return 0
            }, UnsafeMutableRawPointer(db))
            defer { sqlite3_trace_v2(db, 0, nil, nil) }
            XCTAssertThrowsError(try SegmentQueries.getByID(db: db, id: VideoSegmentID(value: videoID)))
            XCTAssertThrowsError(try FrameQueries.getByID(db: db, id: FrameID(value: -1)))
            XCTAssertThrowsError(try AppSegmentQueries.getByID(db: db, id: -1))
            XCTAssertThrowsError(try SegmentQueries.getByTimeRange(db: db, from: .distantPast, to: .distantFuture))
        }
    }

    func testBusyReadRetriesOnceAndPreservesBindings() throws {
        try withLockedRead(releaseOnFirstBusy: true) { db, statement, context in
            XCTAssertEqual(try SQLiteReadStep.next(statement), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "kept binding")
            XCTAssertEqual(try SQLiteReadStep.next(statement), SQLITE_DONE)
            XCTAssertEqual(context.calls, 1)
        }
    }

    func testPersistentBusyReadThrowsAfterOneRetry() throws {
        try withLockedRead(releaseOnFirstBusy: false) { _, statement, context in
            XCTAssertThrowsError(try SQLiteReadStep.next(statement))
            XCTAssertEqual(context.calls, 2)
        }
    }

    func testReadErrorAfterFirstRowDoesNotReturnPartialCollection() async throws {
        try await withDatabase { db in
            XCTAssertEqual(sqlite3_exec(db, """
                INSERT INTO segment(id,bundleID,startDate,endDate,type) VALUES(1,'example',0,10,0);
                INSERT INTO video(id,height,width,path,fileSize,frameRate,processingState) VALUES(1,64,64,'test',100,30,0);
                INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex) VALUES(1,1,'one',1,1,0),(2,2,'two',1,1,1);
                """, nil, nil, nil), SQLITE_OK)
            sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_ROW), { _, context, _, _ in
                sqlite3_interrupt(OpaquePointer(context!))
                return 0
            }, UnsafeMutableRawPointer(db))
            defer { sqlite3_trace_v2(db, 0, nil, nil) }
            XCTAssertThrowsError(try FrameQueries.getByTimeRange(db: db, from: .distantPast, to: .distantFuture, limit: 10))
        }
    }

    private final class BusyContext {
        let writer: OpaquePointer
        let releaseOnFirstBusy: Bool
        var calls = 0
        init(writer: OpaquePointer, releaseOnFirstBusy: Bool) {
            self.writer = writer
            self.releaseOnFirstBusy = releaseOnFirstBusy
        }
    }

    private func withLockedRead(
        releaseOnFirstBusy: Bool,
        body: (OpaquePointer, OpaquePointer, BusyContext) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadRetry_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test.db").path
        var reader: OpaquePointer?, writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &reader), SQLITE_OK)
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        let db = try XCTUnwrap(reader), other = try XCTUnwrap(writer)
        defer { sqlite3_close(db); sqlite3_close(other) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE sample(id INTEGER); INSERT INTO sample VALUES(1);", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT ? FROM sample;", -1, &statement, nil), SQLITE_OK)
        let read = try XCTUnwrap(statement)
        defer { sqlite3_finalize(read) }
        sqlite3_bind_text(read, 1, "kept binding", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_exec(other, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        defer { sqlite3_exec(other, "ROLLBACK;", nil, nil, nil) }
        let context = BusyContext(writer: other, releaseOnFirstBusy: releaseOnFirstBusy)
        sqlite3_busy_handler(db, { pointer, _ in
            let context = Unmanaged<BusyContext>.fromOpaque(pointer!).takeUnretainedValue()
            context.calls += 1
            if context.releaseOnFirstBusy { sqlite3_exec(context.writer, "ROLLBACK;", nil, nil, nil) }
            return 0
        }, Unmanaged.passUnretained(context).toOpaque())
        defer { sqlite3_busy_handler(db, nil, nil) }
        try body(db, read, context)
    }

    private func withDatabase(_ body: (OpaquePointer) throws -> Void) async throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        defer { sqlite3_close(db) }
        try await MigrationRunner(db: db).runMigrations()
        try body(db)
    }
}
