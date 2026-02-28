import XCTest
import Foundation
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                      DATABASE MANAGER TESTS                                  ║
// ║                                                                              ║
// ║  • Verify segment CRUD operations (insert, get, delete)                      ║
// ║  • Verify frame CRUD operations (insert, get, query by time/app)             ║
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
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceDatabaseMigrationTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
        }

        let dbPath = testRoot.appendingPathComponent("retrace.db").path
        let db = DatabaseManager(databasePath: dbPath)

        try await db.initialize()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
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
            id: VideoSegmentID(value: 0),
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
        let insertedSegmentID = try await database.insertVideoSegment(segment)
        print("[TEST DEBUG] Segment inserted")

        // Retrieve segment
        print("[TEST DEBUG] Retrieving segment...")
        let retrieved = try await database.getVideoSegment(id: VideoSegmentID(value: insertedSegmentID))
        print("[TEST DEBUG] Segment retrieved")

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.value, insertedSegmentID)
        XCTAssertEqual(retrieved?.frameCount, 150)
        XCTAssertEqual(retrieved?.fileSizeBytes, 1024 * 1024 * 50)
        XCTAssertEqual(retrieved?.relativePath, "segments/2024/01/segment-001.mp4")
        print("[TEST DEBUG] testInsertAndGetSegment() complete")
    }

    func testGetSegmentContainingTimestamp() async throws {
        let now = Date()
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: now.addingTimeInterval(-600), // 10 minutes ago
            endTime: now.addingTimeInterval(-300),   // 5 minutes ago
            frameCount: 150,
            fileSizeBytes: 1024 * 1024 * 50,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        let insertedSegmentID = try await database.insertVideoSegment(segment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: now.addingTimeInterval(-600),
            endDate: now.addingTimeInterval(-300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // getVideoSegment(containingTimestamp:) resolves via exact frame.createdAt match.
        let timestampInRange = now.addingTimeInterval(-450)
        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestampInRange,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: insertedSegmentID),
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        _ = try await database.insertFrame(frame)

        // Query for timestamp within the segment
        let retrieved = try await database.getVideoSegment(containingTimestamp: timestampInRange)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.value, insertedSegmentID)

        // Query for timestamp outside the segment
        let timestampOutOfRange = now.addingTimeInterval(-449)
        let shouldBeNil = try await database.getVideoSegment(containingTimestamp: timestampOutOfRange)
        XCTAssertNil(shouldBeNil)
    }

    func testDeleteSegment() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 100,
            fileSizeBytes: 1024 * 1024,
            relativePath: "segments/to-delete.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        let insertedSegmentID = try await database.insertVideoSegment(segment)

        // Verify it exists
        var retrieved = try await database.getVideoSegment(id: VideoSegmentID(value: insertedSegmentID))
        XCTAssertNotNil(retrieved)

        // Delete it
        try await database.deleteVideoSegment(id: VideoSegmentID(value: insertedSegmentID))

        // Verify it's gone
        retrieved = try await database.getVideoSegment(id: VideoSegmentID(value: insertedSegmentID))
        XCTAssertNil(retrieved)
    }

    func testGetTotalStorageBytes() async throws {
        let segment1 = VideoSegment(
            id: VideoSegmentID(value: 0),
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
            id: VideoSegmentID(value: 0),
            startTime: Date().addingTimeInterval(300),
            endTime: Date().addingTimeInterval(600),
            frameCount: 100,
            fileSizeBytes: 1024 * 1024 * 20, // 20MB
            relativePath: "segments/2.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        try await database.insertVideoSegment(segment1)
        try await database.insertVideoSegment(segment2)

        let total = try await database.getTotalStorageBytes()
        XCTAssertEqual(total, 1024 * 1024 * 30) // 30MB
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ FRAME TESTS                                                             │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testInsertAndGetFrame() async throws {
        let timestamp = Date()

        // First, create a video segment (frames need a valid segment_id)
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let insertedVideoID = try await database.insertVideoSegment(videoSegment)

        // Create app segment
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: "Retrace - GitHub",
            browserUrl: "https://github.com/retrace",
            type: 0
        )

        // Create a test frame
        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: insertedVideoID),
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Retrace - GitHub",
                browserURL: "https://github.com/retrace"
            ),
            source: .native
        )

        // Insert frame
        let insertedFrameID = try await database.insertFrame(frame)

        // Retrieve frame
        let retrieved = try await database.getFrame(id: FrameID(value: insertedFrameID))

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.value, insertedFrameID)
        XCTAssertEqual(retrieved?.segmentID.value, appSegmentID)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.apple.Safari")
        XCTAssertEqual(retrieved?.metadata.windowName, "Retrace - GitHub")
    }

    func testGetFramesByTimeRange() async throws {
        let startTime = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: startTime,
            endTime: startTime.addingTimeInterval(600),
            frameCount: 3,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: startTime,
            endDate: startTime.addingTimeInterval(600),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let now = Date()

        // Insert frames at different times
        let frame1 = FrameReference(
            id: FrameID(value: 0),
            timestamp: now.addingTimeInterval(-600), // 10 min ago
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoSegment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(value: 0),
            timestamp: now.addingTimeInterval(-300), // 5 min ago
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoSegment.id,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let frame3 = FrameReference(
            id: FrameID(value: 0),
            timestamp: now, // now
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoSegment.id,
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
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(600),
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        _ = try await database.insertVideoSegment(segment)

        let timestamp = Date()

        // Create Safari app segment
        let safariSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Create Xcode app segment
        let xcodeSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Xcode",
            startDate: timestamp.addingTimeInterval(300),
            endDate: timestamp.addingTimeInterval(600),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame1 = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: safariSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(appBundleID: "com.apple.Safari"),
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp.addingTimeInterval(300),
            segmentID: AppSegmentID(value: xcodeSegmentID),
            videoID: segment.id,
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
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(600),
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        _ = try await database.insertVideoSegment(segment)

        let now = Date()

        // Create app segment for old frame
        let oldAppSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: now.addingTimeInterval(-86400 * 100),
            endDate: now.addingTimeInterval(-86400 * 100 + 300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Create app segment for recent frame
        let recentAppSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: now,
            endDate: now.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let oldFrame = FrameReference(
            id: FrameID(value: 0),
            timestamp: now.addingTimeInterval(-86400 * 100), // 100 days ago
            segmentID: AppSegmentID(value: oldAppSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let recentFrame = FrameReference(
            id: FrameID(value: 0),
            timestamp: now,
            segmentID: AppSegmentID(value: recentAppSegmentID),
            videoID: segment.id,
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
    // │ STATISTICS TESTS                                                        │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testGetStatistics() async throws {
        // Create some test data
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 2,
            fileSizeBytes: 1024 * 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        _ = try await database.insertVideoSegment(segment)

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame1 = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp.addingTimeInterval(100),
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        try await database.insertFrame(frame1)
        try await database.insertFrame(frame2)

        // Get statistics
        let stats = try await database.getStatistics()

        XCTAssertEqual(stats.frameCount, 2)
        XCTAssertEqual(stats.segmentCount, 1)
        XCTAssertNotNil(stats.oldestFrameDate)
        XCTAssertNotNil(stats.newestFrameDate)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ CASCADE DELETE TESTS                                                    │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testCascadeDeleteSegmentRemovesFrames() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let insertedVideoID = try await database.insertVideoSegment(segment)

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: insertedVideoID),
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        let insertedFrameID = try await database.insertFrame(frame)

        // Verify frame exists
        var retrievedFrame = try await database.getFrame(id: FrameID(value: insertedFrameID))
        XCTAssertNotNil(retrievedFrame)
        XCTAssertEqual(retrievedFrame?.videoID.value, insertedVideoID)

        // Deleting a video segment should preserve frame rows and null out frame.videoId.
        try await database.deleteVideoSegment(id: VideoSegmentID(value: insertedVideoID))

        // Verify frame still exists but is no longer linked to a video.
        retrievedFrame = try await database.getFrame(id: FrameID(value: insertedFrameID))
        XCTAssertNotNil(retrievedFrame)
        XCTAssertEqual(retrievedFrame?.videoID.value, 0)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ SEGMENT COMMENT TESTS                                                   │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testSegmentComment_CanLinkToMultipleSegments() async throws {
        let segmentA = try await insertTestAppSegment(bundleID: "com.test.a")
        let segmentB = try await insertTestAppSegment(bundleID: "com.test.b")

        let comment = try await database.createSegmentComment(
            body: "Investigation notes",
            author: "Test User",
            attachments: []
        )

        try await database.addCommentToSegment(segmentId: segmentA, commentId: comment.id)
        try await database.addCommentToSegment(segmentId: segmentB, commentId: comment.id)

        let commentsForA = try await database.getCommentsForSegment(segmentId: segmentA)
        let commentsForB = try await database.getCommentsForSegment(segmentId: segmentB)
        let linkedSegmentCount = try await database.getSegmentCountForComment(commentId: comment.id)

        XCTAssertEqual(commentsForA.count, 1)
        XCTAssertEqual(commentsForB.count, 1)
        XCTAssertEqual(commentsForA.first?.id, comment.id)
        XCTAssertEqual(commentsForB.first?.id, comment.id)
        XCTAssertEqual(linkedSegmentCount, 2)
    }

    func testSegmentComment_PersistsFrameAnchor() async throws {
        let timestamp = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(60),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/comment-anchor.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = try await database.insertVideoSegment(videoSegment)

        let segmentID = try await database.insertSegment(
            bundleID: "com.test.anchor",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(30),
            windowName: "Anchor Window",
            browserUrl: nil,
            type: 0
        )
        let segment = SegmentID(value: segmentID)

        let insertedFrameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: segmentID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: 0,
                encodingStatus: .success,
                metadata: .empty,
                source: .native
            )
        )
        let frameID = FrameID(value: insertedFrameID)

        let comment = try await database.createSegmentComment(
            body: "Anchored to frame",
            author: "Test User",
            attachments: [],
            frameID: frameID
        )
        try await database.addCommentToSegment(segmentId: segment, commentId: comment.id)

        let comments = try await database.getCommentsForSegment(segmentId: segment)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.frameID?.value, insertedFrameID)
    }

    func testSegmentComment_FallbackNavigationResolvers() async throws {
        let timestamp = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(120),
            frameCount: 4,
            fileSizeBytes: 2048,
            relativePath: "segments/comment-fallback.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = try await database.insertVideoSegment(videoSegment)

        let segmentAID = try await database.insertSegment(
            bundleID: "com.test.fallback.a",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(30),
            windowName: "Fallback A",
            browserUrl: nil,
            type: 0
        )
        let segmentBID = try await database.insertSegment(
            bundleID: "com.test.fallback.b",
            startDate: timestamp.addingTimeInterval(31),
            endDate: timestamp.addingTimeInterval(60),
            windowName: "Fallback B",
            browserUrl: nil,
            type: 0
        )
        let segmentA = SegmentID(value: segmentAID)
        let segmentB = SegmentID(value: segmentBID)

        let firstFrameInA = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp.addingTimeInterval(1),
                segmentID: AppSegmentID(value: segmentAID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: 0,
                encodingStatus: .success,
                metadata: .empty,
                source: .native
            )
        )
        _ = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp.addingTimeInterval(2),
                segmentID: AppSegmentID(value: segmentAID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: 1,
                encodingStatus: .success,
                metadata: .empty,
                source: .native
            )
        )
        _ = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp.addingTimeInterval(35),
                segmentID: AppSegmentID(value: segmentBID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: 0,
                encodingStatus: .success,
                metadata: .empty,
                source: .native
            )
        )

        let comment = try await database.createSegmentComment(
            body: "No frame anchor; fallback should use first frame in linked segment",
            author: "Test User",
            attachments: [],
            frameID: nil
        )
        try await database.addCommentToSegment(segmentId: segmentA, commentId: comment.id)
        try await database.addCommentToSegment(segmentId: segmentB, commentId: comment.id)

        let resolvedSegment = try await database.getFirstLinkedSegmentForComment(commentId: comment.id)
        XCTAssertEqual(resolvedSegment, segmentA)

        let resolvedFrame = try await database.getFirstFrameForSegment(segmentId: segmentA)
        XCTAssertEqual(resolvedFrame?.value, firstFrameInA)
    }

    func testSegmentComment_SearchReturnsMatches() async throws {
        let matching = try await database.createSegmentComment(
            body: "Investigate crash in sidebar panel",
            author: "Test User",
            attachments: []
        )
        _ = try await database.createSegmentComment(
            body: "Misc unrelated note",
            author: "Test User",
            attachments: []
        )

        let results = try await database.searchSegmentComments(
            query: "crash side",
            limit: 20
        )

        XCTAssertTrue(results.contains(where: { $0.id == matching.id }))
        XCTAssertFalse(results.contains(where: { $0.body == "Misc unrelated note" }))
    }

    func testSegmentComment_SearchHonorsLimitCap() async throws {
        for index in 0..<15 {
            _ = try await database.createSegmentComment(
                body: "Cap limit phrase \(index)",
                author: "Test User",
                attachments: []
            )
        }

        let results = try await database.searchSegmentComments(
            query: "cap limit",
            limit: 5
        )

        XCTAssertEqual(results.count, 5)
    }

    func testSegmentComment_SearchSupportsOffsetPagination() async throws {
        for index in 0..<15 {
            _ = try await database.createSegmentComment(
                body: "Paged phrase \(index)",
                author: "Test User",
                attachments: []
            )
        }

        let firstPage = try await database.searchSegmentComments(
            query: "paged phrase",
            limit: 10,
            offset: 0
        )
        let secondPage = try await database.searchSegmentComments(
            query: "paged phrase",
            limit: 10,
            offset: 10
        )

        XCTAssertEqual(firstPage.count, 10)
        XCTAssertEqual(secondPage.count, 5)
        XCTAssertTrue(Set(firstPage.map(\.id)).isDisjoint(with: Set(secondPage.map(\.id))))
    }

    func testSegmentComment_DuplicateLinkIsIgnored() async throws {
        let segment = try await insertTestAppSegment(bundleID: "com.test.duplicate")
        let comment = try await database.createSegmentComment(
            body: "Same link twice",
            author: "Test User",
            attachments: []
        )

        try await database.addCommentToSegment(segmentId: segment, commentId: comment.id)
        try await database.addCommentToSegment(segmentId: segment, commentId: comment.id)

        let linkedSegmentCount = try await database.getSegmentCountForComment(commentId: comment.id)
        XCTAssertEqual(linkedSegmentCount, 1)
    }

    func testDeleteSegment_RemovesOnlyThatSegmentLink_ForSharedComment() async throws {
        let segmentA = try await insertTestAppSegment(bundleID: "com.test.shared.a")
        let segmentB = try await insertTestAppSegment(bundleID: "com.test.shared.b")

        let comment = try await database.createSegmentComment(
            body: "Shared across segments",
            author: "Test User",
            attachments: []
        )

        try await database.addCommentToSegment(segmentId: segmentA, commentId: comment.id)
        try await database.addCommentToSegment(segmentId: segmentB, commentId: comment.id)

        try await database.deleteSegment(id: segmentA.value)

        let linkedSegmentCount = try await database.getSegmentCountForComment(commentId: comment.id)
        let commentsForB = try await database.getCommentsForSegment(segmentId: segmentB)

        XCTAssertEqual(linkedSegmentCount, 1)
        XCTAssertEqual(commentsForB.count, 1)
        XCTAssertEqual(commentsForB.first?.id, comment.id)
    }

    func testRemoveCommentFromLastSegment_DeletesOrphanComment() async throws {
        let segmentA = try await insertTestAppSegment(bundleID: "com.test.orphan.a")

        let comment = try await database.createSegmentComment(
            body: "Will become orphan",
            author: "Test User",
            attachments: []
        )
        try await database.addCommentToSegment(segmentId: segmentA, commentId: comment.id)

        try await database.removeCommentFromSegment(segmentId: segmentA, commentId: comment.id)

        let linkedSegmentCount = try await database.getSegmentCountForComment(commentId: comment.id)
        XCTAssertEqual(linkedSegmentCount, 0)

        let segmentB = try await insertTestAppSegment(bundleID: "com.test.orphan.b")
        do {
            try await database.addCommentToSegment(segmentId: segmentB, commentId: comment.id)
            XCTFail("Expected linking an orphan-deleted comment to fail")
        } catch {
            // Expected: FK violation because orphan cleanup deleted the comment row.
        }
    }

    func testDeleteSegment_DeletesOrphanCommentAttachments() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceCommentAttachmentTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let attachmentURL = tempDir.appendingPathComponent("note.txt")
        try Data("attachment-body".utf8).write(to: attachmentURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))

        let segment = try await insertTestAppSegment(bundleID: "com.test.attachment")
        let comment = try await database.createSegmentComment(
            body: "Has file",
            author: "Test User",
            attachments: [
                SegmentCommentAttachment(
                    filePath: attachmentURL.path,
                    fileName: "note.txt",
                    mimeType: "text/plain",
                    sizeBytes: 15
                )
            ]
        )
        try await database.addCommentToSegment(segmentId: segment, commentId: comment.id)

        try await database.deleteSegment(id: segment.value)

        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))

        let anotherSegment = try await insertTestAppSegment(bundleID: "com.test.attachment.b")
        do {
            try await database.addCommentToSegment(segmentId: anotherSegment, commentId: comment.id)
            XCTFail("Expected deleted orphan comment to be unavailable for relinking")
        } catch {
            // Expected.
        }
    }

    func testSegmentComment_GetSegmentCommentCountsMap() async throws {
        let segmentA = try await insertTestAppSegment(bundleID: "com.test.counts.a")
        let segmentB = try await insertTestAppSegment(bundleID: "com.test.counts.b")

        let commentA = try await database.createSegmentComment(
            body: "A",
            author: "Test User",
            attachments: []
        )
        let commentB = try await database.createSegmentComment(
            body: "B",
            author: "Test User",
            attachments: []
        )

        try await database.addCommentToSegment(segmentId: segmentA, commentId: commentA.id)
        try await database.addCommentToSegment(segmentId: segmentA, commentId: commentB.id)
        try await database.addCommentToSegment(segmentId: segmentB, commentId: commentB.id)

        let map = try await database.getSegmentCommentCountsMap()

        XCTAssertEqual(map[segmentA.value], 2)
        XCTAssertEqual(map[segmentB.value], 1)
    }

    // MARK: - Helpers

    private func insertTestAppSegment(bundleID: String) async throws -> SegmentID {
        let start = Date()
        let id = try await database.insertSegment(
            bundleID: bundleID,
            startDate: start,
            endDate: start.addingTimeInterval(30),
            windowName: "Test Window",
            browserUrl: nil,
            type: 0
        )
        return SegmentID(value: id)
    }
}
