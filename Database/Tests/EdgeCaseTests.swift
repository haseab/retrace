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
        let result = try await database.getFrame(id: FrameID(value: 999))
        XCTAssertNil(result, "Should return nil for non-existent frame")
    }

    func testGetSegment_EmptyDatabase_ReturnsNil() async throws {
        let result = try await database.getSegment(id: 999)
        XCTAssertNil(result, "Should return nil for non-existent app segment")
    }

    func testGetSegmentContainingTimestamp_EmptyDatabase_ReturnsNil() async throws {
        let result = try await database.getVideoSegment(containingTimestamp: Date())
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
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Create frame with all null optional fields
        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: nil,
                appName: nil,
                windowName: nil,
                browserURL: nil
            ),
            source: .native
        )
        try await database.insertFrame(frame)

        // Retrieve and verify nulls are preserved
        let retrieved = try await database.getFrame(id: frame.id)
        XCTAssertNotNil(retrieved)
        XCTAssertNil(retrieved?.metadata.appBundleID)
        XCTAssertNil(retrieved?.metadata.appName)
        XCTAssertNil(retrieved?.metadata.windowName)
        XCTAssertNil(retrieved?.metadata.browserURL)
    }

    func testFrame_WithPartialMetadata_StoresAndRetrievesCorrectly() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.example.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Only app name, no other metadata
        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "Example",
                windowName: nil,  // Intentionally nil
                browserURL: nil    // Intentionally nil
            ),
            source: .native
        )
        try await database.insertFrame(frame)

        let retrieved = try await database.getFrame(id: frame.id)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.example.app")
        XCTAssertEqual(retrieved?.metadata.appName, "Example")
        XCTAssertNil(retrieved?.metadata.windowName)
        XCTAssertNil(retrieved?.metadata.browserURL)
    }

    func testDocument_WithNullOptionalFields_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

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
            videoID: segment.id,
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
            content: "Test content",
            appName: nil,       // Intentionally nil
            windowName: nil,   // Intentionally nil
            browserURL: nil     // Intentionally nil
        )

        let docID = try await database.insertDocument(document)
        XCTAssertGreaterThan(docID, 0)

        let retrieved = try await database.getDocument(frameID: frame.id)
        XCTAssertEqual(retrieved?.content, "Test content")
        XCTAssertNil(retrieved?.appName)
        XCTAssertNil(retrieved?.windowName)
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
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 0,
            fileSizeBytes: 0,
            relativePath: "empty.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

        let retrieved = try await database.getVideoSegment(id: segment.id)
        XCTAssertEqual(retrieved?.frameCount, 0)
        XCTAssertEqual(retrieved?.fileSizeBytes, 0)
    }

    func testSegment_WithLargeFileSize_StoresCorrectly() async throws {
        // Edge case: very large file (100GB)
        let largeSize: Int64 = 100 * 1024 * 1024 * 1024

        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 10000,
            fileSizeBytes: largeSize,
            relativePath: "large.mp4",
            width: 3840,
            height: 2160,
            source: .native
        )
        try await database.insertVideoSegment(segment)

        let retrieved = try await database.getVideoSegment(id: segment.id)
        XCTAssertEqual(retrieved?.fileSizeBytes, largeSize)
    }

    func testFrame_WithVeryOldTimestamp_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(timeIntervalSince1970: 0),  // 1970
            endTime: Date(timeIntervalSince1970: 1000),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "old.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

        let oldDate = Date(timeIntervalSince1970: 500)  // 1970
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: oldDate,
            endDate: oldDate.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: oldDate,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
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
            id: VideoSegmentID(value: 0),
            startTime: futureDate,
            endTime: futureDate.addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "future.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: futureDate,
            endDate: futureDate.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: futureDate,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
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
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

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
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
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
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

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
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(appBundleID: "com.test.app"),
            source: .native
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
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "unicode.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.example.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: "Émojis: 😀🎉🚀 and más",
            browserUrl: "https://example.com/путь",
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "日本語アプリ",  // Japanese
                windowName: "Émojis: 😀🎉🚀 and más",  // Mixed
                browserURL: "https://example.com/путь"  // Russian
            ),
            source: .native
        )
        try await database.insertFrame(frame)

        let retrieved = try await database.getFrame(id: frame.id)
        XCTAssertEqual(retrieved?.metadata.appName, "日本語アプリ")
        XCTAssertEqual(retrieved?.metadata.windowName, "Émojis: 😀🎉🚀 and más")
        XCTAssertEqual(retrieved?.metadata.browserURL, "https://example.com/путь")
    }

    func testDocument_WithSQLInjectionAttempt_SafelyStored() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "injection.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

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
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
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
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "quotes.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.example.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: "Window with \"double\" quotes",
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "App with 'single' quotes",
                windowName: "Window with \"double\" quotes",
                browserURL: nil
            ),
            source: .native
        )
        try await database.insertFrame(frame)

        let retrieved = try await database.getFrame(id: frame.id)
        XCTAssertEqual(retrieved?.metadata.appName, "App with 'single' quotes")
        XCTAssertEqual(retrieved?.metadata.windowName, "Window with \"double\" quotes")
    }

    func testDocument_WithVeryLongContent_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "long.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

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
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
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
            id: VideoSegmentID(value: 0),
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
        try await database.insertVideoSegment(segment)

        // Query at exact start time
        let atStart = try await database.getVideoSegment(containingTimestamp: startTime)
        XCTAssertNotNil(atStart, "Should find segment at exact start time")

        // Query at exact end time
        let atEnd = try await database.getVideoSegment(containingTimestamp: endTime)
        XCTAssertNotNil(atEnd, "Should find segment at exact end time")
    }

    func testGetSegment_JustOutsideBoundary_NotFound() async throws {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(300)

        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
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
        try await database.insertVideoSegment(segment)

        // Query 1ms before start
        let beforeStart = try await database.getVideoSegment(
            containingTimestamp: startTime.addingTimeInterval(-0.001)
        )
        XCTAssertNil(beforeStart, "Should not find segment before start time")

        // Query 1ms after end
        let afterEnd = try await database.getVideoSegment(
            containingTimestamp: endTime.addingTimeInterval(0.001)
        )
        XCTAssertNil(afterEnd, "Should not find segment after end time")
    }

    func testGetFrames_InvertedTimeRange_ReturnsEmpty() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

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
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
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
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "original.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        try await database.insertVideoSegment(segment)

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
            try await database.insertVideoSegment(duplicate)
            XCTFail("Should have thrown error for duplicate ID")
        } catch {
            // Expected
        }
    }

    func testInsertFrame_DuplicateID_ThrowsError() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

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
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        try await database.insertFrame(frame)

        // Try to insert same ID again
        let duplicate = FrameReference(
            id: frame.id,  // Same ID!
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
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
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(segment)

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
            videoID: segment.id,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
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
