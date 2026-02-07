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
// ║                     OCR PIPELINE INTEGRATION TEST                            ║
// ║                                                                              ║
// ║  Tests the full pipeline: JPEG files → OCR → Video → Database → Search      ║
// ║  Set TEST_SCREENSHOT_PATH environment variable to point to test data        ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class OCRPipelineTests: XCTestCase {

    // MARK: - Properties

    var database: DatabaseManager!
    var ftsManager: FTSManager!
    var storage: StorageManager!
    var processing: ProcessingManager!
    var search: SearchManager!
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
        print("  OCR PIPELINE TEST - Processing Real Screenshots")
        print(String(repeating: "═", count: 70))

        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceOCRPipelineTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

        // Create isolated storage directory for this test run
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        // Initialize managers with isolated test database path
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
            accessibilityEnabled: false, // Disable for test - no UI context
            ocrAccuracyLevel: .accurate,
            recognitionLanguages: ["en-US"],
            minimumConfidence: 0.3
        ))

        search = SearchManager(database: database, ftsEngine: ftsManager)
        try await search.initialize(config: .default)

        print("✓ All managers initialized")
        print("  Database: \(testDatabasePath)")
        print("  Storage: \(storageRoot.path)")
    }

    override func tearDown() async throws {
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
        if testRoot != nil {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil

        print("\n✓ Test cleanup complete")
        print(String(repeating: "═", count: 70) + "\n")
    }

    // MARK: - Main Test

    /// Process all screenshots through the full pipeline
    func testProcessScreenshotsThroughFullPipeline() async throws {
        // STEP 1: Discover all screenshot files
        print("\n📁 Scanning for screenshots...")
        let files = try FileManager.default.contentsOfDirectory(atPath: screenshotPath)
            .filter { $0.hasSuffix(".jpeg") }
            .sorted()

        print("   Found \(files.count) screenshots")

        guard !files.isEmpty else {
            XCTFail("No screenshots found at \(screenshotPath)")
            return
        }

        // STEP 2: Process frames in batches (for video segments)
        let framesPerSegment = 150 // 5 minutes at 2s intervals
        var totalFramesProcessed = 0
        var totalOCRRegions = 0
        var totalTextLength = 0
        var videoSegmentsCreated = 0

        // Track current app segment (simulated - all frames from same "app")
        var currentAppSegmentID: Int64?

        let startTime = Date()

        // Process in batches for video segments
        let batches = stride(from: 0, to: files.count, by: framesPerSegment).map {
            Array(files[$0..<min($0 + framesPerSegment, files.count)])
        }

        print("\n🎬 Processing \(batches.count) video segments...")

        for (batchIndex, batch) in batches.enumerated() {
            print("\n─── Segment \(batchIndex + 1)/\(batches.count) (\(batch.count) frames) ───")

            // Create video segment writer
            var segmentWriter = try await storage.createSegmentWriter()
            var framesInSegment: [(frameID: Int64, timestamp: Date, regions: [TextRegion], fullText: String, chromeText: String, frameIndex: Int)] = []

            for (frameIndex, filename) in batch.enumerated() {
                // Extract timestamp from filename
                let timestampStr = filename.replacingOccurrences(of: ".jpeg", with: "")
                guard let unixTimestamp = TimeInterval(timestampStr) else {
                    print("   ⚠️ Invalid filename: \(filename)")
                    continue
                }
                let frameTimestamp = Date(timeIntervalSince1970: unixTimestamp)

                // Load and process the image
                let imagePath = (screenshotPath as NSString).appendingPathComponent(filename)
                guard let nsImage = NSImage(contentsOfFile: imagePath) else {
                    print("   ⚠️ Failed to load: \(filename)")
                    continue
                }

                // Convert NSImage to raw BGRA pixel data for CapturedFrame
                guard let capturedFrame = createCapturedFrame(from: nsImage, timestamp: frameTimestamp) else {
                    print("   ⚠️ Failed to convert: \(filename)")
                    continue
                }

                // Ensure we have an app segment
                if currentAppSegmentID == nil {
                    currentAppSegmentID = try await database.insertSegment(
                        bundleID: "com.test.screenshots",
                        startDate: frameTimestamp,
                        endDate: frameTimestamp,
                        windowName: "Screenshot Test Session",
                        browserUrl: nil,
                        type: 0
                    )
                }

                // Append frame to video segment
                try await segmentWriter.appendFrame(capturedFrame)

                // Run OCR
                let extractedText = try await processing.extractText(from: capturedFrame)

                // Insert frame into database (videoID will be NULL initially, updated after video finalization)
                let frameRef = FrameReference(
                    id: FrameID(value: 0),
                    timestamp: frameTimestamp,
                    segmentID: AppSegmentID(value: currentAppSegmentID!),
                    videoID: VideoSegmentID(value: 0), // Will be updated after video finalization
                    frameIndexInSegment: frameIndex,
                    metadata: FrameMetadata(
                        appBundleID: "com.test.screenshots",
                        appName: "Screenshot Test",
                        windowName: "Test Session"
                    ),
                    source: .native
                )
                let frameID = try await database.insertFrame(frameRef)

                // Store for batch FTS indexing and video linking
                framesInSegment.append((
                    frameID: frameID,
                    timestamp: frameTimestamp,
                    regions: extractedText.regions,
                    fullText: extractedText.fullText,
                    chromeText: extractedText.chromeText,
                    frameIndex: frameIndex
                ))

                totalFramesProcessed += 1
                totalOCRRegions += extractedText.regions.count
                totalTextLength += extractedText.fullText.count

                // Progress on every frame
                let elapsed = Date().timeIntervalSince(startTime)
                let fps = Double(totalFramesProcessed) / elapsed
                print("   [\(totalFramesProcessed)/\(files.count)] Frame \(frameIndex + 1) | \(extractedText.regions.count) regions | \(extractedText.fullText.count) chars | \(String(format: "%.2f", fps)) fps")
                fflush(stdout)
            }

            // Finalize video segment
            let videoSegment = try await segmentWriter.finalize()
            let videoID = try await database.insertVideoSegment(videoSegment)
            videoSegmentsCreated += 1

            print("   ✓ Video segment saved: \(videoSegment.relativePath) (\(videoSegment.fileSizeBytes / 1024) KB)")

            // Update all frames with the correct videoID
            for frameData in framesInSegment {
                try await database.updateFrameVideoLink(
                    frameID: FrameID(value: frameData.frameID),
                    videoID: VideoSegmentID(value: videoID),
                    frameIndex: frameData.frameIndex
                )
            }

            // Index all frames in FTS and insert OCR nodes
            for frameData in framesInSegment {
                // Index in FTS
                let docid = try await search.index(
                    text: ExtractedText(
                        frameID: FrameID(value: frameData.frameID),
                        timestamp: frameData.timestamp,
                        regions: frameData.regions,
                        fullText: frameData.fullText,
                        chromeText: frameData.chromeText
                    ),
                    segmentId: currentAppSegmentID!,
                    frameId: frameData.frameID
                )

                // Insert OCR nodes with text offsets
                if docid > 0 && !frameData.regions.isEmpty {
                    var currentOffset = 0
                    var nodeData: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)] = []

                    for region in frameData.regions {
                        let textLength = region.text.count
                        nodeData.append((
                            textOffset: currentOffset,
                            textLength: textLength,
                            bounds: region.bounds,
                            windowIndex: nil
                        ))
                        currentOffset += textLength + 1
                    }

                    // Use actual captured frame dimensions for normalization
                    // Note: We need to get the dimensions from the capturedFrame that was used for OCR
                    // For now, we'll use the video segment dimensions which should match
                    try await database.insertNodes(
                        frameID: FrameID(value: frameData.frameID),
                        nodes: nodeData,
                        frameWidth: videoSegment.width,
                        frameHeight: videoSegment.height
                    )
                }
            }

            // Update app segment end date
            if let segmentID = currentAppSegmentID, let lastFrame = framesInSegment.last {
                try await database.updateSegmentEndDate(id: segmentID, endDate: lastFrame.timestamp)
            }
        }

        // STEP 3: Print final statistics
        let totalElapsed = Date().timeIntervalSince(startTime)

        print("\n" + String(repeating: "═", count: 70))
        print("  PIPELINE COMPLETE")
        print(String(repeating: "═", count: 70))
        print("  ✓ Frames processed:    \(totalFramesProcessed)")
        print("  ✓ Video segments:      \(videoSegmentsCreated)")
        print("  ✓ OCR regions:         \(totalOCRRegions)")
        print("  ✓ Total text chars:    \(totalTextLength)")
        print("  ✓ Total time:          \(String(format: "%.1f", totalElapsed)) seconds")
        print("  ✓ Average:             \(String(format: "%.2f", Double(totalFramesProcessed) / totalElapsed)) fps")
        print(String(repeating: "═", count: 70))

        // STEP 4: Verify data in database
        let stats = try await database.getStatistics()
        print("\n📊 Database Statistics:")
        print("   Frames:     \(stats.frameCount)")
        print("   Segments:   \(stats.segmentCount)")
        print("   Documents:  \(stats.documentCount)")
        print("   DB Size:    \(stats.databaseSizeBytes / 1024) KB")

        // Assertions
        XCTAssertEqual(stats.frameCount, totalFramesProcessed, "All frames should be in database")
        XCTAssertGreaterThan(videoSegmentsCreated, 0, "Should have created video segments")

        // Verify all frames have valid videoIDs
        let nullVideoCount = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            Task {
                do {
                    guard let db = await database.getConnection() else {
                        continuation.resume(returning: -1)
                        return
                    }

                    var statement: OpaquePointer?
                    defer { sqlite3_finalize(statement) }
                    let sql = "SELECT COUNT(*) FROM frame WHERE videoId IS NULL;"

                    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                          sqlite3_step(statement) == SQLITE_ROW else {
                        continuation.resume(returning: -1)
                        return
                    }

                    continuation.resume(returning: Int(sqlite3_column_int(statement, 0)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(nullVideoCount, 0, "All frames should have a valid videoId after processing")
    }

    // MARK: - Helper Methods

    /// Clean all test data from database to prevent duplication
    private func cleanDatabase() async throws {
        guard let db = await database.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Delete FTS content first (before frames are deleted due to foreign key constraints)
        var stmt: OpaquePointer?
        sqlite3_exec(db, "DELETE FROM searchRanking;", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM doc_segment;", nil, nil, nil)

        // Delete all frames (cascade will delete nodes)
        _ = try await database.deleteFrames(olderThan: Date(timeIntervalSinceNow: 86400))

        // Delete all segments
        let segments = try await database.getSegments(from: Date(timeIntervalSince1970: 0), to: Date())
        for segment in segments {
            try await database.deleteSegment(id: segment.id.value)
        }

        // Delete all video segments
        let videos = try await database.getVideoSegments(from: Date(timeIntervalSince1970: 0), to: Date())
        for video in videos {
            try await database.deleteVideoSegment(id: video.id)
        }

        // Rebuild FTS index (will be empty since we deleted all content)
        try await ftsManager.rebuildIndex()
    }

    /// Convert NSImage to CapturedFrame with raw BGRA pixel data
    private func createCapturedFrame(from nsImage: NSImage, timestamp: Date) -> CapturedFrame? {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4 // BGRA = 4 bytes per pixel

        // Create a bitmap context with BGRA format
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
                appBundleID: "com.test.screenshots",
                appName: "Screenshot Test",
                windowName: "Test Session"
            )
        )
    }
}
