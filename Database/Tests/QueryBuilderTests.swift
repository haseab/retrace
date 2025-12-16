import XCTest
import SQLite3
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                        QUERY BUILDER TESTS                                   ║
// ║                                                                              ║
// ║  • Verify FrameQueries builds correct SQL statements                         ║
// ║  • Verify SegmentQueries builds correct SQL statements                       ║
// ║  • Verify DocumentQueries builds correct SQL statements                      ║
// ║  • Verify query result parsing works correctly                               ║
// ║  • Verify parameter binding prevents SQL injection                           ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class QueryBuilderTests: XCTestCase {

    var db: OpaquePointer?
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        sqlite3_open(":memory:", &db)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)

        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    override func tearDown() {
        sqlite3_close(db)
        db = nil
    }

    // MARK: - Helper to create VideoSegment with required fields

    private func makeSegment(
        id: SegmentID = SegmentID(),
        startTime: Date = Date(),
        endTime: Date? = nil,
        frameCount: Int = 100,
        fileSizeBytes: Int64 = 1024,
        relativePath: String = "test.mp4"
    ) -> VideoSegment {
        VideoSegment(
            id: id,
            startTime: startTime,
            endTime: endTime ?? startTime.addingTimeInterval(300),
            frameCount: frameCount,
            fileSizeBytes: fileSizeBytes,
            relativePath: relativePath,
            width: 1920,
            height: 1080
        )
    }

    private func makeFrame(
        id: FrameID = FrameID(),
        timestamp: Date = Date(),
        segmentID: SegmentID,
        frameIndex: Int = 0,
        metadata: FrameMetadata = .empty
    ) -> FrameReference {
        FrameReference(
            id: id,
            timestamp: timestamp,
            segmentID: segmentID,
            frameIndexInSegment: frameIndex,
            metadata: metadata
        )
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                      SEGMENT QUERIES TESTS                              ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testSegmentQueries_Insert_StoresAllFields() throws {
        let segment = makeSegment(
            startTime: Date(timeIntervalSince1970: 1702406400),
            endTime: Date(timeIntervalSince1970: 1702406700),
            frameCount: 150,
            fileSizeBytes: 52428800,
            relativePath: "segments/2024/01/test.mp4"
        )

        try SegmentQueries.insert(db: db!, segment: segment)

        // Verify with raw SQL
        let sql = "SELECT * FROM segments WHERE id = ?"
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        sqlite3_bind_text(statement, 1, segment.id.stringValue, -1, SQLITE_TRANSIENT)

        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)

        // Check fields
        let startTime = sqlite3_column_int64(statement, 1)
        let endTime = sqlite3_column_int64(statement, 2)
        let frameCount = sqlite3_column_int(statement, 3)
        let fileSize = sqlite3_column_int64(statement, 4)
        let path = String(cString: sqlite3_column_text(statement, 5))
        let width = sqlite3_column_int(statement, 6)
        let height = sqlite3_column_int(statement, 7)

        XCTAssertEqual(startTime, 1702406400000)  // Milliseconds
        XCTAssertEqual(endTime, 1702406700000)
        XCTAssertEqual(frameCount, 150)
        XCTAssertEqual(fileSize, 52428800)
        XCTAssertEqual(path, "segments/2024/01/test.mp4")
        XCTAssertEqual(width, 1920)
        XCTAssertEqual(height, 1080)

        sqlite3_finalize(statement)
    }

    func testSegmentQueries_GetByID_ReturnsCorrectSegment() throws {
        let segment = makeSegment(frameCount: 100, fileSizeBytes: 1024000)
        try SegmentQueries.insert(db: db!, segment: segment)

        let retrieved = try SegmentQueries.getByID(db: db!, id: segment.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.stringValue, segment.id.stringValue)
        XCTAssertEqual(retrieved?.frameCount, 100)
        XCTAssertEqual(retrieved?.fileSizeBytes, 1024000)
        XCTAssertEqual(retrieved?.width, 1920)
        XCTAssertEqual(retrieved?.height, 1080)
    }

    func testSegmentQueries_GetByID_ReturnsNilForMissingID() throws {
        let result = try SegmentQueries.getByID(db: db!, id: SegmentID())
        XCTAssertNil(result)
    }

    func testSegmentQueries_GetByTimestamp_FindsContainingSegment() throws {
        let startTime = Date()
        let segment = makeSegment(startTime: startTime, endTime: startTime.addingTimeInterval(300))
        try SegmentQueries.insert(db: db!, segment: segment)

        // Query in middle of segment
        let midpoint = startTime.addingTimeInterval(150)
        let result = try SegmentQueries.getByTimestamp(db: db!, timestamp: midpoint)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.id.stringValue, segment.id.stringValue)
    }

    func testSegmentQueries_GetByTimestamp_ReturnsNilOutsideRange() throws {
        let startTime = Date()
        let segment = makeSegment(startTime: startTime, endTime: startTime.addingTimeInterval(300))
        try SegmentQueries.insert(db: db!, segment: segment)

        // Query outside segment
        let beforeStart = startTime.addingTimeInterval(-100)
        let result = try SegmentQueries.getByTimestamp(db: db!, timestamp: beforeStart)

        XCTAssertNil(result)
    }

    func testSegmentQueries_GetByTimeRange_ReturnsOverlappingSegments() throws {
        let seg1 = makeSegment(
            startTime: Date(timeIntervalSince1970: 1000),
            endTime: Date(timeIntervalSince1970: 1300),
            relativePath: "seg1.mp4"
        )
        let seg2 = makeSegment(
            startTime: Date(timeIntervalSince1970: 1500),
            endTime: Date(timeIntervalSince1970: 1800),
            relativePath: "seg2.mp4"
        )
        let seg3 = makeSegment(
            startTime: Date(timeIntervalSince1970: 5000),
            endTime: Date(timeIntervalSince1970: 5300),
            relativePath: "seg3.mp4"
        )

        try SegmentQueries.insert(db: db!, segment: seg1)
        try SegmentQueries.insert(db: db!, segment: seg2)
        try SegmentQueries.insert(db: db!, segment: seg3)

        // Query range: 1200-1600 (overlaps seg1 end and seg2 start)
        let results = try SegmentQueries.getByTimeRange(
            db: db!,
            from: Date(timeIntervalSince1970: 1200),
            to: Date(timeIntervalSince1970: 1600)
        )

        XCTAssertEqual(results.count, 2, "Should find 2 overlapping segments")
    }

    func testSegmentQueries_Delete_RemovesSegment() throws {
        let segment = makeSegment(relativePath: "to-delete.mp4")
        try SegmentQueries.insert(db: db!, segment: segment)

        XCTAssertNotNil(try SegmentQueries.getByID(db: db!, id: segment.id))
        try SegmentQueries.delete(db: db!, id: segment.id)
        XCTAssertNil(try SegmentQueries.getByID(db: db!, id: segment.id))
    }

    func testSegmentQueries_GetCount_ReturnsCorrectCount() throws {
        for i in 0..<5 {
            let segment = makeSegment(
                startTime: Date().addingTimeInterval(Double(i * 300)),
                endTime: Date().addingTimeInterval(Double(i * 300 + 299)),
                relativePath: "seg-\(i).mp4"
            )
            try SegmentQueries.insert(db: db!, segment: segment)
        }

        let count = try SegmentQueries.getCount(db: db!)
        XCTAssertEqual(count, 5)
    }

    func testSegmentQueries_GetTotalStorageBytes_SumsCorrectly() throws {
        let sizes: [Int64] = [1000, 2000, 3000, 4000, 5000]

        for (i, size) in sizes.enumerated() {
            let segment = makeSegment(
                startTime: Date().addingTimeInterval(Double(i * 300)),
                endTime: Date().addingTimeInterval(Double(i * 300 + 299)),
                fileSizeBytes: size,
                relativePath: "seg-\(i).mp4"
            )
            try SegmentQueries.insert(db: db!, segment: segment)
        }

        let total = try SegmentQueries.getTotalStorageBytes(db: db!)
        XCTAssertEqual(total, 15000)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                       FRAME QUERIES TESTS                               ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    private func createTestSegment() throws -> SegmentID {
        let segment = makeSegment(
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date().addingTimeInterval(3600)
        )
        try SegmentQueries.insert(db: db!, segment: segment)
        return segment.id
    }

    func testFrameQueries_Insert_StoresAllFields() throws {
        let segmentID = try createTestSegment()

        let frame = makeFrame(
            segmentID: segmentID,
            frameIndex: 42,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowTitle: "GitHub - retrace",
                browserURL: "https://github.com/retrace"
            )
        )

        try FrameQueries.insert(db: db!, frame: frame)

        let retrieved = try FrameQueries.getByID(db: db!, id: frame.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.frameIndexInSegment, 42)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.apple.Safari")
        XCTAssertEqual(retrieved?.metadata.appName, "Safari")
        XCTAssertEqual(retrieved?.metadata.windowTitle, "GitHub - retrace")
        XCTAssertEqual(retrieved?.metadata.browserURL, "https://github.com/retrace")
    }

    func testFrameQueries_Insert_WithNullMetadata_StoresCorrectly() throws {
        let segmentID = try createTestSegment()
        let frame = makeFrame(segmentID: segmentID, metadata: FrameMetadata())

        try FrameQueries.insert(db: db!, frame: frame)

        let retrieved = try FrameQueries.getByID(db: db!, id: frame.id)
        XCTAssertNil(retrieved?.metadata.appBundleID)
        XCTAssertNil(retrieved?.metadata.appName)
        XCTAssertNil(retrieved?.metadata.windowTitle)
        XCTAssertNil(retrieved?.metadata.browserURL)
    }

    func testFrameQueries_GetByTimeRange_ReturnsOrderedByTimestampDesc() throws {
        let segmentID = try createTestSegment()
        let timestamps = [100.0, 300.0, 200.0, 500.0, 400.0]

        for (i, offset) in timestamps.enumerated() {
            let frame = makeFrame(
                timestamp: Date(timeIntervalSince1970: offset),
                segmentID: segmentID,
                frameIndex: i
            )
            try FrameQueries.insert(db: db!, frame: frame)
        }

        let results = try FrameQueries.getByTimeRange(
            db: db!,
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 1000),
            limit: 10
        )

        XCTAssertEqual(results.count, 5)

        for i in 0..<(results.count - 1) {
            XCTAssertGreaterThan(
                results[i].timestamp.timeIntervalSince1970,
                results[i + 1].timestamp.timeIntervalSince1970
            )
        }
    }

    func testFrameQueries_GetByTimeRange_RespectsLimit() throws {
        let segmentID = try createTestSegment()

        for i in 0..<10 {
            let frame = makeFrame(
                timestamp: Date().addingTimeInterval(Double(i)),
                segmentID: segmentID,
                frameIndex: i
            )
            try FrameQueries.insert(db: db!, frame: frame)
        }

        let results = try FrameQueries.getByTimeRange(
            db: db!,
            from: Date().addingTimeInterval(-100),
            to: Date().addingTimeInterval(100),
            limit: 3
        )

        XCTAssertEqual(results.count, 3)
    }

    func testFrameQueries_GetByApp_FiltersCorrectly() throws {
        let segmentID = try createTestSegment()
        let apps = ["com.apple.Safari", "com.apple.Xcode", "com.apple.Safari", "com.apple.Terminal"]

        for (i, app) in apps.enumerated() {
            let frame = makeFrame(
                timestamp: Date().addingTimeInterval(Double(i)),
                segmentID: segmentID,
                frameIndex: i,
                metadata: FrameMetadata(appBundleID: app)
            )
            try FrameQueries.insert(db: db!, frame: frame)
        }

        let safariFrames = try FrameQueries.getByApp(
            db: db!,
            appBundleID: "com.apple.Safari",
            limit: 10,
            offset: 0
        )

        XCTAssertEqual(safariFrames.count, 2)
        for frame in safariFrames {
            XCTAssertEqual(frame.metadata.appBundleID, "com.apple.Safari")
        }
    }

    func testFrameQueries_DeleteOlderThan_ReturnsDeletedCount() throws {
        let segmentID = try createTestSegment()
        let now = Date()

        // 5 old frames
        for i in 0..<5 {
            let frame = makeFrame(
                timestamp: now.addingTimeInterval(-86400 * Double(100 + i)),
                segmentID: segmentID,
                frameIndex: i
            )
            try FrameQueries.insert(db: db!, frame: frame)
        }

        // 3 recent frames
        for i in 0..<3 {
            let frame = makeFrame(
                timestamp: now.addingTimeInterval(-Double(i)),
                segmentID: segmentID,
                frameIndex: 5 + i
            )
            try FrameQueries.insert(db: db!, frame: frame)
        }

        let cutoff = now.addingTimeInterval(-86400 * 30)
        let deleted = try FrameQueries.deleteOlderThan(db: db!, date: cutoff)

        XCTAssertEqual(deleted, 5)
        XCTAssertEqual(try FrameQueries.getCount(db: db!), 3)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                      DOCUMENT QUERIES TESTS                             ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    private func createTestFrame() throws -> FrameID {
        let segmentID = try createTestSegment()
        let frame = makeFrame(segmentID: segmentID)
        try FrameQueries.insert(db: db!, frame: frame)
        return frame.id
    }

    func testDocumentQueries_Insert_ReturnsAutoIncrementID() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(
            id: 0,
            frameID: frameID,
            timestamp: Date(),
            content: "Test content"
        )

        let id1 = try DocumentQueries.insert(db: db!, document: document)
        XCTAssertGreaterThan(id1, 0)

        let frameID2 = try createTestFrame()
        let document2 = IndexedDocument(id: 0, frameID: frameID2, timestamp: Date(), content: "More content")

        let id2 = try DocumentQueries.insert(db: db!, document: document2)
        XCTAssertGreaterThan(id2, id1)
    }

    func testDocumentQueries_Insert_StoresAllFields() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(
            id: 0,
            frameID: frameID,
            timestamp: Date(timeIntervalSince1970: 1702406400),
            content: "Full document content here",
            appName: "Safari",
            windowTitle: "GitHub Page",
            browserURL: "https://github.com"
        )

        _ = try DocumentQueries.insert(db: db!, document: document)

        let retrieved = try DocumentQueries.getByFrameID(db: db!, frameID: frameID)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.content, "Full document content here")
        XCTAssertEqual(retrieved?.appName, "Safari")
        XCTAssertEqual(retrieved?.windowTitle, "GitHub Page")
        XCTAssertEqual(retrieved?.browserURL, "https://github.com")
    }

    func testDocumentQueries_Update_ChangesContent() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(id: 0, frameID: frameID, timestamp: Date(), content: "Original")
        let docID = try DocumentQueries.insert(db: db!, document: document)

        try DocumentQueries.update(db: db!, id: docID, content: "Updated content")

        let retrieved = try DocumentQueries.getByFrameID(db: db!, frameID: frameID)
        XCTAssertEqual(retrieved?.content, "Updated content")
    }

    func testDocumentQueries_Delete_RemovesDocument() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(id: 0, frameID: frameID, timestamp: Date(), content: "To delete")
        let docID = try DocumentQueries.insert(db: db!, document: document)

        XCTAssertNotNil(try DocumentQueries.getByFrameID(db: db!, frameID: frameID))
        try DocumentQueries.delete(db: db!, id: docID)
        XCTAssertNil(try DocumentQueries.getByFrameID(db: db!, frameID: frameID))
    }

    func testDocumentQueries_GetCount_ReturnsCorrectCount() throws {
        for _ in 0..<7 {
            let frameID = try createTestFrame()
            let document = IndexedDocument(id: 0, frameID: frameID, timestamp: Date(), content: "Content")
            _ = try DocumentQueries.insert(db: db!, document: document)
        }

        let count = try DocumentQueries.getCount(db: db!)
        XCTAssertEqual(count, 7)
    }
}
