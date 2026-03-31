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
    var databasePath: String!
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration_tests_\(UUID().uuidString).sqlite")
        databasePath = fileURL.path
        database = DatabaseManager(databasePath: databasePath)
        ftsManager = FTSManager(databasePath: databasePath)
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
        if let databasePath {
            try? FileManager.default.removeItem(atPath: databasePath)
            try? FileManager.default.removeItem(atPath: "\(databasePath)-shm")
            try? FileManager.default.removeItem(atPath: "\(databasePath)-wal")
        }
        databasePath = nil
    }

    private func insertVideoSegment(_ segment: VideoSegment) async throws -> VideoSegmentID {
        VideoSegmentID(value: try await database.insertVideoSegment(segment))
    }

    private func insertFrame(_ frame: FrameReference) async throws -> FrameReference {
        let insertedID = try await database.insertFrame(frame)
        return FrameReference(
            id: FrameID(value: insertedID),
            timestamp: frame.timestamp,
            segmentID: frame.segmentID,
            videoID: frame.videoID,
            frameIndexInSegment: frame.frameIndexInSegment,
            metadata: frame.metadata,
            source: frame.source
        )
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                    CAPTURE → SEARCH FLOW                                ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Simulates: Screen capture → OCR → Index → Search                        │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testFullCaptureToSearchFlow() async throws {
        let timestamp = Date()

        // STEP 1: Simulate capture - create video segment
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(300),
            frameCount: 10,
            fileSizeBytes: 5 * 1024 * 1024,
            relativePath: "segments/2024/01/capture-001.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let storedVideoID = try await insertVideoSegment(videoSegment)

        // Create app segment for frame
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: "Retrace - Screen Recording App",
            browserUrl: "https://github.com/retrace/app",
            type: 0
        )

        // STEP 2: Simulate frame capture with app metadata
        let storedFrame = try await insertFrame(FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: storedVideoID,
            frameIndexInSegment: 0,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Retrace - Screen Recording App",
                browserURL: "https://github.com/retrace/app"
            )
        ))

        // STEP 3: Simulate OCR processing - index extracted text
        let document = IndexedDocument(
            id: 0,
            frameID: storedFrame.id,
            timestamp: storedFrame.timestamp,
            content: "Retrace is a powerful screen recording application that captures your screen and makes it searchable. Built for macOS with privacy in mind.",
            appName: storedFrame.metadata.appName,
            windowName: storedFrame.metadata.windowName,
            browserURL: storedFrame.metadata.browserURL
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
        XCTAssertEqual(searchResults[0].frameID, storedFrame.id, "Result should reference correct frame")
        XCTAssertEqual(searchResults[0].appName, "com.apple.Safari", "Should have current segment bundle ID")
        XCTAssertTrue(searchResults[0].snippet.lowercased().contains("screen"), "Snippet should contain match")
    }

    func testSearchWithDateFilter_FindsOnlyRecentContent() async throws {
        let oldTime = Date().addingTimeInterval(-86400 * 30)
        let recentTime = Date()

        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: oldTime,
            endTime: recentTime,
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let storedVideoID = try await insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: oldTime,
            endDate: recentTime,
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Old frame (30 days ago)
        let oldFrame = try await insertFrame(FrameReference(
            id: FrameID(value: 0),
            timestamp: oldTime,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: storedVideoID,
            frameIndexInSegment: 0,
            metadata: .empty
        ))

        let oldDoc = IndexedDocument(
            id: 0,
            frameID: oldFrame.id,
            timestamp: oldFrame.timestamp,
            content: "Meeting notes from last month"
        )
        _ = try await database.insertDocument(oldDoc)

        // Recent frame (today)
        let recentFrame = try await insertFrame(FrameReference(
            id: FrameID(value: 0),
            timestamp: recentTime,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: storedVideoID,
            frameIndexInSegment: 1,
            metadata: .empty
        ))

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
        let baseTime = Date()

        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: baseTime,
            endTime: baseTime.addingTimeInterval(600),
            frameCount: 3,
            fileSizeBytes: 1024,
            relativePath: "multi-app.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let storedVideoID = try await insertVideoSegment(videoSegment)

        // Create 3 app segments for 3 different apps
        let safariSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: baseTime,
            endDate: baseTime.addingTimeInterval(60),
            windowName: "GitHub",
            browserUrl: nil,
            type: 0
        )

        let xcodeSegmentID = try await database.insertSegment(
            bundleID: "com.apple.dt.Xcode",
            startDate: baseTime.addingTimeInterval(60),
            endDate: baseTime.addingTimeInterval(120),
            windowName: "DatabaseManager.swift",
            browserUrl: nil,
            type: 0
        )

        let terminalSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Terminal",
            startDate: baseTime.addingTimeInterval(120),
            endDate: baseTime.addingTimeInterval(600),
            windowName: "bash",
            browserUrl: nil,
            type: 0
        )

        // Frame 1: Safari
        let safariFrame = try await insertFrame(FrameReference(
            id: FrameID(value: 0),
            timestamp: baseTime,
            segmentID: AppSegmentID(value: safariSegmentID),
            videoID: storedVideoID,
            frameIndexInSegment: 0,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "GitHub"
            )
        ))
        _ = try await database.insertDocument(IndexedDocument(
            id: 0,
            frameID: safariFrame.id,
            timestamp: safariFrame.timestamp,
            content: "GitHub repository code review",
            appName: "Safari"
        ))

        // Frame 2: Xcode
        let xcodeFrame = try await insertFrame(FrameReference(
            id: FrameID(value: 0),
            timestamp: baseTime.addingTimeInterval(60),
            segmentID: AppSegmentID(value: xcodeSegmentID),
            videoID: storedVideoID,
            frameIndexInSegment: 1,
            metadata: FrameMetadata(
                appBundleID: "com.apple.dt.Xcode",
                appName: "Xcode",
                windowName: "DatabaseManager.swift"
            )
        ))
        _ = try await database.insertDocument(IndexedDocument(
            id: 0,
            frameID: xcodeFrame.id,
            timestamp: xcodeFrame.timestamp,
            content: "Swift code implementation details",
            appName: "Xcode"
        ))

        // Frame 3: Terminal
        let terminalFrame = try await insertFrame(FrameReference(
            id: FrameID(value: 0),
            timestamp: baseTime.addingTimeInterval(120),
            segmentID: AppSegmentID(value: terminalSegmentID),
            videoID: storedVideoID,
            frameIndexInSegment: 2,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Terminal",
                appName: "Terminal",
                windowName: "bash"
            )
        ))
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
        XCTAssertEqual(safariFrames[0].metadata.appBundleID, "com.apple.Safari")
        XCTAssertNil(safariFrames[0].metadata.appName)

        // Search should find content from all apps
        let codeResults = try await ftsManager.search(query: "code", limit: 10, offset: 0)
        XCTAssertEqual(codeResults.count, 2, "Should find code in Safari and Xcode")
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                    DELETION CASCADES                                    ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testDeleteVideoSegment_PreservesFramesAndDocumentsAndUnlinksVideo() async throws {
        // Setup: segment → frame → document
        let timestamp = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "cascade-test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let storedVideoID = try await insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let storedFrame = try await insertFrame(FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: storedVideoID,
            frameIndexInSegment: 0,
            metadata: .empty
        ))

        _ = try await database.insertDocument(IndexedDocument(
            id: 0,
            frameID: storedFrame.id,
            timestamp: storedFrame.timestamp,
            content: "Cascade test content"
        ))

        // Verify all exist
        let segmentExists = try await database.getVideoSegment(id: storedVideoID)
        let frameExists = try await database.getFrame(id: storedFrame.id)
        let documentExists = try await database.getDocument(frameID: storedFrame.id)
        XCTAssertNotNil(segmentExists)
        XCTAssertNotNil(frameExists)
        XCTAssertNotNil(documentExists)

        // Delete video row
        try await database.deleteVideoSegment(id: storedVideoID)

        let segmentAfterDelete = try await database.getVideoSegment(id: storedVideoID)
        let frameAfterDelete = try await database.getFrame(id: storedFrame.id)
        let documentAfterDelete = try await database.getDocument(frameID: storedFrame.id)
        XCTAssertNil(segmentAfterDelete, "Segment should be deleted")
        XCTAssertNotNil(frameAfterDelete, "Frames currently survive video deletion")
        XCTAssertEqual(frameAfterDelete?.videoID.value, 0, "Video link should be cleared")
        XCTAssertNotNil(documentAfterDelete, "Documents currently survive video deletion")

        let searchResults = try await ftsManager.search(query: "Cascade", limit: 10, offset: 0)
        XCTAssertEqual(searchResults.count, 1, "FTS should still find surviving indexed content")
        XCTAssertEqual(searchResults[0].frameID, storedFrame.id)
    }

    func testDeleteOldFrames_RemovesAssociatedDocuments() async throws {
        let oldTime = Date().addingTimeInterval(-86400 * 100)
        let recentTime = Date()

        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: oldTime,
            endTime: recentTime,
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "old-frames.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let storedVideoID = try await insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: oldTime,
            endDate: recentTime,
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Old frame
        let oldFrame = try await insertFrame(FrameReference(
            id: FrameID(value: 0),
            timestamp: oldTime,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: storedVideoID,
            frameIndexInSegment: 0,
            metadata: .empty
        ))
        _ = try await database.insertDocument(IndexedDocument(
            id: 0,
            frameID: oldFrame.id,
            timestamp: oldFrame.timestamp,
            content: "Old searchable content"
        ))

        // Recent frame
        let recentFrame = try await insertFrame(FrameReference(
            id: FrameID(value: 0),
            timestamp: recentTime,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: storedVideoID,
            frameIndexInSegment: 1,
            metadata: .empty
        ))
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

            let startTime = Date().addingTimeInterval(Double(i * 100))
            let endTime = Date().addingTimeInterval(Double(i * 100 + 99))

            let videoSegment = VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: startTime,
                endTime: endTime,
                frameCount: 5,
                fileSizeBytes: size,
                relativePath: "segment-\(i).mp4",
                width: 1920,
                height: 1080,
                source: .native
            )
            let storedVideoID = try await insertVideoSegment(videoSegment)

            let appSegmentID = try await database.insertSegment(
                bundleID: "com.test.app",
                startDate: startTime,
                endDate: endTime,
                windowName: nil,
                browserUrl: nil,
                type: 0
            )

            // Add frames to each segment
            for j in 0..<5 {
                let frame = try await insertFrame(FrameReference(
                    id: FrameID(value: 0),
                    timestamp: Date().addingTimeInterval(Double(i * 100 + j * 10)),
                    segmentID: AppSegmentID(value: appSegmentID),
                    videoID: storedVideoID,
                    frameIndexInSegment: j,
                    metadata: .empty
                ))

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
        let startTime = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: startTime,
            endTime: startTime.addingTimeInterval(1000),
            frameCount: 100,
            fileSizeBytes: 1024,
            relativePath: "concurrent.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let storedVideoID = try await insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: startTime,
            endDate: startTime.addingTimeInterval(1000),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Insert 100 frames concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let frame = FrameReference(
                        id: FrameID(value: 0),
                        timestamp: Date().addingTimeInterval(Double(i)),
                        segmentID: AppSegmentID(value: appSegmentID),
                        videoID: storedVideoID,
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
        let startTime = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: startTime,
            endTime: startTime.addingTimeInterval(1000),
            frameCount: 50,
            fileSizeBytes: 1024,
            relativePath: "readwrite.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let storedVideoID = try await insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: startTime,
            endDate: startTime.addingTimeInterval(1000),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Pre-insert some frames
        for i in 0..<25 {
            let frame = FrameReference(
                id: FrameID(value: 0),
                timestamp: Date().addingTimeInterval(Double(i)),
                segmentID: AppSegmentID(value: appSegmentID),
                videoID: storedVideoID,
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
                        id: FrameID(value: 0),
                        timestamp: Date().addingTimeInterval(Double(i)),
                        segmentID: AppSegmentID(value: appSegmentID),
                        videoID: storedVideoID,
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
        let startTime = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: startTime,
            endTime: startTime.addingTimeInterval(300),
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "vacuum-test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let storedVideoID = try await insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: startTime,
            endDate: startTime.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        for i in 0..<10 {
            let frame = FrameReference(
                id: FrameID(value: 0),
                timestamp: Date().addingTimeInterval(Double(i)),
                segmentID: AppSegmentID(value: appSegmentID),
                videoID: storedVideoID,
                frameIndexInSegment: i,
                metadata: .empty
            )
            try await database.insertFrame(frame)
        }

        try await database.deleteVideoSegment(id: storedVideoID)

        // Vacuum should complete without error
        try await database.vacuum()

        // Database should still work and preserve frames whose video link was nulled out.
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 10)
    }

    func testAnalyze_CompletesSuccessfully() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "analyze-test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let storedVideoID = try await insertVideoSegment(segment)

        // Analyze should complete without error
        try await database.analyze()

        // Database should still work
        let retrieved = try await database.getVideoSegment(id: storedVideoID)
        XCTAssertNotNil(retrieved)
    }

    func testCheckpoint_CompletesSuccessfully() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "checkpoint-test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let storedVideoID = try await insertVideoSegment(segment)

        // Checkpoint should complete without error
        try await database.checkpoint()

        // Database should still work
        let retrieved = try await database.getVideoSegment(id: storedVideoID)
        XCTAssertNotNil(retrieved)
    }
}
