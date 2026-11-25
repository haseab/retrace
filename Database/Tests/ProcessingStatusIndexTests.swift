import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class ProcessingStatusIndexTests: XCTestCase {
    private final class Trace {
        var queries: [String] = []
        var indexCreates = 0
    }

    func testFreshLibraryIndexExcludesCompletedFramesAndTracksTransitions() async throws {
        try await withDatabase { _, db in
            try self.seed(db)
            XCTAssertEqual(try self.scalar(db, "SELECT partial FROM pragma_index_list('frame') WHERE name='idx_frame_processing_status';"), 1)
            XCTAssertEqual(try self.scalar(db, "SELECT SUM(ncell) FROM dbstat WHERE name='idx_frame_processing_status';"), 8)
            XCTAssertEqual(try self.scalar(db, "SELECT COUNT(*) FROM frame;"), 20_009)
            try self.execute(db, "UPDATE frame SET processingStatus=0 WHERE id=1;")
            XCTAssertEqual(try self.scalar(db, "SELECT SUM(ncell) FROM dbstat WHERE name='idx_frame_processing_status';"), 9)
            try self.execute(db, "UPDATE frame SET processingStatus=2 WHERE id=1;")
            XCTAssertEqual(try self.scalar(db, "SELECT SUM(ncell) FROM dbstat WHERE name='idx_frame_processing_status';"), 8)
            // Rewritten (7), failed (3/8), and unreadable (4) states remain represented.
            XCTAssertEqual(try self.scalar(db, "SELECT COUNT(*) FROM frame INDEXED BY idx_frame_processing_status WHERE processingStatus != 2;"), 8)
        }
    }

    func testExistingV19LibraryUpgradesOnceWithoutChangingFrameData() async throws {
        try await withDatabase { _, db in
            try self.seed(db)
            // Reconstruct the old V19 index and migration ledger on real migrated tables.
            try self.execute(db, """
                DROP INDEX idx_frame_processing_status;
                CREATE INDEX idx_frame_processing_status ON frame(processingStatus);
                DELETE FROM schema_migrations WHERE version>=20;
                """)
            let previousBytes = try self.scalar(db, "SELECT SUM(pgsize) FROM dbstat WHERE name='idx_frame_processing_status';")
            let runner = MigrationRunner(db: db)
            try await runner.runMigrations()
            XCTAssertEqual(try self.scalar(db, "SELECT partial FROM pragma_index_list('frame') WHERE name='idx_frame_processing_status';"), 1)
            XCTAssertEqual(try self.scalar(db, "SELECT COUNT(*) FROM frame WHERE processingStatus=2;"), 20_000)
            XCTAssertEqual(try self.scalar(db, "SELECT COUNT(*) FROM frame WHERE processingStatus IS NULL;"), 1)
            XCTAssertEqual(try self.scalar(db, "SELECT COUNT(*) FROM frame;"), 20_009)
            XCTAssertLessThan(try self.scalar(db, "SELECT SUM(pgsize) FROM dbstat WHERE name='idx_frame_processing_status';"), previousBytes)
            XCTAssertEqual(try self.scalar(db, "SELECT COUNT(*) FROM schema_migrations WHERE version=20;"), 1)
            let trace = Trace()
            sqlite3_set_authorizer(db, { context, action, _, _, _, _ in
                if let context, action == SQLITE_CREATE_INDEX {
                    Unmanaged<Trace>.fromOpaque(context).takeUnretainedValue().indexCreates += 1
                }
                return SQLITE_OK
            }, Unmanaged.passUnretained(trace).toOpaque())
            defer { sqlite3_set_authorizer(db, nil, nil) }
            try await runner.runMigrations()
            XCTAssertEqual(trace.indexCreates, 0, "Already-applied migration must not rebuild the index")
        }
    }

    func testProductionBacklogQueriesUsePartialIndexAndPreserveResults() async throws {
        try await withDatabase { database, db in
            try self.seed(db)
            let trace = Trace()
            sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
                guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                let text = String(cString: sql)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("SELECT"), text.contains("processingStatus") {
                    Unmanaged<Trace>.fromOpaque(context).takeUnretainedValue().queries.append(text)
                }
                return 0
            }, Unmanaged.passUnretained(trace).toOpaque())
            defer { sqlite3_trace_v2(db, 0, nil, nil) }
            let counts = try await database.getFrameStatusCounts()
            XCTAssertEqual([counts.ocrPending, counts.ocrProcessing, counts.rewritePending, counts.rewriteProcessing], [1,1,1,1])
            let pending = try await database.getPendingFrameCount()
            XCTAssertEqual(pending, 3)
            let crashed = try await database.getCrashedProcessingFrameIDs()
            XCTAssertEqual(crashed, [20_002])
            let unreadable = try await database.getUnreadableFrameCount()
            XCTAssertEqual(unreadable, 1)
            let recentUnreadable = try await database.getUnreadableFrameCount(withinLastMinutes: 1)
            XCTAssertEqual(recentUnreadable, 0)
            let unqueued = try await database.getPendingFrameIDsNotInQueue(limit: 100)
            XCTAssertEqual(unqueued, [20_001])
            let unqueuedCount = try await database.countPendingFramesNotInQueue()
            XCTAssertEqual(unqueuedCount, 1)
            let queries = trace.queries
            sqlite3_trace_v2(db, 0, nil, nil)
            XCTAssertEqual(queries.count, 7, "Capture the real production SQL, not test copies of its predicates")
            for sql in queries {
                let plan = try self.queryPlan(db, sql)
                XCTAssertTrue(plan.contains("idx_frame_processing_status"), "Backlog lookup lost its status index: \(plan)")
            }
            // Timeline/primary-key reads still expose completed rows normally.
            let completedStatus = try await database.getFrameProcessingStatus(frameID: 1)
            XCTAssertEqual(completedStatus, 2)
        }
    }

    func testFailedIndexReplacementKeepsOldIndexAndMigrationVersion() async throws {
        try await withDatabase { _, db in
            try self.execute(db, """
                DROP INDEX idx_frame_processing_status;
                CREATE INDEX idx_frame_processing_status ON frame(processingStatus);
                DELETE FROM schema_migrations WHERE version>=20;
                """)
            sqlite3_set_authorizer(db, { _, action, _, _, _, _ in
                action == SQLITE_CREATE_INDEX ? SQLITE_DENY : SQLITE_OK
            }, nil)
            do {
                try await MigrationRunner(db: db).runMigrations()
                XCTFail("Expected index creation failure")
            } catch {}
            sqlite3_set_authorizer(db, nil, nil)
            XCTAssertEqual(try self.scalar(db, "SELECT partial FROM pragma_index_list('frame') WHERE name='idx_frame_processing_status';"), 0)
            XCTAssertEqual(try self.scalar(db, "SELECT MAX(version) FROM schema_migrations;"), 19)
            try await MigrationRunner(db: db).runMigrations()
            XCTAssertEqual(try self.scalar(db, "SELECT partial FROM pragma_index_list('frame') WHERE name='idx_frame_processing_status';"), 1)
        }
    }

    func testRewriteDeletionAndReadabilityConsumersKeepTheirStatusSemantics() async throws {
        try await withDatabase { database, db in
            try self.seed(db)
            try self.execute(db, """
                INSERT INTO video(id,height,width,path,fileSize,frameRate,processingState) VALUES (1,100,100,'video',1,30,0);
                UPDATE frame SET videoId=1, videoFrameIndex=id, rewritePurpose='redaction' WHERE id IN (1,20005,20006,20007,20008);
                UPDATE frame SET rewritePurpose='deletion' WHERE id=20006;
                INSERT INTO node(frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height,encryptedText)
                  SELECT id,0,0,1,0,0,1,1,'rtx-permanent-v1' FROM frame WHERE id IN (1,20005,20006,20007,20008);
                """)
            let rewriteVideos = try await database.getVideoIDsWithPendingRewrites(includeRetryableFailures: true)
            XCTAssertEqual(rewriteVideos, [1])
            let redactionVideos = try await database.getVideoIDsWithPendingNodeRedactions(includeRetryableFailures: true)
            XCTAssertEqual(redactionVideos, [1])
            let pending = try await database.getPendingNodeRedactionJobs(videoID: 1, includeInProgressJobs: true, includeRetryableFailures: true)
            XCTAssertEqual(pending.map(\.frameID).sorted(), [20_005,20_008])
            let deletions = try await database.getPendingFrameDeletionJobs(videoID: 1, includeInProgressJobs: true, includeRetryableFailures: true)
            XCTAssertEqual(deletions.map(\.frameID), [20_006])
            let waitingBefore = try await database.videoHasFramesAwaitingOCR(videoID: 1)
            XCTAssertFalse(waitingBefore)
            try self.execute(db, "UPDATE frame SET videoId=1 WHERE id=20004;")
            let waitingAfter = try await database.videoHasFramesAwaitingOCR(videoID: 1)
            XCTAssertTrue(waitingAfter)
            let abandoned = try await database.abandonPendingNodeRedactions(missingKeyRewritePurpose: "missing-key")
            XCTAssertEqual(abandoned, 2)
            XCTAssertEqual(try self.scalar(db, "SELECT processingStatus FROM frame WHERE id=1;"), 2)
            XCTAssertEqual(try self.scalar(db, "SELECT processingStatus FROM frame WHERE id=20007;"), 7)
        }
    }

    private func seed(_ db: OpaquePointer) throws {
        try execute(db, """
            WITH RECURSIVE n(id) AS (VALUES(1) UNION ALL SELECT id+1 FROM n WHERE id<20000)
            INSERT INTO frame(id,createdAt,imageFileName,processingStatus) SELECT id,1000,'completed',2 FROM n;
            INSERT INTO frame(id,createdAt,imageFileName,processingStatus) VALUES
              (20001,1000,'pending',0),(20002,1000,'processing',1),(20003,1000,'failed',3),(20004,1000,'unreadable',4),
              (20005,1000,'rewrite',5),(20006,1000,'rewriting',6),(20007,1000,'rewritten',7),(20008,1000,'retry',8),(20009,1000,'legacy',NULL);
            """)
    }

    private func withDatabase(_ operation: (DatabaseManager, OpaquePointer) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databasePath: root.appendingPathComponent("db.sqlite").path, storageRootPath: root.path)
        try await database.initialize()
        do {
            let connection = await database.getConnection()
            let db = try XCTUnwrap(connection)
            try await operation(database, db)
            try await database.close()
        } catch {
            try? await database.close()
            throw error
        }
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func queryPlan(_ db: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 3) { details.append(String(cString: text)) }
        }
        return details.joined(separator: "; ")
    }
}
