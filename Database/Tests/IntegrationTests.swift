import XCTest
import Foundation
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                          INTEGRATION TESTS                                   ║
// ║                                                                              ║
// ║  • Verify full capture → OCR → index → search workflow                       ║
// ║  • Verify multi-frame scenarios with time-based queries                      ║
// ║  • Verify data consistency across DatabaseManager and FTSManager             ║
// ║  • Verify realistic user scenarios (search recent content, etc.)             ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class IntegrationTests: XCTestCase {

    var database: DatabaseManager!
    var ftsManager: FTSManager!
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        // Use one shared in-memory DB for both managers.
        let sharedPath = "file:integration_tests_\(UUID().uuidString)?mode=memory&cache=shared"
        database = DatabaseManager(databasePath: sharedPath)
        ftsManager = FTSManager(databasePath: sharedPath)
        try await database.initialize()
        try await ftsManager.initialize()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    override func tearDown() async throws {
        try await ftsManager.close()
        try await database.close()
        database = nil
        ftsManager = nil
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                    CAPTURE → SEARCH FLOW                                ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Simulates: Screen capture → OCR → Index → Search                        │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testFullCaptureToSearchFlow() async throws {
        // STEP 1: Simulate capture - create video segment
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 10,
            fileSizeBytes: 5 * 1024 * 1024,
            relativePath: "segments/2024/01/capture-001.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // STEP 2: Simulate frame capture with app metadata
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
                windowTitle: "Retrace - Screen Recording App",
                browserURL: "https://github.com/retrace/app"
            )
        )
        try await database.insertFrame(frame)

        // STEP 3: Simulate OCR processing - index extracted text
        let document = IndexedDocument(
            id: 0,
            frameID: frame.id,
            timestamp: frame.timestamp,
            content: "Retrace is a powerful screen recording application that captures your screen and makes it searchable. Built for macOS with privacy in mind.",
            appName: frame.metadata.appName,
            windowTitle: frame.metadata.windowTitle,
            browserURL: frame.metadata.browserURL
        )
        let docID = try await database.insertDocument(document)
        XCTAssertGreaterThan(docID, 0, "Document should be indexed")

        // STEP 4: User searches for content they saw
        let searchResults = try await ftsManager.search(
            query: "screen recording",
            limit: 10,
            offset: 0
        )

        // VERIFY: Search finds the captured content
        XCTAssertEqual(searchResults.count, 1, "Should find one result")
        XCTAssertEqual(searchResults[0].frameID, frame.id, "Result should reference correct frame")
        XCTAssertEqual(searchResults[0].appName, "Safari", "Should have correct app name")
        XCTAssertTrue(searchResults[0].snippet.lowercased().contains("screen"), "Snippet should contain match")
    }

    func testSearchWithDateFilter_FindsOnlyRecentContent() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date().addingTimeInterval(-86400 * 30),  // 30 days ago
            endTime: Date(),
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Old frame (30 days ago)
        let oldFrame = FrameReference(
            id: FrameID(),
            timestamp: Date().addingTimeInterval(-86400 * 30),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty
        )
        try await database.insertFrame(oldFrame)

        let oldDoc = IndexedDocument(
            id: 0,
            frameID: oldFrame.id,
            timestamp: oldFrame.timestamp,
            content: "Meeting notes from last month"
        )
        _ = try await database.insertDocument(oldDoc)

        // Recent frame (today)
        let recentFrame = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty
        )
        try await database.insertFrame(recentFrame)

        let recentDoc = IndexedDocument(
            id: 0,
            frameID: recentFrame.id,
            timestamp: recentFrame.timestamp,
            content: "Meeting notes from today"
        )
        _ = try await database.insertDocument(recentDoc)

        // Search with date filter (last 7 days only)
        let filters = SearchFilters(
            startDate: Date().addingTimeInterval(-86400 * 7),
            endDate: Date()
        )

        let results = try await ftsManager.search(
            query: "meeting notes",
            filters: filters,
            limit: 10,
            offset: 0
        )

        XCTAssertEqual(results.count, 1, "Should only find recent content")
        XCTAssertEqual(results[0].frameID, recentFrame.id, "Should be the recent frame")
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                    MULTI-APP SESSION FLOW                               ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testMultipleAppsInSameSegment_SearchByApp() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(600),
            frameCount: 3,
            fileSizeBytes: 1024,
            relativePath: "multi-app.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Frame 1: Safari
        let safariFrame = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowTitle: "GitHub"
            )
        )
        try await database.insertFrame(safariFrame)
        _ = try await database.insertDocument(IndexedDocument(
            id: 0,
            frameID: safariFrame.id,
            timestamp: safariFrame.timestamp,
            content: "GitHub repository code review",
            appName: "Safari"
        ))

        // Frame 2: Xcode
        let xcodeFrame = FrameReference(
            id: FrameID(),
            timestamp: Date().addingTimeInterval(60),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.apple.dt.Xcode",
                appName: "Xcode",
                windowTitle: "DatabaseManager.swift"
            )
        )
        try await database.insertFrame(xcodeFrame)
        _ = try await database.insertDocument(IndexedDocument(
            id: 0,
            frameID: xcodeFrame.id,
            timestamp: xcodeFrame.timestamp,
            content: "Swift code implementation details",
            appName: "Xcode"
        ))

        // Frame 3: Terminal
        let terminalFrame = FrameReference(
            id: FrameID(),
            timestamp: Date().addingTimeInterval(120),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 2,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Terminal",
                appName: "Terminal",
                windowTitle: "bash"
            )
        )
        try await database.insertFrame(terminalFrame)
        _ = try await database.insertDocument(IndexedDocument(
            id: 0,
            frameID: terminalFrame.id,
            timestamp: terminalFrame.timestamp,
            content: "git commit and push commands",
            appName: "Terminal"
        ))

        // Query by app bundle ID
        let safariFrames = try await database.getFrames(
            appBundleID: "com.apple.Safari",
            limit: 10,
            offset: 0
        )
        XCTAssertEqual(safariFrames.count, 1)
        XCTAssertEqual(safariFrames[0].metadata.appName, "Safari")

        // Search should find content from all apps
        let codeResults = try await ftsManager.search(query: "code", limit: 10, offset: 0)
        XCTAssertEqual(codeResults.count, 2, "Should find code in Safari and Xcode")
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                    DELETION CASCADES                                    ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testDeleteSegment_CascadesToFramesAndDocuments() async throws {
        // Setup: segment → frame → document
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "cascade-test.mp4",
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

        _ = try await database.insertDocument(IndexedDocument(
            id: 0,
            frameID: frame.id,
            timestamp: frame.timestamp,
            content: "Cascade test content"
        ))

        // Verify all exist
        let segmentExists = try await database.getSegment(id: segment.id)
        let frameExists = try await database.getFrame(id: frame.id)
        let documentExists = try await database.getDocument(frameID: frame.id)
        XCTAssertNotNil(segmentExists)
        XCTAssertNotNil(frameExists)
        XCTAssertNotNil(documentExists)

        // Delete segment
        try await database.deleteSegment(id: segment.id)

        // All should be gone
        let segmentAfterDelete = try await database.getSegment(id: segment.id)
        let frameAfterDelete = try await database.getFrame(id: frame.id)
        let documentAfterDelete = try await database.getDocument(frameID: frame.id)
        XCTAssertNil(segmentAfterDelete, "Segment should be deleted")
        XCTAssertNil(frameAfterDelete, "Frame should cascade delete")
        XCTAssertNil(documentAfterDelete, "Document should cascade delete")

        // FTS should also be updated (via trigger)
        let searchResults = try await ftsManager.search(query: "Cascade", limit: 10, offset: 0)
        XCTAssertEqual(searchResults.count, 0, "FTS should not find deleted content")
    }

    func testDeleteOldFrames_RemovesAssociatedDocuments() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date().addingTimeInterval(-86400 * 100),
            endTime: Date(),
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "old-frames.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Old frame
        let oldFrame = FrameReference(
            id: FrameID(),
            timestamp: Date().addingTimeInterval(-86400 * 100),  // 100 days ago
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty
        )
        try await database.insertFrame(oldFrame)
        _ = try await database.insertDocument(IndexedDocument(
            id: 0,
            frameID: oldFrame.id,
            timestamp: oldFrame.timestamp,
            content: "Old searchable content"
        ))

        // Recent frame
        let recentFrame = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty
        )
        try await database.insertFrame(recentFrame)
        _ = try await database.insertDocument(IndexedDocument(
            id: 0,
            frameID: recentFrame.id,
            timestamp: recentFrame.timestamp,
            content: "Recent searchable content"
        ))

        // Delete frames older than 30 days
        let cutoff = Date().addingTimeInterval(-86400 * 30)
        let deleted = try await database.deleteFrames(olderThan: cutoff)

        XCTAssertEqual(deleted, 1, "Should delete 1 old frame")

        // Old document should be gone (cascade)
        let oldDocument = try await database.getDocument(frameID: oldFrame.id)
        XCTAssertNil(oldDocument)

        // Recent document should still exist
        let recentDocument = try await database.getDocument(frameID: recentFrame.id)
        XCTAssertNotNil(recentDocument)

        // FTS should reflect deletion
        let oldResults = try await ftsManager.search(query: "Old searchable", limit: 10, offset: 0)
        let recentResults = try await ftsManager.search(query: "Recent searchable", limit: 10, offset: 0)

        XCTAssertEqual(oldResults.count, 0, "Old content should be gone from FTS")
        XCTAssertEqual(recentResults.count, 1, "Recent content should still be searchable")
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                    STATISTICS ACCURACY                                  ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testStatistics_AccurateAfterMultipleOperations() async throws {
        // Create 3 segments with varying sizes
        var totalSize: Int64 = 0

        for i in 0..<3 {
            let size = Int64((i + 1) * 1024 * 1024)  // 1MB, 2MB, 3MB
            totalSize += size

            let segment = VideoSegment(
                id: SegmentID(),
                startTime: Date().addingTimeInterval(Double(i * 100)),
                endTime: Date().addingTimeInterval(Double(i * 100 + 99)),
                frameCount: 5,
                fileSizeBytes: size,
                relativePath: "segment-\(i).mp4",
                width: 1920,
                height: 1080,
                source: .native
            )
            try await database.insertSegment(segment)

            // Add frames to each segment
            for j in 0..<5 {
                let frame = FrameReference(
                    id: FrameID(),
                    timestamp: Date().addingTimeInterval(Double(i * 100 + j * 10)),
                    segmentID: segment.id,
                    frameIndexInSegment: j,
                    metadata: .empty
                )
                try await database.insertFrame(frame)

                // Add document to some frames
                if j % 2 == 0 {
                    _ = try await database.insertDocument(IndexedDocument(
                        id: 0,
                        frameID: frame.id,
                        timestamp: frame.timestamp,
                        content: "Content for frame \(j) in segment \(i)"
                    ))
                }
            }
        }

        let stats = try await database.getStatistics()

        XCTAssertEqual(stats.segmentCount, 3, "Should have 3 segments")
        XCTAssertEqual(stats.frameCount, 15, "Should have 15 frames (5 per segment)")
        XCTAssertEqual(stats.documentCount, 9, "Should have 9 documents (3 per segment, only even indices)")
        XCTAssertNotNil(stats.oldestFrameDate)
        XCTAssertNotNil(stats.newestFrameDate)

        // Total storage from segments
        let storageBytes = try await database.getTotalStorageBytes()
        XCTAssertEqual(storageBytes, totalSize, "Storage should match sum of segment sizes")
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                    CONCURRENT ACCESS (Actor Safety)                     ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testConcurrentInserts_NoDataCorruption() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(1000),
            frameCount: 100,
            fileSizeBytes: 1024,
            relativePath: "concurrent.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Insert 100 frames concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let frame = FrameReference(
                        id: FrameID(),
                        timestamp: Date().addingTimeInterval(Double(i)),
                        segmentID: segment.id,
                        frameIndexInSegment: i,
                        metadata: FrameMetadata(appName: "App \(i)")
                    )
                    try? await self.database.insertFrame(frame)
                }
            }
        }

        // Verify all frames were inserted
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 100, "All concurrent inserts should succeed")
    }

    func testConcurrentReadsAndWrites_NoDeadlock() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(1000),
            frameCount: 50,
            fileSizeBytes: 1024,
            relativePath: "readwrite.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Pre-insert some frames
        for i in 0..<25 {
            let frame = FrameReference(
                id: FrameID(),
                timestamp: Date().addingTimeInterval(Double(i)),
                segmentID: segment.id,
                frameIndexInSegment: i,
                metadata: .empty
            )
            try await database.insertFrame(frame)
        }

        // Concurrent reads and writes
        await withTaskGroup(of: Int.self) { group in
            // 5 readers
            for _ in 0..<5 {
                group.addTask {
                    let count = try? await self.database.getFrameCount()
                    return count ?? -1
                }
            }

            // 5 writers
            for i in 25..<50 {
                group.addTask {
                    let frame = FrameReference(
                        id: FrameID(),
                        timestamp: Date().addingTimeInterval(Double(i)),
                        segmentID: segment.id,
                        frameIndexInSegment: i,
                        metadata: .empty
                    )
                    try? await self.database.insertFrame(frame)
                    return 0
                }
            }

            // Collect results (just verifying no deadlock)
            for await _ in group { }
        }

        // Should complete without hanging
        let finalCount = try await database.getFrameCount()
        XCTAssertEqual(finalCount, 50, "All operations should complete")
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                    DATABASE MAINTENANCE                                 ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testVacuum_CompletesSuccessfully() async throws {
        // Insert and delete data to create fragmentation
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "vacuum-test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        for i in 0..<10 {
            let frame = FrameReference(
                id: FrameID(),
                timestamp: Date().addingTimeInterval(Double(i)),
                segmentID: segment.id,
                frameIndexInSegment: i,
                metadata: .empty
            )
            try await database.insertFrame(frame)
        }

        // Delete segment (cascades to frames)
        try await database.deleteSegment(id: segment.id)

        // Vacuum should complete without error
        try await database.vacuum()

        // Database should still work
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 0)
    }

    func testAnalyze_CompletesSuccessfully() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "analyze-test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Analyze should complete without error
        try await database.analyze()

        // Database should still work
        let retrieved = try await database.getSegment(id: segment.id)
        XCTAssertNotNil(retrieved)
    }

    func testCheckpoint_CompletesSuccessfully() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "checkpoint-test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Checkpoint should complete without error
        try await database.checkpoint()

        // Database should still work
        let retrieved = try await database.getSegment(id: segment.id)
        XCTAssertNotNil(retrieved)
    }
}
