import XCTest
import Foundation
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                      DATABASE MANAGER TESTS                                  ║
// ║                                                                              ║
// ║  • Verify segment CRUD operations (insert, get, delete)                      ║
// ║  • Verify frame CRUD operations (insert, get, query by time/app)             ║
// ║  • Verify document CRUD operations (insert, get, update)                     ║
// ║  • Verify cascade deletes (deleting segment removes frames)                  ║
// ║  • Verify storage calculations (total bytes)                                 ║
// ║  • Verify statistics queries (frame count, oldest/newest dates)              ║
// ║  • Verify time-based queries and deletions                                   ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class DatabaseManagerTests: XCTestCase {

    var database: DatabaseManager!
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        print("[TEST DEBUG] setUp() started")
        // Use unique in-memory database name per test to avoid FTS5 pointer corruption
        // when multiple in-memory databases are created/destroyed in same process
        let uniqueDbPath = "file:memdb_\(UUID().uuidString)?mode=memory&cache=private"
        database = DatabaseManager(databasePath: uniqueDbPath)
        print("[TEST DEBUG] DatabaseManager created with path: \(uniqueDbPath)")
        try await database.initialize()
        print("[TEST DEBUG] Database initialized")

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
        print("[TEST DEBUG] setUp() complete")
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ MIGRATION TEST                                                          │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testActualDatabaseMigration() async throws {
        let dbPath = "~/Library/Application Support/Retrace/retrace.db"
        let db = DatabaseManager(databasePath: dbPath)

        try await db.initialize()
        print("✅ Database migration completed successfully at: \(dbPath)")
        try await db.close()
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ SEGMENT TESTS                                                           │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testInsertAndGetSegment() async throws {
        print("[TEST DEBUG] testInsertAndGetSegment() started")
        // Create a test segment
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300), // 5 minutes
            frameCount: 150,
            fileSizeBytes: 1024 * 1024 * 50, // 50MB
            relativePath: "segments/2024/01/segment-001.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        print("[TEST DEBUG] Segment created")

        // Insert segment
        print("[TEST DEBUG] Inserting segment...")
        try await database.insertSegment(segment)
        print("[TEST DEBUG] Segment inserted")

        // Retrieve segment
        print("[TEST DEBUG] Retrieving segment...")
        let retrieved = try await database.getSegment(id: segment.id)
        print("[TEST DEBUG] Segment retrieved")

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.stringValue, segment.id.stringValue)
        XCTAssertEqual(retrieved?.frameCount, 150)
        XCTAssertEqual(retrieved?.fileSizeBytes, 1024 * 1024 * 50)
        XCTAssertEqual(retrieved?.relativePath, "segments/2024/01/segment-001.mp4")
        print("[TEST DEBUG] testInsertAndGetSegment() complete")
    }

    func testGetSegmentContainingTimestamp() async throws {
        let now = Date()
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: now.addingTimeInterval(-600), // 10 minutes ago
            endTime: now.addingTimeInterval(-300),   // 5 minutes ago
            frameCount: 150,
            fileSizeBytes: 1024 * 1024 * 50,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        try await database.insertSegment(segment)

        // Query for timestamp within the segment
        let timestampInRange = now.addingTimeInterval(-450) // 7.5 minutes ago
        let retrieved = try await database.getSegment(containingTimestamp: timestampInRange)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.stringValue, segment.id.stringValue)

        // Query for timestamp outside the segment
        let timestampOutOfRange = now // Current time
        let shouldBeNil = try await database.getSegment(containingTimestamp: timestampOutOfRange)
        XCTAssertNil(shouldBeNil)
    }

    func testDeleteSegment() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 100,
            fileSizeBytes: 1024 * 1024,
            relativePath: "segments/to-delete.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        try await database.insertSegment(segment)

        // Verify it exists
        var retrieved = try await database.getSegment(id: segment.id)
        XCTAssertNotNil(retrieved)

        // Delete it
        try await database.deleteSegment(id: segment.id)

        // Verify it's gone
        retrieved = try await database.getSegment(id: segment.id)
        XCTAssertNil(retrieved)
    }

    func testGetTotalStorageBytes() async throws {
        let segment1 = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 100,
            fileSizeBytes: 1024 * 1024 * 10, // 10MB
            relativePath: "segments/1.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        let segment2 = VideoSegment(
            id: SegmentID(),
            startTime: Date().addingTimeInterval(300),
            endTime: Date().addingTimeInterval(600),
            frameCount: 100,
            fileSizeBytes: 1024 * 1024 * 20, // 20MB
            relativePath: "segments/2.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        try await database.insertSegment(segment1)
        try await database.insertSegment(segment2)

        let total = try await database.getTotalStorageBytes()
        XCTAssertEqual(total, 1024 * 1024 * 30) // 30MB
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ FRAME TESTS                                                             │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testInsertAndGetFrame() async throws {
        // First, create a segment (frames need a valid segment_id)
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Create a test frame
        let frame = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowTitle: "Retrace - GitHub",
                browserURL: "https://github.com/retrace"
            ),
            source: .native
        )

        // Insert frame
        try await database.insertFrame(frame)

        // Retrieve frame
        let retrieved = try await database.getFrame(id: frame.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.stringValue, frame.id.stringValue)
        XCTAssertEqual(retrieved?.segmentID.stringValue, segment.id.stringValue)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.apple.Safari")
        XCTAssertEqual(retrieved?.metadata.windowTitle, "Retrace - GitHub")
    }

    func testGetFramesByTimeRange() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(600),
            frameCount: 3,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let now = Date()

        // Insert frames at different times
        let frame1 = FrameReference(
            id: FrameID(),
            timestamp: now.addingTimeInterval(-600), // 10 min ago
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(),
            timestamp: now.addingTimeInterval(-300), // 5 min ago
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let frame3 = FrameReference(
            id: FrameID(),
            timestamp: now, // now
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 2,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        try await database.insertFrame(frame1)
        try await database.insertFrame(frame2)
        try await database.insertFrame(frame3)

        // Query for frames in a range
        let startDate = now.addingTimeInterval(-400) // 6.7 min ago
        let endDate = now.addingTimeInterval(100)     // future
        let frames = try await database.getFrames(from: startDate, to: endDate, limit: 10)

        // Should get frame2 and frame3
        XCTAssertEqual(frames.count, 2)
    }

    func testGetFramesByApp() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(600),
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let frame1 = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(appBundleID: "com.apple.Safari"),
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: FrameMetadata(appBundleID: "com.apple.Xcode"),
            source: .native
        )

        try await database.insertFrame(frame1)
        try await database.insertFrame(frame2)

        let safariFrames = try await database.getFrames(
            appBundleID: "com.apple.Safari",
            limit: 10,
            offset: 0
        )

        XCTAssertEqual(safariFrames.count, 1)
        XCTAssertEqual(safariFrames.first?.metadata.appBundleID, "com.apple.Safari")
    }

    func testDeleteOldFrames() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(600),
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let now = Date()

        let oldFrame = FrameReference(
            id: FrameID(),
            timestamp: now.addingTimeInterval(-86400 * 100), // 100 days ago
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let recentFrame = FrameReference(
            id: FrameID(),
            timestamp: now,
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        try await database.insertFrame(oldFrame)
        try await database.insertFrame(recentFrame)

        // Delete frames older than 30 days
        let cutoffDate = now.addingTimeInterval(-86400 * 30)
        let deletedCount = try await database.deleteFrames(olderThan: cutoffDate)

        XCTAssertEqual(deletedCount, 1)

        // Verify only recent frame remains
        let remainingCount = try await database.getFrameCount()
        XCTAssertEqual(remainingCount, 1)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ DOCUMENT TESTS                                                          │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testInsertAndGetDocument() async throws {
        // Create segment and frame
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let frame = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        try await database.insertFrame(frame)

        // Create document
        let document = IndexedDocument(
            id: 0, // Will be auto-generated
            frameID: frame.id,
            timestamp: Date(),
            content: "This is test content from a screen capture",
            appName: "Safari",
            windowTitle: "Test Page"
        )

        // Insert document
        let documentID = try await database.insertDocument(document)
        XCTAssertGreaterThan(documentID, 0)

        // Retrieve document
        let retrieved = try await database.getDocument(frameID: frame.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.content, "This is test content from a screen capture")
        XCTAssertEqual(retrieved?.appName, "Safari")
    }

    func testUpdateDocument() async throws {
        // Create segment and frame
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let frame = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        try await database.insertFrame(frame)

        let document = IndexedDocument(
            id: 0,
            frameID: frame.id,
            timestamp: Date(),
            content: "Original content",
            appName: "Test"
        )

        let documentID = try await database.insertDocument(document)

        // Update the document
        try await database.updateDocument(id: documentID, content: "Updated content")

        // Retrieve and verify
        let retrieved = try await database.getDocument(frameID: frame.id)
        XCTAssertEqual(retrieved?.content, "Updated content")
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ STATISTICS TESTS                                                        │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testGetStatistics() async throws {
        // Create some test data
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 2,
            fileSizeBytes: 1024 * 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let frame1 = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(),
            timestamp: Date().addingTimeInterval(100),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        try await database.insertFrame(frame1)
        try await database.insertFrame(frame2)

        let document = IndexedDocument(
            id: 0,
            frameID: frame1.id,
            timestamp: Date(),
            content: "Test document"
        )
        _ = try await database.insertDocument(document)

        // Get statistics
        let stats = try await database.getStatistics()

        XCTAssertEqual(stats.frameCount, 2)
        XCTAssertEqual(stats.segmentCount, 1)
        XCTAssertEqual(stats.documentCount, 1)
        XCTAssertNotNil(stats.oldestFrameDate)
        XCTAssertNotNil(stats.newestFrameDate)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ CASCADE DELETE TESTS                                                    │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testCascadeDeleteSegmentRemovesFrames() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let frame = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        try await database.insertFrame(frame)

        // Verify frame exists
        var retrievedFrame = try await database.getFrame(id: frame.id)
        XCTAssertNotNil(retrievedFrame)

        // Delete segment (should cascade to frame)
        try await database.deleteSegment(id: segment.id)

        // Verify frame is gone
        retrievedFrame = try await database.getFrame(id: frame.id)
        XCTAssertNil(retrievedFrame)
    }
}
