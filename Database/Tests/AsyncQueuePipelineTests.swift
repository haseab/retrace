import XCTest
import Foundation
import AppKit
import Vision
import AVFoundation
import SQLCipher
import Shared
@testable import Database
@testable import Storage
@testable import Processing
@testable import Search

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                  ASYNC QUEUE PIPELINE INTEGRATION TEST                       ║
// ║                                                                              ║
// ║  Tests the full async pipeline: JPEG → Video → Queue → Workers → Search     ║
// ║  Set TEST_SCREENSHOT_PATH environment variable to point to test data        ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class AsyncQueuePipelineTests: XCTestCase {

    // MARK: - Properties

    var database: DatabaseManager!
    var ftsManager: FTSManager!
    var storage: StorageManager!
    var processing: ProcessingManager!
    var search: SearchManager!
    var processingQueue: FrameProcessingQueue!
    var testRoot: URL!

    /// Path to test screenshots (set via TEST_SCREENSHOT_PATH env var)
    var screenshotPath: String {
        ProcessInfo.processInfo.environment["TEST_SCREENSHOT_PATH"] ?? NSString(string: "~/ScreenMemoryData/screenshots").expandingTildeInPath
    }

    /// Database path for this test (isolated temp location)
    var testDatabasePath: String {
        testRoot.appendingPathComponent("retrace-test.db").path
    }

    /// Storage root for video segments (isolated temp location)
    var storageRoot: URL {
        testRoot.appendingPathComponent("storage", isDirectory: true)
    }

    // MARK: - Setup/Teardown

    override func setUp() async throws {
        print("\n" + String(repeating: "═", count: 70))
        print("  ASYNC QUEUE PIPELINE TEST - Testing Background Processing")
        print(String(repeating: "═", count: 70))

        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceAsyncQueueTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

        // Create isolated storage directory for this test run
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        // Initialize managers
        database = DatabaseManager(databasePath: testDatabasePath)
        ftsManager = FTSManager(databasePath: testDatabasePath)
        storage = StorageManager(storageRoot: storageRoot)
        processing = ProcessingManager(config: .default)

        try await database.initialize()
        try await ftsManager.initialize()
        try await storage.initialize(config: StorageConfig(
            storageRootPath: storageRoot.path,
            retentionDays: nil,
            maxStorageGB: 100,
            segmentDurationSeconds: 300
        ))
        try await processing.initialize(config: ProcessingConfig(
            accessibilityEnabled: false,
            ocrAccuracyLevel: .accurate,
            recognitionLanguages: ["en-US"],
            minimumConfidence: 0.3
        ))

        search = SearchManager(database: database, ftsEngine: ftsManager)
        try await search.initialize(config: .default)

        // Initialize processing queue with workers
        processingQueue = FrameProcessingQueue(
            database: database,
            storage: storage,
            processing: processing,
            search: search,
            config: ProcessingQueueConfig(
                workerCount: 2,  // Use 2 workers for testing
                maxRetryAttempts: 3,
                maxQueueSize: 1000
            )
        )
        await processingQueue.startWorkers()

        print("✓ All managers and queue initialized")
        print("  Database: \(testDatabasePath)")
        print("  Storage: \(storageRoot.path)")
        print("  Workers: 2")
    }

    override func tearDown() async throws {
        if processingQueue != nil {
            // Stop workers first
            await processingQueue.stopWorkers()
        }
        if ftsManager != nil {
            try await ftsManager.close()
        }
        if database != nil {
            try await database.close()
        }

        database = nil
        ftsManager = nil
        storage = nil
        processing = nil
        search = nil
        processingQueue = nil
        if testRoot != nil {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil

        print("\n✓ Test cleanup complete")
        print(String(repeating: "═", count: 70) + "\n")
    }

    // MARK: - Main Test

    /// Process screenshots through async queue pipeline
    func testProcessScreenshotsThroughAsyncQueue() async throws {
        // STEP 1: Discover screenshot files
        print("\n📁 Scanning for screenshots...")
        let files = try FileManager.default.contentsOfDirectory(atPath: screenshotPath)
            .filter { $0.hasSuffix(".jpeg") }
            .sorted()

        print("   Found \(files.count) screenshots to process")

        guard !files.isEmpty else {
            XCTFail("No screenshots found at \(screenshotPath)")
            return
        }

        // STEP 2: Process frames in batches (for video segments)
        let framesPerSegment = 150 // 5 minutes at 2s intervals
        var totalFramesProcessed = 0
        var videoSegmentsCreated = 0
        var currentAppSegmentID: Int64?
        var allEnqueuedFrameIDs: [Int64] = []

        // Process in batches for video segments
        let batches = stride(from: 0, to: files.count, by: framesPerSegment).map {
            Array(files[$0..<min($0 + framesPerSegment, files.count)])
        }

        print("\n🎬 Processing \(batches.count) video segments...")

        for (batchIndex, batch) in batches.enumerated() {
            print("\n─── Segment \(batchIndex + 1)/\(batches.count) (\(batch.count) frames) ───")

            var segmentWriter = try await storage.createSegmentWriter()
            var enqueuedFrameIDs: [Int64] = []
            var frameTimestamps: [Date] = []

            for (frameIndex, filename) in batch.enumerated() {
            // Extract timestamp from filename
            let timestampStr = filename.replacingOccurrences(of: ".jpeg", with: "")
            guard let unixTimestamp = TimeInterval(timestampStr) else {
                print("   ⚠️ Invalid filename: \(filename)")
                continue
            }
            let frameTimestamp = Date(timeIntervalSince1970: unixTimestamp)

            // Load image
            let imagePath = (screenshotPath as NSString).appendingPathComponent(filename)
            guard let nsImage = NSImage(contentsOfFile: imagePath),
                  let capturedFrame = createCapturedFrame(from: nsImage, timestamp: frameTimestamp) else {
                print("   ⚠️ Failed to load: \(filename)")
                continue
            }

            // Create app segment if needed
            if currentAppSegmentID == nil {
                currentAppSegmentID = try await database.insertSegment(
                    bundleID: "com.test.asyncqueue",
                    startDate: frameTimestamp,
                    endDate: frameTimestamp,
                    windowName: "Async Queue Test Session",
                    browserUrl: nil,
                    type: 0
                )
            }

            // Append frame to video
            try await segmentWriter.appendFrame(capturedFrame)

            // Insert frame into database with PENDING status
            let frameRef = FrameReference(
                id: FrameID(value: 0),
                timestamp: frameTimestamp,
                segmentID: AppSegmentID(value: currentAppSegmentID!),
                videoID: VideoSegmentID(value: 0),  // Will be updated after finalization
                frameIndexInSegment: frameIndex,
                metadata: FrameMetadata(
                    appBundleID: "com.test.asyncqueue",
                    appName: "Async Queue Test",
                    windowName: "Test Session"
                ),
                source: .native
            )
            let frameID = try await database.insertFrame(frameRef)
            enqueuedFrameIDs.append(frameID)
            frameTimestamps.append(frameTimestamp)

            totalFramesProcessed += 1

            // Print progress every 10 frames within segment
            if (frameIndex + 1) % 10 == 0 || frameIndex == 0 || frameIndex == batch.count - 1 {
                print("   [Frame \(totalFramesProcessed)/\(files.count)] Inserted frameID=\(frameID)")
            }
        }

        // Finalize video segment
        let videoSegment = try await segmentWriter.finalize()
        let videoID = try await database.insertVideoSegment(videoSegment)
        videoSegmentsCreated += 1

        print("   ✓ Video segment \(batchIndex + 1) saved: \(videoSegment.relativePath) (\(videoSegment.fileSizeBytes / 1024) KB)")

        // Update all frames in this segment with the correct videoID
        for (index, frameID) in enqueuedFrameIDs.enumerated() {
            try await database.updateFrameVideoLink(
                frameID: FrameID(value: frameID),
                videoID: VideoSegmentID(value: videoID),
                frameIndex: index
            )
        }

        // Enqueue frames for async processing
        for frameID in enqueuedFrameIDs {
            try await processingQueue.enqueue(frameID: frameID)
        }

        // Add to global list
        allEnqueuedFrameIDs.append(contentsOf: enqueuedFrameIDs)

            // Update app segment end date
            if let segmentID = currentAppSegmentID, let lastTimestamp = frameTimestamps.last {
                try await database.updateSegmentEndDate(id: segmentID, endDate: lastTimestamp)
            }
        }

        print("\n   ✓ Total: \(videoSegmentsCreated) video segments, \(allEnqueuedFrameIDs.count) frames enqueued for processing")

        // STEP 3: Wait for queue to drain AND all workers to finish
        print("\n⏳ Waiting for async workers to process all frames...")
        let startWait = Date()
        let maxWaitTime: TimeInterval = 120  // 2 minutes max

        var lastPrintedProcessed = 0
        while true {
            let queueDepth = try await processingQueue.getQueueDepth()
            let stats = await processingQueue.getStatistics()

            // Print progress every 10 processed frames or when queue is done
            if stats.totalProcessed - lastPrintedProcessed >= 10 || queueDepth == 0 {
                print("   Queue depth: \(queueDepth), Processed: \(stats.totalProcessed), Failed: \(stats.totalFailed)")
                lastPrintedProcessed = stats.totalProcessed
            }

            // Wait for queue to drain AND all frames to be processed
            if queueDepth == 0 && stats.totalProcessed >= allEnqueuedFrameIDs.count {
                // Give a small grace period for workers to mark frames as completed
                try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds
                break
            }

            if Date().timeIntervalSince(startWait) > maxWaitTime {
                XCTFail("Queue did not drain within \(maxWaitTime) seconds")
                break
            }

            try await Task.sleep(nanoseconds: 500_000_000)  // Wait 0.5 seconds
        }

        let elapsedWait = Date().timeIntervalSince(startWait)
        print("   ✓ Queue drained in \(String(format: "%.1f", elapsedWait)) seconds")

        // STEP 4: Verify all frames were processed
        print("\n✅ Verifying processing results...")

        var completedCount = 0
        var failedCount = 0
        var pendingCount = 0

        for frameID in allEnqueuedFrameIDs {
            guard let frame = try await database.getFrame(id: FrameID(value: frameID)) else {
                XCTFail("Frame \(frameID) not found in database")
                continue
            }

            let status = try await getFrameProcessingStatus(frameID: frameID)

            switch status {
            case .pending:
                pendingCount += 1
            case .processing:
                XCTFail("Frame \(frameID) still marked as processing after queue drain")
            case .completed:
                completedCount += 1
            case .failed:
                failedCount += 1
            }
        }

        print("   Completed: \(completedCount)")
        print("   Failed: \(failedCount)")
        print("   Still Pending: \(pendingCount)")

        // STEP 5: Verify FTS indexing
        print("\n🔍 Verifying FTS indexing...")

        let dbStats = try await database.getStatistics()
        print("   FTS Documents: \(dbStats.documentCount)")

        XCTAssertGreaterThan(dbStats.documentCount, 0, "Should have indexed documents in FTS")
        XCTAssertEqual(completedCount, allEnqueuedFrameIDs.count, "All frames should be completed")
        XCTAssertEqual(pendingCount, 0, "No frames should remain pending")

        // STEP 6: Test search functionality
        print("\n🔎 Testing search on async-processed content...")

        // Verify FTS is searchable (search for anything will return all docs if indexed properly)
        // Note: Actual content depends on screenshots, so we just verify search doesn't crash
        let searchResults = try await search.search(text: "a", limit: 10)

        print("   Search query executed successfully (\(searchResults.results.count) results)")
        // Don't assert on specific count since content varies, just verify search works
        XCTAssertGreaterThanOrEqual(dbStats.documentCount, allEnqueuedFrameIDs.count, "Should have indexed all processed frames")

        // STEP 7: Final statistics
        let finalStats = await processingQueue.getStatistics()

        print("\n" + String(repeating: "═", count: 70))
        print("  ASYNC PIPELINE COMPLETE")
        print(String(repeating: "═", count: 70))
        print("  ✓ Video segments:      \(videoSegmentsCreated)")
        print("  ✓ Frames enqueued:     \(allEnqueuedFrameIDs.count)")
        print("  ✓ Frames completed:    \(completedCount)")
        print("  ✓ Frames failed:       \(failedCount)")
        print("  ✓ FTS documents:       \(dbStats.documentCount)")
        print("  ✓ Processing time:     \(String(format: "%.1f", elapsedWait)) seconds")
        print("  ✓ Throughput:          \(String(format: "%.2f", Double(allEnqueuedFrameIDs.count) / elapsedWait)) fps")
        print(String(repeating: "═", count: 70))
    }

    // MARK: - Helper Methods

    /// Get frame processing status
    private func getFrameProcessingStatus(frameID: Int64) async throws -> FrameProcessingStatus {
        guard let db = await database.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT processingStatus FROM frame WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, frameID)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: "Frame not found")
        }

        let statusInt = Int(sqlite3_column_int(stmt, 0))
        return FrameProcessingStatus(rawValue: statusInt) ?? .pending
    }

    /// Convert NSImage to CapturedFrame with raw BGRA pixel data
    private func createCapturedFrame(from nsImage: NSImage, timestamp: Date) -> CapturedFrame? {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        var pixelData = Data(count: bytesPerRow * height)

        pixelData.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return CapturedFrame(
            timestamp: timestamp,
            imageData: pixelData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: FrameMetadata(
                appBundleID: "com.test.asyncqueue",
                appName: "Async Queue Test",
                windowName: "Test Session"
            )
        )
    }
}
