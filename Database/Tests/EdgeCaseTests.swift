import XCTest
import Foundation
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                            EDGE CASE TESTS                                   ║
// ║                                                                              ║
// ║  • Verify empty database queries return nil/empty (don't crash)              ║
// ║  • Verify null/optional field handling                                       ║
// ║  • Verify large data sets don't cause performance issues                     ║
// ║  • Verify special characters and Unicode in text content                     ║
// ║  • Verify boundary conditions (zero values, max values)                      ║
// ║  • Verify duplicate handling and constraint violations                       ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class EdgeCaseTests: XCTestCase {

    var database: DatabaseManager!
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        database = DatabaseManager()
        try await database.initialize()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         EMPTY DATABASE TESTS                            ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Queries on empty database should return empty/nil, not crash            │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testGetFrame_EmptyDatabase_ReturnsNil() async throws {
        let result = try await database.getFrame(id: FrameID())
        XCTAssertNil(result, "Should return nil for non-existent frame")
    }

    func testGetSegment_EmptyDatabase_ReturnsNil() async throws {
        let result = try await database.getSegment(id: SegmentID())
        XCTAssertNil(result, "Should return nil for non-existent segment")
    }

    func testGetSegmentContainingTimestamp_EmptyDatabase_ReturnsNil() async throws {
        let result = try await database.getSegment(containingTimestamp: Date())
        XCTAssertNil(result, "Should return nil when no segments exist")
    }

    func testGetFrames_EmptyDatabase_ReturnsEmptyArray() async throws {
        let result = try await database.getFrames(
            from: Date().addingTimeInterval(-3600),
            to: Date(),
            limit: 100
        )
        XCTAssertEqual(result.count, 0, "Should return empty array")
    }

    func testGetFramesByApp_EmptyDatabase_ReturnsEmptyArray() async throws {
        let result = try await database.getFrames(
            appBundleID: "com.example.app",
            limit: 100,
            offset: 0
        )
        XCTAssertEqual(result.count, 0, "Should return empty array")
    }

    func testGetFrameCount_EmptyDatabase_ReturnsZero() async throws {
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 0, "Should return 0")
    }

    func testGetTotalStorageBytes_EmptyDatabase_ReturnsZero() async throws {
        let bytes = try await database.getTotalStorageBytes()
        XCTAssertEqual(bytes, 0, "Should return 0")
    }

    func testDeleteFramesOlderThan_EmptyDatabase_ReturnsZero() async throws {
        let deleted = try await database.deleteFrames(olderThan: Date())
        XCTAssertEqual(deleted, 0, "Should return 0 when nothing to delete")
    }

    func testGetStatistics_EmptyDatabase_ReturnsZeroCounts() async throws {
        let stats = try await database.getStatistics()

        XCTAssertEqual(stats.frameCount, 0)
        XCTAssertEqual(stats.segmentCount, 0)
        XCTAssertEqual(stats.documentCount, 0)
        XCTAssertNil(stats.oldestFrameDate)
        XCTAssertNil(stats.newestFrameDate)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         NULL/OPTIONAL HANDLING                          ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Nullable fields should be stored and retrieved correctly                │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testFrame_WithNullMetadata_StoresAndRetrievesCorrectly() async throws {
        // Create segment first
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Create frame with all null optional fields
        let frame = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: nil,
                appName: nil,
                windowTitle: nil,
                browserURL: nil
            )
        )
        try await database.insertFrame(frame)

        // Retrieve and verify nulls are preserved
        let retrieved = try await database.getFrame(id: frame.id)
        XCTAssertNotNil(retrieved)
        XCTAssertNil(retrieved?.metadata.appBundleID)
        XCTAssertNil(retrieved?.metadata.appName)
        XCTAssertNil(retrieved?.metadata.windowTitle)
        XCTAssertNil(retrieved?.metadata.browserURL)
    }

    func testFrame_WithPartialMetadata_StoresAndRetrievesCorrectly() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Only app name, no other metadata
        let frame = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "Example",
                windowTitle: nil,  // Intentionally nil
                browserURL: nil    // Intentionally nil
            )
        )
        try await database.insertFrame(frame)

        let retrieved = try await database.getFrame(id: frame.id)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.example.app")
        XCTAssertEqual(retrieved?.metadata.appName, "Example")
        XCTAssertNil(retrieved?.metadata.windowTitle)
        XCTAssertNil(retrieved?.metadata.browserURL)
    }

    func testDocument_WithNullOptionalFields_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
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
            metadata: .empty
        )
        try await database.insertFrame(frame)

        let document = IndexedDocument(
            id: 0,
            frameID: frame.id,
            timestamp: Date(),
            content: "Test content",
            appName: nil,       // Intentionally nil
            windowTitle: nil,   // Intentionally nil
            browserURL: nil     // Intentionally nil
        )

        let docID = try await database.insertDocument(document)
        XCTAssertGreaterThan(docID, 0)

        let retrieved = try await database.getDocument(frameID: frame.id)
        XCTAssertEqual(retrieved?.content, "Test content")
        XCTAssertNil(retrieved?.appName)
        XCTAssertNil(retrieved?.windowTitle)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         BOUNDARY CONDITIONS                             ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Tests for extreme values, limits, and edge timestamps                   │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testSegment_WithZeroFrameCount_StoresCorrectly() async throws {
        // Edge case: segment with no frames yet
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 0,
            fileSizeBytes: 0,
            relativePath: "empty.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let retrieved = try await database.getSegment(id: segment.id)
        XCTAssertEqual(retrieved?.frameCount, 0)
        XCTAssertEqual(retrieved?.fileSizeBytes, 0)
    }

    func testSegment_WithLargeFileSize_StoresCorrectly() async throws {
        // Edge case: very large file (100GB)
        let largeSize: Int64 = 100 * 1024 * 1024 * 1024

        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 10000,
            fileSizeBytes: largeSize,
            relativePath: "large.mp4",
            width: 3840,
            height: 2160,
            source: .native
        )
        try await database.insertSegment(segment)

        let retrieved = try await database.getSegment(id: segment.id)
        XCTAssertEqual(retrieved?.fileSizeBytes, largeSize)
    }

    func testFrame_WithVeryOldTimestamp_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(timeIntervalSince1970: 0),  // 1970
            endTime: Date(timeIntervalSince1970: 1000),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "old.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let oldDate = Date(timeIntervalSince1970: 500)  // 1970

        let frame = FrameReference(
            id: FrameID(),
            timestamp: oldDate,
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty
        )
        try await database.insertFrame(frame)

        let retrieved = try await database.getFrame(id: frame.id)
        guard let retrieved = retrieved else {
            XCTFail("Failed to retrieve frame")
            return
        }
        XCTAssertEqual(
            retrieved.timestamp.timeIntervalSince1970,
            oldDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testFrame_WithFutureTimestamp_StoresCorrectly() async throws {
        let futureDate = Date().addingTimeInterval(86400 * 365 * 10)  // 10 years from now

        let segment = VideoSegment(
            id: SegmentID(),
            startTime: futureDate,
            endTime: futureDate.addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "future.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let frame = FrameReference(
            id: FrameID(),
            timestamp: futureDate,
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty
        )
        try await database.insertFrame(frame)

        let retrieved = try await database.getFrame(id: frame.id)
        guard let retrieved = retrieved else {
            XCTFail("Failed to retrieve frame")
            return
        }
        XCTAssertEqual(
            retrieved.timestamp.timeIntervalSince1970,
            futureDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testGetFrames_WithZeroLimit_ReturnsEmptyArray() async throws {
        // Set up data
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
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
            metadata: .empty
        )
        try await database.insertFrame(frame)

        // Query with limit 0
        let results = try await database.getFrames(
            from: Date().addingTimeInterval(-3600),
            to: Date().addingTimeInterval(3600),
            limit: 0
        )

        XCTAssertEqual(results.count, 0, "Limit 0 should return empty array")
    }

    func testGetFramesByApp_WithLargeOffset_ReturnsEmptyArray() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
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
            metadata: FrameMetadata(appBundleID: "com.test.app")
        )
        try await database.insertFrame(frame)

        // Query with huge offset
        let results = try await database.getFrames(
            appBundleID: "com.test.app",
            limit: 100,
            offset: 1000000
        )

        XCTAssertEqual(results.count, 0, "Large offset past data should return empty")
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         SPECIAL CHARACTERS                              ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Unicode, emoji, SQL injection attempts, special chars                   │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testFrame_WithUnicodeMetadata_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "unicode.mp4",
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
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "日本語アプリ",  // Japanese
                windowTitle: "Émojis: 😀🎉🚀 and más",  // Mixed
                browserURL: "https://example.com/путь"  // Russian
            )
        )
        try await database.insertFrame(frame)

        let retrieved = try await database.getFrame(id: frame.id)
        XCTAssertEqual(retrieved?.metadata.appName, "日本語アプリ")
        XCTAssertEqual(retrieved?.metadata.windowTitle, "Émojis: 😀🎉🚀 and más")
        XCTAssertEqual(retrieved?.metadata.browserURL, "https://example.com/путь")
    }

    func testDocument_WithSQLInjectionAttempt_SafelyStored() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "injection.mp4",
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
            metadata: .empty
        )
        try await database.insertFrame(frame)

        // Attempt SQL injection in content
        let maliciousContent = "'; DROP TABLE documents; --"
        let document = IndexedDocument(
            id: 0,
            frameID: frame.id,
            timestamp: Date(),
            content: maliciousContent,
            appName: "Robert'); DROP TABLE Students;--"  // Bobby Tables
        )

        let docID = try await database.insertDocument(document)
        XCTAssertGreaterThan(docID, 0, "Insert should succeed despite SQL injection attempt")

        // Verify table still exists and content is stored literally
        let retrieved = try await database.getDocument(frameID: frame.id)
        XCTAssertEqual(retrieved?.content, maliciousContent, "Content should be stored literally, not executed")
    }

    func testFrame_WithQuotesInMetadata_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "quotes.mp4",
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
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "App with 'single' quotes",
                windowTitle: "Window with \"double\" quotes",
                browserURL: nil
            )
        )
        try await database.insertFrame(frame)

        let retrieved = try await database.getFrame(id: frame.id)
        XCTAssertEqual(retrieved?.metadata.appName, "App with 'single' quotes")
        XCTAssertEqual(retrieved?.metadata.windowTitle, "Window with \"double\" quotes")
    }

    func testDocument_WithVeryLongContent_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "long.mp4",
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
            metadata: .empty
        )
        try await database.insertFrame(frame)

        // Create very long content (100KB of text)
        let longContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 4000)

        let document = IndexedDocument(
            id: 0,
            frameID: frame.id,
            timestamp: Date(),
            content: longContent
        )

        let docID = try await database.insertDocument(document)
        XCTAssertGreaterThan(docID, 0)

        let retrieved = try await database.getDocument(frameID: frame.id)
        XCTAssertEqual(retrieved?.content.count, longContent.count)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         TIME RANGE EDGE CASES                           ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testGetSegment_ExactlyAtBoundary_Found() async throws {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(300)

        let segment = VideoSegment(
            id: SegmentID(),
            startTime: startTime,
            endTime: endTime,
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "boundary.mp4"
        ,
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Query at exact start time
        let atStart = try await database.getSegment(containingTimestamp: startTime)
        XCTAssertNotNil(atStart, "Should find segment at exact start time")

        // Query at exact end time
        let atEnd = try await database.getSegment(containingTimestamp: endTime)
        XCTAssertNotNil(atEnd, "Should find segment at exact end time")
    }

    func testGetSegment_JustOutsideBoundary_NotFound() async throws {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(300)

        let segment = VideoSegment(
            id: SegmentID(),
            startTime: startTime,
            endTime: endTime,
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "boundary.mp4"
        ,
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Query 1ms before start
        let beforeStart = try await database.getSegment(
            containingTimestamp: startTime.addingTimeInterval(-0.001)
        )
        XCTAssertNil(beforeStart, "Should not find segment before start time")

        // Query 1ms after end
        let afterEnd = try await database.getSegment(
            containingTimestamp: endTime.addingTimeInterval(0.001)
        )
        XCTAssertNil(afterEnd, "Should not find segment after end time")
    }

    func testGetFrames_InvertedTimeRange_ReturnsEmpty() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
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
            metadata: .empty
        )
        try await database.insertFrame(frame)

        // Query with end before start (inverted range)
        let now = Date()
        let results = try await database.getFrames(
            from: now.addingTimeInterval(3600),  // Future
            to: now.addingTimeInterval(-3600),   // Past (inverted!)
            limit: 100
        )

        XCTAssertEqual(results.count, 0, "Inverted time range should return empty")
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         DUPLICATE HANDLING                              ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testInsertSegment_DuplicateID_ThrowsError() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "original.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        try await database.insertSegment(segment)

        // Try to insert same ID again
        let duplicate = VideoSegment(
            id: segment.id,  // Same ID!
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 20,
            fileSizeBytes: 2048,
            relativePath: "duplicate.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        do {
            try await database.insertSegment(duplicate)
            XCTFail("Should have thrown error for duplicate ID")
        } catch {
            // Expected
        }
    }

    func testInsertFrame_DuplicateID_ThrowsError() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
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
            metadata: .empty
        )
        try await database.insertFrame(frame)

        // Try to insert same ID again
        let duplicate = FrameReference(
            id: frame.id,  // Same ID!
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty
        )

        do {
            try await database.insertFrame(duplicate)
            XCTFail("Should have thrown error for duplicate frame ID")
        } catch {
            // Expected
        }
    }

    func testInsertDocument_DuplicateFrameID_ThrowsError() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
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
            metadata: .empty
        )
        try await database.insertFrame(frame)

        let document1 = IndexedDocument(
            id: 0,
            frameID: frame.id,
            timestamp: Date(),
            content: "First document"
        )
        _ = try await database.insertDocument(document1)

        // Try to insert another document for same frame
        let document2 = IndexedDocument(
            id: 0,
            frameID: frame.id,  // Same frame ID!
            timestamp: Date(),
            content: "Second document"
        )

        do {
            _ = try await database.insertDocument(document2)
            XCTFail("Should have thrown error for duplicate frame_id in documents")
        } catch {
            // Expected - UNIQUE constraint on frame_id
        }
    }
}
