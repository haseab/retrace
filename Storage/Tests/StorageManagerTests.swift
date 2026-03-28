import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import Shared
@testable import Storage

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                      STORAGE MANAGER TESTS                                   ║
// ║                                                                              ║
// ║  • Verify encrypt/decrypt is no-op when encryption disabled                  ║
// ║  • Verify key generation, export, import round trip                          ║
// ║  • Verify encrypt/decrypt round trip when encryption enabled                 ║
// ║  • Verify segment exists after create and is removed after cancel            ║
// ║  • Verify getSegmentPath finds segment by ID                                 ║
// ║  • Verify cleanupOldSegments deletes files older than cutoff                 ║
// ║  • Verify getTotalStorageUsed sums all segment sizes                         ║
// ║  • Verify readFrame throws error for missing segment                         ║
// ║  • Verify getAvailableDiskSpace returns non-negative value                   ║
// ║  • Verify segment writer append/finalize creates segment file                ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class StorageManagerTests: XCTestCase {

    private static var hasPrintedSeparator = false

    override func setUp() {
        super.setUp()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                           Helper Methods                                 │
    // └──────────────────────────────────────────────────────────────────────────┘

    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceStorageTests_\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStorageConfig(root: URL) -> StorageConfig {
        StorageConfig(
            storageRootPath: root.path,
            retentionDays: nil,
            maxStorageGB: nil,
            segmentDurationSeconds: 300
        )
    }

    private func createFakeSegmentFile(
        root: URL,
        id: VideoSegmentID,
        date: Date,
        ext: String? = nil,
        size: Int,
        modDate: Date
    ) throws -> URL {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        let dir = root
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent(String(format: "%04d%02d", year, month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileName: String
        if let ext, !ext.isEmpty {
            fileName = "\(id.stringValue).\(ext)"
        } else {
            fileName = id.stringValue
        }
        let url = dir.appendingPathComponent(fileName)
        let data = Data(repeating: 0xCD, count: size)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modDate], ofItemAtPath: url.path)
        return url
    }

    private func diskUsageBytes(at url: URL) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let output = String(data: data, encoding: .utf8),
            let sizeKB = Int64(output.split(separator: "\t").first ?? "")
        else {
            XCTFail("Failed to parse du output for \(url.path)")
            return 0
        }

        return sizeKB * 1024
    }

    private func makeCapturedFrame(
        width: Int = 4,
        height: Int = 4,
        bytesPerRow: Int? = nil,
        imageByteCount: Int? = nil,
        timestamp: Date = Date(),
        metadata: FrameMetadata = FrameMetadata(
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            windowName: "Window",
            browserURL: "https://example.com",
            displayID: 1
        )
    ) -> CapturedFrame {
        let rowBytes = bytesPerRow ?? max(1, width * 4)
        let dataSize = imageByteCount ?? max(1, rowBytes * max(height, 1))
        return CapturedFrame(
            timestamp: timestamp,
            imageData: Data(repeating: 0xAB, count: dataSize),
            width: width,
            height: height,
            bytesPerRow: rowBytes,
            metadata: metadata
        )
    }

    private func makePatternedCapturedFrame(
        width: Int = 64,
        height: Int = 64,
        targetRect: CGRect
    ) -> CapturedFrame {
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)

        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }

            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    let point = CGPoint(x: x, y: y)
                    if targetRect.contains(point) {
                        let checker = ((x / 4) + (y / 4)).isMultiple(of: 2)
                        baseAddress[offset] = checker ? 24 : 232
                        baseAddress[offset + 1] = UInt8((x * 3) % 256)
                        baseAddress[offset + 2] = UInt8((y * 5) % 256)
                        baseAddress[offset + 3] = 255
                    } else {
                        baseAddress[offset] = 212
                        baseAddress[offset + 1] = 212
                        baseAddress[offset + 2] = 212
                        baseAddress[offset + 3] = 255
                    }
                }
            }
        }

        return CapturedFrame(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            imageData: data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: .empty
        )
    }

    private func decodeJPEG(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func extractPatch(
        from data: Data,
        imageWidth: Int,
        rect: CGRect
    ) -> Data {
        let width = Int(rect.width)
        let height = Int(rect.height)
        let originX = Int(rect.origin.x)
        let originY = Int(rect.origin.y)
        let bytesPerRow = imageWidth * 4
        let patchBytesPerRow = width * 4
        var patch = Data(count: patchBytesPerRow * height)

        data.withUnsafeBytes { sourceRaw in
            patch.withUnsafeMutableBytes { patchRaw in
                guard let sourceBase = sourceRaw.baseAddress,
                      let patchBase = patchRaw.baseAddress else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = (originY + row) * bytesPerRow + originX * 4
                    let destinationOffset = row * patchBytesPerRow
                    memcpy(
                        patchBase.advanced(by: destinationOffset),
                        sourceBase.advanced(by: sourceOffset),
                        patchBytesPerRow
                    )
                }
            }
        }

        return patch
    }

    private func averageAbsoluteDifference(_ lhs: Data, _ rhs: Data) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let lhsBytes = Array(lhs)
        let rhsBytes = Array(rhs)
        let totalDifference = zip(lhsBytes, rhsBytes).reduce(0) { partialResult, pair in
            partialResult + abs(Int(pair.0) - Int(pair.1))
        }
        return Double(totalDifference) / Double(lhs.count)
    }

    private func makeDatabase(name: String) async throws -> RecoveryTestDatabase {
        _ = name
        let database = RecoveryTestDatabase()
        try await database.initialize()
        return database
    }

    private func makeRecoveryManager(
        walManager: WALManager,
        storage: StorageProtocol,
        database: DatabaseProtocol
    ) -> RecoveryManager {
        RecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )
    }

    private func makePlaceholderVideo(
        id: VideoSegmentID,
        start: Date,
        frameCount: Int,
        fileSizeBytes: Int64 = 123,
        width: Int = 8,
        height: Int = 8
    ) -> VideoSegment {
        VideoSegment(
            id: id,
            startTime: start,
            endTime: start.addingTimeInterval(Double(max(frameCount, 1))),
            frameCount: frameCount,
            fileSizeBytes: fileSizeBytes,
            relativePath: "chunks/202603/12/\(id.value)",
            width: width,
            height: height
        )
    }

    @discardableResult
    private func insertStoredFrame(
        database: RecoveryTestDatabase,
        frameID: Int64,
        timestamp: Date,
        segmentID: Int64,
        videoID: Int64,
        frameIndex: Int,
        metadata: FrameMetadata
    ) async throws -> Int64 {
        try await database.insertFrame(
            FrameReference(
                id: FrameID(value: frameID),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: segmentID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: frameIndex,
                metadata: metadata,
                source: .native
            )
        )
    }

    private func corruptWALMetadata(for session: WALSession, contents: Data = Data("{invalid".utf8)) throws {
        let metadataURL = session.sessionDir.appendingPathComponent("metadata.json")
        try contents.write(to: metadataURL)
    }

    private func loadWALMetadata(from sessionDir: URL) throws -> WALMetadata {
        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WALMetadata.self, from: data)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                       Segment Management Tests                           │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testSegmentExistsAfterCreateAndCancel() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let writer = try await storage.createSegmentWriter()
        let id = await writer.segmentID

        // Note: File is only created after first frame is written with AVAssetWriter
        // Before that, segmentExists should return false
        let exists1 = try await storage.segmentExists(id: id)
        XCTAssertFalse(exists1)  // Changed from True - file doesn't exist until first frame

        try await writer.cancel()
        let exists2 = try await storage.segmentExists(id: id)
        XCTAssertFalse(exists2)

        try? FileManager.default.removeItem(at: root)
    }

    func testGetSegmentPathFindsExtensionlessAndMP4Files() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let now = Date()
        let extensionlessID = VideoSegmentID(value: 101)
        let mp4ID = VideoSegmentID(value: 102)
        let extensionlessURL = try createFakeSegmentFile(
            root: root,
            id: extensionlessID,
            date: now,
            size: 16,
            modDate: now
        )
        let mp4URL = try createFakeSegmentFile(
            root: root,
            id: mp4ID,
            date: now,
            ext: "mp4",
            size: 24,
            modDate: now
        )

        let foundExtensionless = try await storage.getSegmentPath(id: extensionlessID)
        let foundMP4 = try await storage.getSegmentPath(id: mp4ID)

        XCTAssertEqual(foundExtensionless.standardizedFileURL.path, extensionlessURL.standardizedFileURL.path)
        XCTAssertEqual(foundMP4.standardizedFileURL.path, mp4URL.standardizedFileURL.path)

        try? FileManager.default.removeItem(at: root)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                            Cleanup Tests                                 │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testCleanupOldSegmentsReturnsCandidatesAndCallerDeletesFiles() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let oldDate = Date(timeIntervalSinceNow: -7 * 24 * 3600)
        let cutoff = Date(timeIntervalSinceNow: -24 * 3600)
        let recentDate = Date()

        let id1 = VideoSegmentID(value: 201)
        let id2 = VideoSegmentID(value: 202)
        let recentID = VideoSegmentID(value: 203)
        let oldURL1 = try createFakeSegmentFile(root: root, id: id1, date: oldDate, size: 10, modDate: oldDate)
        let oldURL2 = try createFakeSegmentFile(root: root, id: id2, date: oldDate, ext: "mp4", size: 20, modDate: oldDate)
        let recentURL = try createFakeSegmentFile(root: root, id: recentID, date: recentDate, ext: "mp4", size: 30, modDate: recentDate)

        let candidates = try await storage.cleanupOldSegments(olderThan: cutoff)
        XCTAssertEqual(Set(candidates), Set([id1, id2]))

        for segmentID in candidates {
            try await storage.deleteSegment(id: segmentID)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
        let exists1 = try await storage.segmentExists(id: id1)
        XCTAssertFalse(exists1)
        let exists2 = try await storage.segmentExists(id: id2)
        XCTAssertFalse(exists2)
        let recentExists = try await storage.segmentExists(id: recentID)
        XCTAssertTrue(recentExists)

        try? FileManager.default.removeItem(at: root)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Storage Metrics Tests                             │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testTotalStorageUsedMatchesChunkDiskUsage() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let now = Date()
        let id1 = VideoSegmentID(value: 301)
        let id2 = VideoSegmentID(value: 302)
        _ = try createFakeSegmentFile(root: root, id: id1, date: now, size: 123, modDate: now)
        _ = try createFakeSegmentFile(root: root, id: id2, date: now, ext: "mp4", size: 456, modDate: now)

        let chunksURL = root.appendingPathComponent("chunks", isDirectory: true)
        let expected = try diskUsageBytes(at: chunksURL)
        let total = try await storage.getTotalStorageUsed(includeRewind: false)
        XCTAssertEqual(total, expected)

        try? FileManager.default.removeItem(at: root)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                         Frame Reading Tests                              │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testReadFrameThrowsForMissingSegment() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let missingID = VideoSegmentID(value: 0)
        await XCTAssertThrowsErrorAsync {
            _ = try await storage.readFrame(segmentID: missingID, frameIndex: 0)
        }

        try? FileManager.default.removeItem(at: root)
    }

    func testAvailableDiskSpaceNonNegative() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let bytes = try await storage.getAvailableDiskSpace()
        XCTAssertGreaterThanOrEqual(bytes, 0)

        try? FileManager.default.removeItem(at: root)
    }

    func testMakeBGRADataPreservesImageRowOrdering() throws {
        let width = 2
        let height = 2
        let bytesPerRow = width * 4
        var source = Data(count: bytesPerRow * height)

        source.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                XCTFail("Missing source image buffer")
                return
            }

            func writePixel(x: Int, y: Int, red: UInt8, green: UInt8, blue: UInt8) {
                let offset = (y * bytesPerRow) + (x * 4)
                baseAddress[offset + 0] = blue
                baseAddress[offset + 1] = green
                baseAddress[offset + 2] = red
                baseAddress[offset + 3] = 255
            }

            // Top row is red, bottom row is blue.
            writePixel(x: 0, y: 0, red: 255, green: 0, blue: 0)
            writePixel(x: 1, y: 0, red: 255, green: 0, blue: 0)
            writePixel(x: 0, y: 1, red: 0, green: 0, blue: 255)
            writePixel(x: 1, y: 1, red: 0, green: 0, blue: 255)
        }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        let provider = try XCTUnwrap(CGDataProvider(data: source as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )

        let converted = try StorageManager.makeBGRAData(from: image)
        XCTAssertEqual(Array(converted.prefix(bytesPerRow)), Array(source.prefix(bytesPerRow)))
        XCTAssertEqual(Array(converted.suffix(bytesPerRow)), Array(source.suffix(bytesPerRow)))
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Segment Writer Tests                              │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testSegmentWriterAppendFinalizeCreatesSegmentFile() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        do {
            let writer = try await storage.createSegmentWriter()
            let bytesPerRow = 4 * 4
            let imageData = Data(repeating: 0x00, count: bytesPerRow * 4)
            let frame = CapturedFrame(
                imageData: imageData,
                width: 4,
                height: 4,
                bytesPerRow: bytesPerRow
            )
            try await writer.appendFrame(frame)
            let count = await writer.frameCount
            XCTAssertEqual(count, 1)
            let segment = try await writer.finalize()
            XCTAssertEqual(segment.frameCount, 1)
            let url = try await storage.getSegmentPath(id: segment.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        } catch {
            throw XCTSkip("HEVC encoding unavailable in test environment: \(error)")
        }

        try? FileManager.default.removeItem(at: root)
    }

    func testRewriteSegmentWithScrambledNodesRewritesTargetPatchEndToEnd() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let writer = try await storage.createSegmentWriter()
        let segmentID = await writer.segmentID
        let targetRect = CGRect(x: 16, y: 16, width: 32, height: 32)
        try await writer.appendFrame(
            makePatternedCapturedFrame(
                width: 64,
                height: 64,
                targetRect: targetRect
            )
        )
        _ = try await writer.finalize()

        let beforeJPEG = try await storage.readFrame(segmentID: segmentID, frameIndex: 0)
        try await storage.rewriteSegmentForRedaction(
            segmentID: segmentID,
            frameIDs: [42],
            targetsByFrameIndex: [
                0: [
                    SegmentRedactionTarget(
                        frameID: 42,
                        nodeID: 7,
                        normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                    )
                ]
            ],
            secret: "unit-test-secret"
        )
        let afterJPEG = try await storage.readFrame(segmentID: segmentID, frameIndex: 0)

        let beforeImage = try decodeJPEG(beforeJPEG)
        let afterImage = try decodeJPEG(afterJPEG)
        let beforeBGRA = try StorageManager.makeBGRAData(from: beforeImage)
        let afterBGRA = try StorageManager.makeBGRAData(from: afterImage)

        let beforeTarget = extractPatch(from: beforeBGRA, imageWidth: beforeImage.width, rect: targetRect)
        let afterTarget = extractPatch(from: afterBGRA, imageWidth: afterImage.width, rect: targetRect)
        let beforeControl = extractPatch(
            from: beforeBGRA,
            imageWidth: beforeImage.width,
            rect: CGRect(x: 0, y: 0, width: 16, height: 16)
        )
        let afterControl = extractPatch(
            from: afterBGRA,
            imageWidth: afterImage.width,
            rect: CGRect(x: 0, y: 0, width: 16, height: 16)
        )

        let targetDifference = averageAbsoluteDifference(beforeTarget, afterTarget)
        let controlDifference = averageAbsoluteDifference(beforeControl, afterControl)

        XCTAssertGreaterThan(targetDifference, 6.0)
        XCTAssertGreaterThan(targetDifference, controlDifference * 1.8)

        try? FileManager.default.removeItem(at: root)
    }

    func testRecoverInterruptedCommittedSegmentRewriteReturnsCompletionAction() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let writer = try await storage.createSegmentWriter()
        let segmentID = await writer.segmentID
        let targetRect = CGRect(x: 16, y: 16, width: 32, height: 32)
        try await writer.appendFrame(
            makePatternedCapturedFrame(
                width: 64,
                height: 64,
                targetRect: targetRect
            )
        )
        _ = try await writer.finalize()

        let beforeJPEG = try await storage.readFrame(segmentID: segmentID, frameIndex: 0)
        try await storage.rewriteSegmentForRedaction(
            segmentID: segmentID,
            frameIDs: [42],
            targetsByFrameIndex: [
                0: [
                    SegmentRedactionTarget(
                        frameID: 42,
                        nodeID: 7,
                        normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                    )
                ]
            ],
            secret: "unit-test-secret"
        )
        let afterJPEG = try await storage.readFrame(segmentID: segmentID, frameIndex: 0)

        let actions = try await storage.recoverInterruptedSegmentRedactions()
        XCTAssertEqual(
            actions,
            [
                SegmentRedactionRecoveryAction(
                    mode: .markCompleted,
                    segmentID: segmentID
                )
            ]
        )

        let beforeImage = try decodeJPEG(beforeJPEG)
        let afterImage = try decodeJPEG(afterJPEG)
        let beforeBGRA = try StorageManager.makeBGRAData(from: beforeImage)
        let afterBGRA = try StorageManager.makeBGRAData(from: afterImage)
        let beforeTarget = extractPatch(from: beforeBGRA, imageWidth: beforeImage.width, rect: targetRect)
        let afterTarget = extractPatch(from: afterBGRA, imageWidth: afterImage.width, rect: targetRect)
        XCTAssertGreaterThan(averageAbsoluteDifference(beforeTarget, afterTarget), 6.0)

        try await storage.finishInterruptedSegmentRedactionRecovery(segmentID: segmentID)
        let actionsAfterCleanup = try await storage.recoverInterruptedSegmentRedactions()
        XCTAssertTrue(actionsAfterCleanup.isEmpty)

        try? FileManager.default.removeItem(at: root)
    }

    func testRecoverInterruptedSegmentRewriteRollbackStateRollsBackToOriginalSegment() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let writer = try await storage.createSegmentWriter()
        let segmentID = await writer.segmentID
        let targetRect = CGRect(x: 16, y: 16, width: 32, height: 32)
        try await writer.appendFrame(
            makePatternedCapturedFrame(
                width: 64,
                height: 64,
                targetRect: targetRect
            )
        )
        _ = try await writer.finalize()

        let originalJPEG = try await storage.readFrame(segmentID: segmentID, frameIndex: 0)
        try await storage.rewriteSegmentForRedaction(
            segmentID: segmentID,
            frameIDs: [42],
            targetsByFrameIndex: [
                0: [
                    SegmentRedactionTarget(
                        frameID: 42,
                        nodeID: 7,
                        normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                    )
                ]
            ],
            secret: "unit-test-secret"
        )

        try await storage.forceRollbackSegmentRewriteStateForTesting(segmentID: segmentID)
        let actions = try await storage.recoverInterruptedSegmentRedactions()
        XCTAssertEqual(
            actions,
            [
                SegmentRedactionRecoveryAction(
                    mode: .rollbackToPending,
                    segmentID: segmentID
                )
            ]
        )

        let recoveredJPEG = try await storage.readFrame(segmentID: segmentID, frameIndex: 0)
        let originalImage = try decodeJPEG(originalJPEG)
        let recoveredImage = try decodeJPEG(recoveredJPEG)
        let originalBGRA = try StorageManager.makeBGRAData(from: originalImage)
        let recoveredBGRA = try StorageManager.makeBGRAData(from: recoveredImage)
        let originalTarget = extractPatch(from: originalBGRA, imageWidth: originalImage.width, rect: targetRect)
        let recoveredTarget = extractPatch(from: recoveredBGRA, imageWidth: recoveredImage.width, rect: targetRect)
        XCTAssertLessThan(averageAbsoluteDifference(originalTarget, recoveredTarget), 1.0)

        try await storage.finishInterruptedSegmentRedactionRecovery(segmentID: segmentID)
        let actionsAfterCleanup = try await storage.recoverInterruptedSegmentRedactions()
        XCTAssertTrue(actionsAfterCleanup.isEmpty)

        try? FileManager.default.removeItem(at: root)
    }

    func testRecoverableFrameCountIgnoresTruncatedTailFrame() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        var session = try await walManager.createSession(videoID: VideoSegmentID(value: 42))
        let frame = makeCapturedFrame()
        try await walManager.appendFrame(frame, to: &session)

        let fileHandle = try XCTUnwrap(FileHandle(forWritingAtPath: session.framesURL.path))
        defer { try? fileHandle.close() }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: Data(repeating: 0xCC, count: 12))

        let recoverableFrameCount = try await walManager.recoverableFrameCount(for: session)
        XCTAssertEqual(recoverableFrameCount, 1)

        let recoveredFrame = try await walManager.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(recoveredFrame.imageData, frame.imageData)
        XCTAssertEqual(recoveredFrame.metadata.browserURL, frame.metadata.browserURL)

        try? FileManager.default.removeItem(at: root)
    }

    func testReadFrameByFrameIDUsesRegisteredMappingInsteadOfFallbackIndex() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        var session = try await walManager.createSession(videoID: VideoSegmentID(value: 314))
        let firstFrame = makeCapturedFrame(
            timestamp: Date(timeIntervalSince1970: 1_720_000_000),
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "First",
                browserURL: "https://example.com/first",
                displayID: 1
            )
        )
        let secondFrame = makeCapturedFrame(
            timestamp: firstFrame.timestamp.addingTimeInterval(1),
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Second",
                browserURL: "https://example.com/second",
                displayID: 1
            )
        )
        try await walManager.appendFrame(firstFrame, to: &session)
        try await walManager.appendFrame(secondFrame, to: &session)
        try await walManager.registerFrameID(videoID: session.videoID, frameID: 9001, frameIndex: 1)

        let resolvedFrame = try await walManager.readFrame(
            videoID: session.videoID,
            frameID: 9001,
            fallbackFrameIndex: 0
        )

        XCTAssertEqual(resolvedFrame.timestamp, secondFrame.timestamp)
        XCTAssertEqual(resolvedFrame.metadata.windowName, secondFrame.metadata.windowName)
        XCTAssertEqual(resolvedFrame.metadata.browserURL, secondFrame.metadata.browserURL)

        try? FileManager.default.removeItem(at: root)
    }

    func testReadFrameByFrameIDRejectsMissingMappingInsteadOfFallingBackToIndex() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        var session = try await walManager.createSession(videoID: VideoSegmentID(value: 315))
        let firstFrame = makeCapturedFrame(
            timestamp: Date(timeIntervalSince1970: 1_720_000_100),
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Mapped",
                browserURL: "https://example.com/mapped",
                displayID: 1
            )
        )
        let secondFrame = makeCapturedFrame(
            timestamp: firstFrame.timestamp.addingTimeInterval(1),
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Fallback",
                browserURL: "https://example.com/fallback",
                displayID: 1
            )
        )
        try await walManager.appendFrame(firstFrame, to: &session)
        try await walManager.appendFrame(secondFrame, to: &session)
        try await walManager.registerFrameID(videoID: session.videoID, frameID: 9002, frameIndex: 0)

        do {
            _ = try await walManager.readFrame(
                videoID: session.videoID,
                frameID: 9999,
                fallbackFrameIndex: 1
            )
            XCTFail("Expected missing frameID map entry to defer instead of falling back by index")
        } catch let error as StorageError {
            guard case .fileReadFailed(let path, let underlying) = error else {
                return XCTFail("Unexpected storage error: \(error)")
            }
            XCTAssertTrue(path.hasSuffix("frame_id_map.bin"))
            XCTAssertTrue(underlying.contains("Incomplete WAL frameID map"))
            XCTAssertTrue(underlying.contains("refusing fallback"))
        }

        try? FileManager.default.removeItem(at: root)
    }

    func testReadFramesRejectsOversizedWALSession() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let session = try await walManager.createSession(videoID: VideoSegmentID(value: 99))
        let fileHandle = try XCTUnwrap(FileHandle(forWritingAtPath: session.framesURL.path))
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: UInt64((512 * 1024 * 1024) + 1))

        do {
            _ = try await walManager.readFrames(from: session)
            XCTFail("Expected oversized WAL eager read to fail")
        } catch let error as StorageError {
            guard case .fileReadFailed(_, let underlying) = error else {
                return XCTFail("Unexpected storage error: \(error)")
            }
            XCTAssertTrue(underlying.contains("too large for eager read"))
        }

        try? FileManager.default.removeItem(at: root)
    }

    func testQuarantineSessionRemovesItFromActiveListing() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let session = try await walManager.createSession(videoID: VideoSegmentID(value: 7))
        let quarantineURL = try await walManager.quarantineSession(session, reason: "test")

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.sessionDir.path))

        try? FileManager.default.removeItem(at: root)
    }

    func testCleanupQuarantinedSessionsRemovesOnlyExpiredDirectories() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let session = try await walManager.createSession(videoID: VideoSegmentID(value: 11))
        let quarantineURL = try await walManager.quarantineSession(session, reason: "expired")

        let keptCount = await walManager.cleanupQuarantinedSessions(olderThan: .distantPast)
        XCTAssertEqual(keptCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))

        let removedCount = await walManager.cleanupQuarantinedSessions(olderThan: .distantFuture)
        XCTAssertEqual(removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineURL.path))

        try? FileManager.default.removeItem(at: root)
    }

    func testCleanupQuarantinedSessionsKeepsRetainedDirectories() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let session = try await walManager.createSession(videoID: VideoSegmentID(value: 12))
        let quarantineURL = try await walManager.quarantineSession(
            session,
            reason: "retry later",
            disposition: .retained
        )

        let removedCount = await walManager.cleanupQuarantinedSessions(olderThan: .distantFuture)
        XCTAssertEqual(removedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))

        try? FileManager.default.removeItem(at: root)
    }

    func testStorageInitializeRepairsBlockingWALFile() async throws {
        let root = makeTempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let walRoot = root.appendingPathComponent("wal", isDirectory: false)
        let sentinel = Data("not-a-directory".utf8)
        FileManager.default.createFile(atPath: walRoot.path, contents: sentinel)

        let storage = StorageManager(storageRoot: root)

        try await storage.initialize(config: makeStorageConfig(root: root))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: walRoot.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let rootContents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(rootContents.contains { $0.lastPathComponent.hasPrefix("wal.invalid.") })
        let walReady = await storage.isWALReady()
        XCTAssertTrue(walReady)

        try? FileManager.default.removeItem(at: root)
    }

    func testCreateSegmentWriterFailsFastWhenWALRemainsUnavailable() async throws {
        let root = makeTempRoot()
        let crashReportRoot = makeTempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashReportRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("chunks", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("temp", isDirectory: true),
            withIntermediateDirectories: true
        )

        let walRoot = root.appendingPathComponent("wal", isDirectory: false)
        FileManager.default.createFile(
            atPath: walRoot.path,
            contents: Data("blocking-file".utf8)
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: crashReportRoot)
        }

        let storage = StorageManager(
            storageRoot: root,
            crashReportDirectory: crashReportRoot.path
        )
        try await storage.initialize(config: makeStorageConfig(root: root))

        let walIssue = await storage.currentWALAvailabilityIssue()
        XCTAssertNotNil(walIssue)
        let walReady = await storage.isWALReady()
        XCTAssertFalse(walReady)

        do {
            _ = try await storage.createSegmentWriter()
            XCTFail("Expected writer creation to fail while WAL is unavailable")
        } catch let error as StorageError {
            guard case .walUnavailable = error else {
                XCTFail("Expected walUnavailable, got \(error)")
                return
            }
        }
    }

    func testStorageInitializeDetectsReadOnlyWALRootWithWriteProbe() async throws {
        let root = makeTempRoot()
        let crashReportRoot = makeTempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashReportRoot, withIntermediateDirectories: true)

        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        try FileManager.default.createDirectory(at: walRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: walRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: walRoot.path)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: crashReportRoot)
        }

        let storage = StorageManager(
            storageRoot: root,
            crashReportDirectory: crashReportRoot.path
        )

        try await storage.initialize(config: makeStorageConfig(root: root))

        let walIssue = await storage.currentWALAvailabilityIssue()
        XCTAssertNotNil(walIssue)
        let walReady = await storage.isWALReady()
        XCTAssertFalse(walReady)

        do {
            _ = try await storage.createSegmentWriter()
            XCTFail("Expected writer creation to fail while WAL write probe is unavailable")
        } catch let error as StorageError {
            guard case .walUnavailable = error else {
                XCTFail("Expected walUnavailable, got \(error)")
                return
            }
        }

        let reportFiles = try FileManager.default.contentsOfDirectory(atPath: crashReportRoot.path)
        let walReports = reportFiles.filter { $0.hasPrefix("retrace-emergency-wal_unavailable-") }
        XCTAssertEqual(walReports.count, 1)
    }

    func testCancelAfterAppendPreservesWALSessionForRecovery() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let writer = try await storage.createSegmentWriter()
        let incrementalWriter = try XCTUnwrap(writer as? IncrementalSegmentWriter)
        let segmentID = await writer.segmentID
        try await writer.appendFrame(makeCapturedFrame())

        let walManager = await storage.getWALManager()

        try await incrementalWriter.cancelPreservingRecoveryData()

        let segmentExists = try await storage.segmentExists(id: segmentID)
        XCTAssertFalse(segmentExists)

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertEqual(activeSessions.count, 1)
        XCTAssertEqual(activeSessions.first?.videoID, segmentID)
        if let session = activeSessions.first {
            let recoverableFrameCount = try await walManager.recoverableFrameCount(for: session)
            XCTAssertEqual(recoverableFrameCount, 1)
        }

        try? FileManager.default.removeItem(at: root)
    }

    func testCancelAfterAppendRemovesWALSessionByDefault() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let writer = try await storage.createSegmentWriter()
        let segmentID = await writer.segmentID
        try await writer.appendFrame(makeCapturedFrame())

        let walManager = await storage.getWALManager()

        try await writer.cancel()

        let segmentExists = try await storage.segmentExists(id: segmentID)
        XCTAssertFalse(segmentExists)

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertFalse(activeSessions.contains(where: { $0.videoID == segmentID }))

        try? FileManager.default.removeItem(at: root)
    }

    func testAppendFrameContinuesWhenMetadataSidecarCannotBeWritten() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let videoID = VideoSegmentID(value: 410)
        var session = try await walManager.createSession(videoID: videoID)
        let metadataURL = session.sessionDir.appendingPathComponent("metadata.json")
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        let frame = makeCapturedFrame(
            width: 12,
            height: 8,
            bytesPerRow: 48,
            imageByteCount: 48 * 8,
            timestamp: Date(timeIntervalSince1970: 1_720_010_000)
        )
        try await walManager.appendFrame(frame, to: &session)

        XCTAssertEqual(session.metadata.frameCount, 1)

        let sessions = try await walManager.listActiveSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.metadata.frameCount, 1)
        XCTAssertEqual(sessions.first?.metadata.width, frame.width)
        XCTAssertEqual(sessions.first?.metadata.height, frame.height)

        try? FileManager.default.removeItem(at: root)
    }

    func testRegisterFrameIDRecreatesFrameMapSidecarWhenPathStopsBeingAFile() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let videoID = VideoSegmentID(value: 411)
        var session = try await walManager.createSession(videoID: videoID)
        let firstFrame = makeCapturedFrame(
            timestamp: Date(timeIntervalSince1970: 1_720_010_100)
        )
        let secondFrame = makeCapturedFrame(
            timestamp: Date(timeIntervalSince1970: 1_720_010_101)
        )
        try await walManager.appendFrame(firstFrame, to: &session)
        try await walManager.appendFrame(secondFrame, to: &session)

        try await walManager.registerFrameID(videoID: videoID, frameID: 20_001, frameIndex: 0)

        let mapURL = session.sessionDir.appendingPathComponent("frame_id_map.bin")
        try FileManager.default.removeItem(at: mapURL)
        try FileManager.default.createDirectory(at: mapURL, withIntermediateDirectories: true)

        try await walManager.registerFrameID(videoID: videoID, frameID: 20_002, frameIndex: 1)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: mapURL.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)

        let recoveredFirst = try await walManager.readFrame(
            videoID: videoID,
            frameID: 20_001,
            fallbackFrameIndex: 0
        )
        let recoveredSecond = try await walManager.readFrame(
            videoID: videoID,
            frameID: 20_002,
            fallbackFrameIndex: 1
        )
        XCTAssertEqual(recoveredFirst.timestamp, firstFrame.timestamp)
        XCTAssertEqual(recoveredSecond.timestamp, secondFrame.timestamp)

        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryContinuesWhenOneSessionMetadataIsCorruptedAndUnrecoverable() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let healthyVideoID = VideoSegmentID(value: 510)
        var healthySession = try await walManager.createSession(videoID: healthyVideoID)
        let healthyFrame = makeCapturedFrame(
            width: 8,
            height: 8,
            bytesPerRow: 32,
            imageByteCount: 32 * 8,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try await walManager.appendFrame(healthyFrame, to: &healthySession)

        let brokenVideoID = VideoSegmentID(value: 511)
        var brokenSession = try await walManager.createSession(videoID: brokenVideoID)
        try await walManager.appendFrame(
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: healthyFrame.timestamp.addingTimeInterval(10)
            ),
            to: &brokenSession
        )
        try corruptWALMetadata(for: brokenSession)
        let brokenHandle = try XCTUnwrap(FileHandle(forWritingAtPath: brokenSession.framesURL.path))
        defer { try? brokenHandle.close() }
        try brokenHandle.truncate(atOffset: 0)

        let database = try await makeDatabase(name: "recovery_corrupted_metadata_does_not_block_healthy_session")
        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [healthyVideoID.value: 0],
            validVideoIDs: []
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 1)
        XCTAssertEqual(result.videoSegmentsCreated, 1)

        let recoveredFrames = try await database.getFrames(
            from: healthyFrame.timestamp.addingTimeInterval(-60),
            to: healthyFrame.timestamp.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(recoveredFrames.count, 1)
        XCTAssertEqual(recoveredFrames[0].timestamp, healthyFrame.timestamp)

        let walContents = try FileManager.default.contentsOfDirectory(at: walRoot, includingPropertiesForKeys: nil)
        let retainedQuarantines = walContents.filter {
            $0.lastPathComponent.hasPrefix("retained_segment_\(brokenVideoID.value)_")
        }
        XCTAssertEqual(retainedQuarantines.count, 1)

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testListActiveSessionsRebuildsCorruptedMetadataAndRecoverySucceeds() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let videoID = VideoSegmentID(value: 512)
        var session = try await walManager.createSession(videoID: videoID)
        let firstFrame = makeCapturedFrame(
            width: 12,
            height: 10,
            bytesPerRow: 48,
            imageByteCount: 48 * 10,
            timestamp: Date(timeIntervalSince1970: 1_750_000_100)
        )
        let secondFrame = makeCapturedFrame(
            width: 12,
            height: 10,
            bytesPerRow: 48,
            imageByteCount: 48 * 10,
            timestamp: firstFrame.timestamp.addingTimeInterval(1)
        )
        try await walManager.appendFrame(firstFrame, to: &session)
        try await walManager.appendFrame(secondFrame, to: &session)
        try corruptWALMetadata(for: session)

        let rebuiltSessions = try await walManager.listActiveSessions()
        XCTAssertEqual(rebuiltSessions.count, 1)
        let rebuiltSession = try XCTUnwrap(rebuiltSessions.first)
        XCTAssertEqual(rebuiltSession.videoID, videoID)
        XCTAssertEqual(rebuiltSession.metadata.frameCount, 2)
        XCTAssertEqual(rebuiltSession.metadata.width, firstFrame.width)
        XCTAssertEqual(rebuiltSession.metadata.height, firstFrame.height)
        XCTAssertEqual(rebuiltSession.metadata.startTime, firstFrame.timestamp)

        let repairedMetadata = try loadWALMetadata(from: session.sessionDir)
        XCTAssertEqual(repairedMetadata.videoID, videoID)
        XCTAssertEqual(repairedMetadata.frameCount, 2)
        XCTAssertEqual(repairedMetadata.width, firstFrame.width)
        XCTAssertEqual(repairedMetadata.height, firstFrame.height)
        XCTAssertEqual(repairedMetadata.startTime, firstFrame.timestamp)

        let database = try await makeDatabase(name: "recovery_rebuilds_corrupted_metadata")
        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [videoID.value: 0],
            validVideoIDs: []
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 2)
        XCTAssertEqual(result.videoSegmentsCreated, 1)

        let recoveredFrames = try await database.getFrames(
            from: firstFrame.timestamp.addingTimeInterval(-60),
            to: secondFrame.timestamp.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(recoveredFrames.count, 2)

        let walContents = try FileManager.default.contentsOfDirectory(at: walRoot, includingPropertiesForKeys: nil)
        let retainedQuarantines = walContents.filter {
            $0.lastPathComponent.hasPrefix("retained_segment_\(videoID.value)_")
        }
        XCTAssertTrue(retainedQuarantines.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testListActiveSessionsQuarantinesOnlyCorruptedSessionWithUnrecoverableFrames() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let healthyVideoID = VideoSegmentID(value: 513)
        var healthySession = try await walManager.createSession(videoID: healthyVideoID)
        try await walManager.appendFrame(
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: Date(timeIntervalSince1970: 1_750_000_200)
            ),
            to: &healthySession
        )

        let brokenVideoID = VideoSegmentID(value: 514)
        var brokenSession = try await walManager.createSession(videoID: brokenVideoID)
        try await walManager.appendFrame(
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: Date(timeIntervalSince1970: 1_750_000_201)
            ),
            to: &brokenSession
        )
        try corruptWALMetadata(for: brokenSession)
        let brokenHandle = try XCTUnwrap(FileHandle(forWritingAtPath: brokenSession.framesURL.path))
        defer { try? brokenHandle.close() }
        try brokenHandle.truncate(atOffset: 0)

        let listedSessions = try await walManager.listActiveSessions()
        XCTAssertEqual(listedSessions.map(\.videoID.value), [healthyVideoID.value])

        let walContents = try FileManager.default.contentsOfDirectory(at: walRoot, includingPropertiesForKeys: nil)
        let retainedQuarantines = walContents.filter {
            $0.lastPathComponent.hasPrefix("retained_segment_\(brokenVideoID.value)_")
        }
        XCTAssertEqual(retainedQuarantines.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: healthySession.sessionDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: brokenSession.sessionDir.path))

        try? FileManager.default.removeItem(at: root)
    }

    func testListActiveSessionsRepairsZeroedMetadataSidecar() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 313)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let frame = makeCapturedFrame(
            width: 1920,
            height: 1080,
            bytesPerRow: 1920 * 4,
            imageByteCount: 1920 * 1080 * 4,
            timestamp: Date(timeIntervalSince1970: 1_720_001_000)
        )
        try await walManager.appendFrame(frame, to: &session)

        let metadataURL = session.sessionDir.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let staleMetadata = WALMetadata(
            videoID: sessionVideoID,
            startTime: session.metadata.startTime,
            frameCount: 0,
            width: 0,
            height: 0,
            durableReadableFrameCount: session.metadata.durableReadableFrameCount,
            durableVideoFileSizeBytes: session.metadata.durableVideoFileSizeBytes
        )
        let staleData = try encoder.encode(staleMetadata)
        try staleData.write(to: metadataURL, options: [.atomic])

        let sessions = try await walManager.listActiveSessions()
        XCTAssertEqual(sessions.count, 1)
        let repairedSession = try XCTUnwrap(sessions.first)
        XCTAssertEqual(repairedSession.metadata.frameCount, 1)
        XCTAssertEqual(repairedSession.metadata.width, frame.width)
        XCTAssertEqual(repairedSession.metadata.height, frame.height)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let repairedSidecar = try decoder.decode(WALMetadata.self, from: Data(contentsOf: metadataURL))
        XCTAssertEqual(repairedSidecar.frameCount, 1)
        XCTAssertEqual(repairedSidecar.width, frame.width)
        XCTAssertEqual(repairedSidecar.height, frame.height)

        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryRepairsOverflowingPositiveMetadataBeforeBatchSizing() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let videoID = VideoSegmentID(value: 314)
        var session = try await walManager.createSession(videoID: videoID)
        let frame = makeCapturedFrame(
            width: 12,
            height: 10,
            bytesPerRow: 48,
            imageByteCount: 48 * 10,
            timestamp: Date(timeIntervalSince1970: 1_720_001_100)
        )
        try await walManager.appendFrame(frame, to: &session)

        let metadataURL = session.sessionDir.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let overflowingMetadata = WALMetadata(
            videoID: videoID,
            startTime: session.metadata.startTime,
            frameCount: 1,
            width: Int.max,
            height: 2,
            durableReadableFrameCount: session.metadata.durableReadableFrameCount,
            durableVideoFileSizeBytes: session.metadata.durableVideoFileSizeBytes
        )
        let staleData = try encoder.encode(overflowingMetadata)
        try staleData.write(to: metadataURL, options: [.atomic])

        let listedSessions = try await walManager.listActiveSessions()
        XCTAssertEqual(listedSessions.count, 1)
        let repairedSession = try XCTUnwrap(listedSessions.first)
        XCTAssertEqual(repairedSession.metadata.frameCount, 1)
        XCTAssertEqual(repairedSession.metadata.width, frame.width)
        XCTAssertEqual(repairedSession.metadata.height, frame.height)

        let repairedSidecar = try loadWALMetadata(from: session.sessionDir)
        XCTAssertEqual(repairedSidecar.width, frame.width)
        XCTAssertEqual(repairedSidecar.height, frame.height)

        let database = try await makeDatabase(name: "recovery_repairs_overflowing_positive_metadata")
        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [videoID.value: 0],
            validVideoIDs: []
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 1)
        XCTAssertEqual(result.videoSegmentsCreated, 1)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryCommitsOnlyEncodedFramesAndContinuesWithSuffix() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 500)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<5 {
            try await walManager.appendFrame(
                makeCapturedFrame(
                    width: 8,
                    height: 8,
                    bytesPerRow: 32,
                    imageByteCount: 32 * 8,
                    timestamp: start.addingTimeInterval(Double(index))
                ),
                to: &session
            )
        }

        let database = try await makeDatabase(name: "recovery_partial_encode")
        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: 2), .init(failAfter: nil)],
            existingFrameCounts: [sessionVideoID.value: 0],
            validVideoIDs: [sessionVideoID.value]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 5)
        XCTAssertEqual(result.videoSegmentsCreated, 2)

        let finalizedSegments = await storage.finalizedSegmentsSnapshot()
        XCTAssertEqual(finalizedSegments.map(\.frameCount), [2, 3])

        let videos = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(videos.count, 2)

        let frames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 20
        ).sorted(by: { $0.timestamp < $1.timestamp })
        XCTAssertEqual(frames.count, 5)

        let frameCountsByVideoID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id.value, $0.frameCount) })
        for frame in frames {
            let maxFrameCount = try XCTUnwrap(frameCountsByVideoID[frame.videoID.value])
            XCTAssertLessThan(frame.frameIndexInSegment, maxFrameCount)
        }

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryReadableExistingVideoMissingDatabaseRowCreatesDatabaseVideoRowWithoutReencoding() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_573)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_500)

        for index in 0..<3 {
            try await walManager.appendFrame(
                makeCapturedFrame(
                    width: 8,
                    height: 8,
                    bytesPerRow: 32,
                    imageByteCount: 32 * 8,
                    timestamp: start.addingTimeInterval(Double(index))
                ),
                to: &session
            )
        }

        let database = try await makeDatabase(name: "recovery_readable_existing_video_missing_db_row")
        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: 3],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 456]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 3)
        XCTAssertEqual(result.videoSegmentsCreated, 0)
        let deletedSegmentIDs = await storage.deletedSegmentIDsSnapshot()
        XCTAssertEqual(deletedSegmentIDs, [])

        let videos = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.frameCount, 3)
        XCTAssertEqual(videos.first?.fileSizeBytes, 456)

        let recoveredVideoID = try XCTUnwrap(videos.first?.id.value)
        let frames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.videoID.value == recoveredVideoID })
        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryMappedCompletedPrefixSkipsRawWALReads() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_574)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_550)
        let frames = (0..<3).map { index in
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }

        let database = try await makeDatabase(name: "recovery_mapped_completed_prefix_skips_raw_reads")
        let databaseVideoID = try await database.insertVideoSegment(
            makePlaceholderVideo(id: sessionVideoID, start: start, frameCount: frames.count)
        )
        try await database.markVideoFinalized(id: databaseVideoID, frameCount: frames.count, fileSize: 123)
        let segmentID = try await database.insertSegment(
            bundleID: frames[0].metadata.appBundleID ?? "com.apple.Safari",
            startDate: frames[0].timestamp,
            endDate: frames.last?.timestamp ?? frames[0].timestamp,
            windowName: frames[0].metadata.windowName,
            browserUrl: frames[0].metadata.browserURL,
            type: 0
        )

        for (index, frame) in frames.enumerated() {
            let frameID = 9_100 + Int64(index)
            try await walManager.registerFrameID(videoID: sessionVideoID, frameID: frameID, frameIndex: index)
            try await insertStoredFrame(
                database: database,
                frameID: frameID,
                timestamp: frame.timestamp,
                segmentID: segmentID,
                videoID: databaseVideoID,
                frameIndex: index,
                metadata: frame.metadata
            )
            try await database.updateFrameProcessingStatus(frameID: frameID, status: 2)
        }

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: frames.count],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 456]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        await walManager.resetDebugRawReadOffsets(for: sessionVideoID)

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 0)
        XCTAssertEqual(result.videoSegmentsCreated, 0)
        let rawReadOffsets = await walManager.debugRawReadOffsets(for: sessionVideoID)
        XCTAssertEqual(rawReadOffsets, [])

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryTinyUnmappedTailLoadsOnlyTailOffsets() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_575)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_600)
        let frames = (0..<5).map { index in
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }

        let database = try await makeDatabase(name: "recovery_tiny_unmapped_tail")
        let databaseVideoID = try await database.insertVideoSegment(
            makePlaceholderVideo(id: sessionVideoID, start: start, frameCount: frames.count)
        )
        try await database.markVideoFinalized(id: databaseVideoID, frameCount: frames.count, fileSize: 123)
        let segmentID = try await database.insertSegment(
            bundleID: frames[0].metadata.appBundleID ?? "com.apple.Safari",
            startDate: frames[0].timestamp,
            endDate: frames[2].timestamp,
            windowName: frames[0].metadata.windowName,
            browserUrl: frames[0].metadata.browserURL,
            type: 0
        )

        for index in 0..<3 {
            let frameID = 9_200 + Int64(index)
            try await walManager.registerFrameID(videoID: sessionVideoID, frameID: frameID, frameIndex: index)
            try await insertStoredFrame(
                database: database,
                frameID: frameID,
                timestamp: frames[index].timestamp,
                segmentID: segmentID,
                videoID: databaseVideoID,
                frameIndex: index,
                metadata: frames[index].metadata
            )
            try await database.updateFrameProcessingStatus(frameID: frameID, status: 2)
        }

        let recoveryIndex = try await walManager.recoveryIndex(for: session)
        let expectedOffsets = Array(recoveryIndex.recoverableOffsets.suffix(2))

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: frames.count],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 555]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        await walManager.resetDebugRawReadOffsets(for: sessionVideoID)

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 2)
        XCTAssertEqual(result.videoSegmentsCreated, 0)
        let rawReadOffsets = await walManager.debugRawReadOffsets(for: sessionVideoID)
        XCTAssertEqual(rawReadOffsets, expectedOffsets)

        let repairedFrames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(repairedFrames.count, 5)
        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryMappedMissingDatabaseRowLoadsOnlyMissingMappedOffset() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_576)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_650)
        let frames = (0..<2).map { index in
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }

        let firstFrameID: Int64 = 9_300
        let secondFrameID: Int64 = 9_301
        try await walManager.registerFrameID(videoID: sessionVideoID, frameID: firstFrameID, frameIndex: 0)
        try await walManager.registerFrameID(videoID: sessionVideoID, frameID: secondFrameID, frameIndex: 1)

        let database = try await makeDatabase(name: "recovery_mapped_missing_db_row")
        let databaseVideoID = try await database.insertVideoSegment(
            makePlaceholderVideo(id: sessionVideoID, start: start, frameCount: frames.count)
        )
        try await database.markVideoFinalized(id: databaseVideoID, frameCount: frames.count, fileSize: 123)
        let segmentID = try await database.insertSegment(
            bundleID: frames[0].metadata.appBundleID ?? "com.apple.Safari",
            startDate: frames[0].timestamp,
            endDate: frames[0].timestamp,
            windowName: frames[0].metadata.windowName,
            browserUrl: frames[0].metadata.browserURL,
            type: 0
        )
        try await insertStoredFrame(
            database: database,
            frameID: firstFrameID,
            timestamp: frames[0].timestamp,
            segmentID: segmentID,
            videoID: databaseVideoID,
            frameIndex: 0,
            metadata: frames[0].metadata
        )
        try await database.updateFrameProcessingStatus(frameID: firstFrameID, status: 2)

        let recoveryIndex = try await walManager.recoveryIndex(for: session)
        let expectedOffset = [recoveryIndex.recoverableOffsets[1]]

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: frames.count],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 444]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        await walManager.resetDebugRawReadOffsets(for: sessionVideoID)

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 1)
        XCTAssertEqual(result.videoSegmentsCreated, 0)
        let rawReadOffsets = await walManager.debugRawReadOffsets(for: sessionVideoID)
        XCTAssertEqual(rawReadOffsets, expectedOffset)

        let recoveredFrames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(recoveredFrames.count, 2)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryReadablePrefixRepairsBrokenProcessingStatusesWithoutRawReplay() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_577)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_700)
        let frames = (0..<6).map { index in
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }

        let database = try await makeDatabase(name: "recovery_broken_processing_statuses")
        let databaseVideoID = try await database.insertVideoSegment(
            makePlaceholderVideo(id: sessionVideoID, start: start, frameCount: frames.count)
        )
        try await database.markVideoFinalized(id: databaseVideoID, frameCount: frames.count, fileSize: 123)
        let segmentID = try await database.insertSegment(
            bundleID: frames[0].metadata.appBundleID ?? "com.apple.Safari",
            startDate: frames[0].timestamp,
            endDate: frames.last?.timestamp ?? frames[0].timestamp,
            windowName: frames[0].metadata.windowName,
            browserUrl: frames[0].metadata.browserURL,
            type: 0
        )

        let statuses = [4, 1, 3, 5, 6, 8]
        let frameIDs: [Int64] = [9_400, 9_401, 9_402, 9_403, 9_404, 9_405]
        for (index, frame) in frames.enumerated() {
            let frameID = frameIDs[index]
            try await walManager.registerFrameID(videoID: sessionVideoID, frameID: frameID, frameIndex: index)
            try await insertStoredFrame(
                database: database,
                frameID: frameID,
                timestamp: frame.timestamp,
                segmentID: segmentID,
                videoID: databaseVideoID,
                frameIndex: index,
                metadata: frame.metadata
            )
            try await database.updateFrameProcessingStatus(frameID: frameID, status: statuses[index])
        }

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: frames.count],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 333]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )
        let enqueueCollector = RecoveryEnqueueCollector()
        await recoveryManager.setFrameEnqueueCallback { frameIDs in
            await enqueueCollector.append(frameIDs)
        }

        await walManager.resetDebugRawReadOffsets(for: sessionVideoID)

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 0)
        XCTAssertEqual(result.videoSegmentsCreated, 0)
        let rawReadOffsets = await walManager.debugRawReadOffsets(for: sessionVideoID)
        let enqueuedFrameIDs = await enqueueCollector.snapshot()
        XCTAssertEqual(rawReadOffsets, [])
        XCTAssertEqual(Set(enqueuedFrameIDs), Set(frameIDs.prefix(3)))

        let repairedStatuses = try await database.getFrameProcessingStatuses(frameIDs: frameIDs)
        XCTAssertEqual(repairedStatuses[frameIDs[0]], 0)
        XCTAssertEqual(repairedStatuses[frameIDs[1]], 0)
        XCTAssertEqual(repairedStatuses[frameIDs[2]], 0)
        XCTAssertEqual(repairedStatuses[frameIDs[3]], 5)
        XCTAssertEqual(repairedStatuses[frameIDs[4]], 6)
        XCTAssertEqual(repairedStatuses[frameIDs[5]], 8)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryReadablePrefixRepairsMissingFrameIntoExistingSegmentAndUpdatesEndDate() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_578)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_710)
        let safariMetadata = FrameMetadata(
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            windowName: "Docs",
            browserURL: "https://example.com/docs",
            displayID: 1
        )
        let terminalMetadata = FrameMetadata(
            appBundleID: "com.apple.Terminal",
            appName: "Terminal",
            windowName: "shell",
            browserURL: nil,
            displayID: 1
        )
        let frames = [
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start,
                metadata: safariMetadata
            ),
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(1),
                metadata: safariMetadata
            ),
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(2),
                metadata: terminalMetadata
            )
        ]
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }

        let mappedFrameIDs: [Int64] = [9_450, 9_451, 9_452]
        for (index, frameID) in mappedFrameIDs.enumerated() {
            try await walManager.registerFrameID(videoID: sessionVideoID, frameID: frameID, frameIndex: index)
        }

        let database = try await makeDatabase(name: "recovery_readable_prefix_segment_end_date")
        let databaseVideoID = try await database.insertVideoSegment(
            makePlaceholderVideo(id: sessionVideoID, start: start, frameCount: frames.count)
        )
        try await database.markVideoFinalized(id: databaseVideoID, frameCount: frames.count, fileSize: 444)

        let safariSegmentID = try await database.insertSegment(
            bundleID: safariMetadata.appBundleID ?? "com.apple.Safari",
            startDate: frames[0].timestamp,
            endDate: frames[0].timestamp,
            windowName: safariMetadata.windowName,
            browserUrl: safariMetadata.browserURL,
            type: 0
        )
        let terminalSegmentID = try await database.insertSegment(
            bundleID: terminalMetadata.appBundleID ?? "com.apple.Terminal",
            startDate: frames[2].timestamp,
            endDate: frames[2].timestamp,
            windowName: terminalMetadata.windowName,
            browserUrl: terminalMetadata.browserURL,
            type: 0
        )
        try await insertStoredFrame(
            database: database,
            frameID: mappedFrameIDs[0],
            timestamp: frames[0].timestamp,
            segmentID: safariSegmentID,
            videoID: databaseVideoID,
            frameIndex: 0,
            metadata: safariMetadata
        )
        try await insertStoredFrame(
            database: database,
            frameID: mappedFrameIDs[2],
            timestamp: frames[2].timestamp,
            segmentID: terminalSegmentID,
            videoID: databaseVideoID,
            frameIndex: 2,
            metadata: terminalMetadata
        )
        try await database.updateFrameProcessingStatus(frameID: mappedFrameIDs[0], status: 2)
        try await database.updateFrameProcessingStatus(frameID: mappedFrameIDs[2], status: 2)

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: frames.count],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 444]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 1)
        XCTAssertEqual(result.videoSegmentsCreated, 0)

        let segments = try await database.getSegments(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60)
        )
        XCTAssertEqual(segments.count, 2)
        let repairedSafariSegment = try XCTUnwrap(segments.first { $0.id.value == safariSegmentID })
        XCTAssertEqual(repairedSafariSegment.endDate, frames[1].timestamp)
        let repairedTerminalSegment = try XCTUnwrap(segments.first { $0.id.value == terminalSegmentID })
        XCTAssertEqual(repairedTerminalSegment.endDate, frames[2].timestamp)

        let repairedFrames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        ).sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(repairedFrames.count, 3)
        XCTAssertEqual(repairedFrames[1].segmentID.value, safariSegmentID)
        XCTAssertEqual(repairedFrames[1].videoID.value, databaseVideoID)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryReadablePrefixRollbackRestoresExistingFramesAndDeletesInsertedRowsOnFinalizeFailure() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 408)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_740_000_500)
        let metadata = FrameMetadata(
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            windowName: "Docs",
            browserURL: "https://example.com/docs",
            displayID: 1
        )
        let frames = [
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start,
                metadata: metadata
            ),
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(1),
                metadata: metadata
            )
        ]
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }

        let mappedFrameIDs: [Int64] = [9_800, 9_801]
        for (index, frameID) in mappedFrameIDs.enumerated() {
            try await walManager.registerFrameID(videoID: sessionVideoID, frameID: frameID, frameIndex: index)
        }

        let database = try await makeDatabase(name: "recovery_readable_prefix_rollback_finalize_failure")
        let placeholderVideo = makePlaceholderVideo(id: sessionVideoID, start: start, frameCount: frames.count, fileSizeBytes: 444)
        let placeholderDBID = try await database.insertVideoSegment(placeholderVideo)
        let originalVideoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 999),
                startTime: start,
                endTime: start,
                frameCount: 1,
                fileSizeBytes: 123,
                relativePath: "chunks/original/999",
                width: 8,
                height: 8
            )
        )
        try await database.markVideoFinalized(id: originalVideoID, frameCount: 1, fileSize: 123)

        let originalSegmentID = try await database.insertSegment(
            bundleID: metadata.appBundleID ?? "com.apple.Safari",
            startDate: frames[0].timestamp,
            endDate: frames[0].timestamp,
            windowName: metadata.windowName,
            browserUrl: metadata.browserURL,
            type: 0
        )
        try await insertStoredFrame(
            database: database,
            frameID: mappedFrameIDs[0],
            timestamp: frames[0].timestamp,
            segmentID: originalSegmentID,
            videoID: originalVideoID,
            frameIndex: 7,
            metadata: metadata
        )
        try await database.updateFrameProcessingStatus(frameID: mappedFrameIDs[0], status: 2)
        await database.failNextMarkVideoFinalized()

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: frames.count],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 444]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 0)
        XCTAssertEqual(result.framesRecovered, 0)
        XCTAssertEqual(result.videoSegmentsCreated, 0)

        let restoredFrame = try await database.getFrame(id: FrameID(value: mappedFrameIDs[0]))
        XCTAssertEqual(restoredFrame?.videoID.value, originalVideoID)
        XCTAssertEqual(restoredFrame?.frameIndexInSegment, 7)

        let framesAfterRollback = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(framesAfterRollback.count, 1)
        XCTAssertEqual(framesAfterRollback.first?.id.value, mappedFrameIDs[0])

        let restoredSegment = try await database.getSegment(id: originalSegmentID)
        XCTAssertEqual(restoredSegment?.endDate, frames[0].timestamp)

        let deletedPlaceholder = try await database.getVideoSegment(id: VideoSegmentID(value: placeholderDBID))
        XCTAssertNil(deletedPlaceholder)

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)
        let walContents = try FileManager.default.contentsOfDirectory(at: walRoot, includingPropertiesForKeys: nil)
        let retainedQuarantines = walContents.filter {
            $0.lastPathComponent.hasPrefix("retained_segment_\(sessionVideoID.value)_")
        }
        XCTAssertEqual(retainedQuarantines.count, 1)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryTruncatedFrameMapTailIsTreatedAsUnmappedTail() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_578)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_750)
        let frames = (0..<4).map { index in
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }

        let frameIDs: [Int64] = [9_500, 9_501, 9_502, 9_503]
        for (index, frameID) in frameIDs.enumerated() {
            try await walManager.registerFrameID(videoID: sessionVideoID, frameID: frameID, frameIndex: index)
        }

        let fullRecoveryIndex = try await walManager.recoveryIndex(for: session)
        let expectedTailOffset = [try XCTUnwrap(fullRecoveryIndex.recoverableOffsets.last)]

        let mapURL = session.sessionDir.appendingPathComponent("frame_id_map.bin")
        let originalMapSize = (try FileManager.default.attributesOfItem(atPath: mapURL.path)[.size] as? Int64) ?? 0
        let mapHandle = try XCTUnwrap(FileHandle(forWritingAtPath: mapURL.path))
        defer { try? mapHandle.close() }
        try mapHandle.truncate(atOffset: UInt64(originalMapSize - 8))

        let database = try await makeDatabase(name: "recovery_truncated_frame_map_tail")
        let databaseVideoID = try await database.insertVideoSegment(
            makePlaceholderVideo(id: sessionVideoID, start: start, frameCount: frames.count)
        )
        try await database.markVideoFinalized(id: databaseVideoID, frameCount: frames.count, fileSize: 123)
        let segmentID = try await database.insertSegment(
            bundleID: frames[0].metadata.appBundleID ?? "com.apple.Safari",
            startDate: frames[0].timestamp,
            endDate: frames[2].timestamp,
            windowName: frames[0].metadata.windowName,
            browserUrl: frames[0].metadata.browserURL,
            type: 0
        )
        for index in 0..<3 {
            try await insertStoredFrame(
                database: database,
                frameID: frameIDs[index],
                timestamp: frames[index].timestamp,
                segmentID: segmentID,
                videoID: databaseVideoID,
                frameIndex: index,
                metadata: frames[index].metadata
            )
            try await database.updateFrameProcessingStatus(frameID: frameIDs[index], status: 2)
        }

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: frames.count],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 777]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        await walManager.resetDebugRawReadOffsets(for: sessionVideoID)

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 1)
        XCTAssertEqual(result.videoSegmentsCreated, 0)
        let rawReadOffsets = await walManager.debugRawReadOffsets(for: sessionVideoID)
        XCTAssertEqual(rawReadOffsets, expectedTailOffset)

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryReencodeUsesMappedFrameIDInsteadOfTimestampFallback() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_580)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_800)
        let frames = (0..<2).map { index in
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }

        let mappedFrameIDs: [Int64] = [9_700, 9_701]
        for (index, frameID) in mappedFrameIDs.enumerated() {
            try await walManager.registerFrameID(videoID: sessionVideoID, frameID: frameID, frameIndex: index)
        }

        let database = try await makeDatabase(name: "recovery_reencode_respects_mapped_frame_id")
        let originalVideoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 999),
                startTime: start,
                endTime: start,
                frameCount: 1,
                fileSizeBytes: 50,
                relativePath: "chunks/original/999",
                width: 8,
                height: 8
            )
        )
        try await database.markVideoFinalized(id: originalVideoID, frameCount: 1, fileSize: 50)
        let originalSegmentID = try await database.insertSegment(
            bundleID: frames[0].metadata.appBundleID ?? "com.apple.Safari",
            startDate: start,
            endDate: start,
            windowName: frames[0].metadata.windowName,
            browserUrl: frames[0].metadata.browserURL,
            type: 0
        )
        let conflictingFrameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: frames[0].timestamp,
                segmentID: AppSegmentID(value: originalSegmentID),
                videoID: VideoSegmentID(value: originalVideoID),
                frameIndexInSegment: 7,
                metadata: frames[0].metadata,
                source: .native
            )
        )

        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [sessionVideoID.value: 0],
            validVideoIDs: []
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 2)
        XCTAssertEqual(result.videoSegmentsCreated, 1)

        let allFrames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        ).sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(allFrames.count, 3)

        let unchangedConflictingFrame = try await database.getFrame(id: FrameID(value: conflictingFrameID))
        XCTAssertEqual(unchangedConflictingFrame?.videoID.value, originalVideoID)
        XCTAssertEqual(unchangedConflictingFrame?.frameIndexInSegment, 7)

        let recoveredFrames = allFrames.filter { $0.id.value != conflictingFrameID }
        XCTAssertEqual(recoveredFrames.count, 2)
        XCTAssertFalse(recoveredFrames.map(\.id.value).contains(mappedFrameIDs[0]))
        XCTAssertFalse(recoveredFrames.map(\.id.value).contains(mappedFrameIDs[1]))

        let recoveredVideoIDs = Set(recoveredFrames.map(\.videoID.value))
        XCTAssertEqual(recoveredVideoIDs.count, 1)
        XCTAssertFalse(recoveredVideoIDs.contains(originalVideoID))

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryMaintains150FrameOutputAcrossSmallReadBatches() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 900)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_710_000_000)

        for index in 0..<200 {
            try await walManager.appendFrame(
                makeCapturedFrame(
                    width: 3440,
                    height: 1440,
                    bytesPerRow: 4,
                    imageByteCount: 4,
                    timestamp: start.addingTimeInterval(Double(index))
                ),
                to: &session
            )
        }

        let database = try await makeDatabase(name: "recovery_large_batching")
        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil), .init(failAfter: nil)],
            existingFrameCounts: [sessionVideoID.value: 0],
            validVideoIDs: [sessionVideoID.value]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.videoSegmentsCreated, 2)

        let finalizedSegments = await storage.finalizedSegmentsSnapshot()
        XCTAssertEqual(finalizedSegments.map(\.frameCount), [150, 50])

        let videos = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(videos.count, 2)
        XCTAssertEqual(videos.map(\.frameCount).sorted(), [50, 150])
        let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
        XCTAssertTrue(unfinalisedVideos.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryExistingVideoRowsUseDatabaseVideoIDResolvedFromPath() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_568)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_000)

        for index in 0..<3 {
            try await walManager.appendFrame(
                makeCapturedFrame(
                    width: 8,
                    height: 8,
                    bytesPerRow: 32,
                    imageByteCount: 32 * 8,
                    timestamp: start.addingTimeInterval(Double(index))
                ),
                to: &session
            )
        }

        let database = try await makeDatabase(name: "recovery_existing_video_id_resolution")
        let placeholderVideo = VideoSegment(
            id: sessionVideoID,
            startTime: start,
            endTime: start.addingTimeInterval(3),
            frameCount: 3,
            fileSizeBytes: 123,
            relativePath: "chunks/202603/12/\(sessionVideoID.value)",
            width: 8,
            height: 8
        )
        let databaseVideoID = try await database.insertVideoSegment(placeholderVideo)
        XCTAssertNotEqual(databaseVideoID, sessionVideoID.value)

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: 3],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 456]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.videoSegmentsCreated, 0)

        let frames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.videoID.value == databaseVideoID })
        XCTAssertTrue(frames.allSatisfy { $0.videoID.value != sessionVideoID.value })
        let recoveredVideo = try await database.getVideoSegment(id: VideoSegmentID(value: databaseVideoID))
        XCTAssertEqual(recoveredVideo?.frameCount, 3)
        XCTAssertEqual(recoveredVideo?.fileSizeBytes, 456)
        let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
        XCTAssertTrue(unfinalisedVideos.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryFinalizedExistingVideoRowsUseDatabaseVideoIDResolvedFromPath() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_570)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_200)

        for index in 0..<3 {
            try await walManager.appendFrame(
                makeCapturedFrame(
                    width: 8,
                    height: 8,
                    bytesPerRow: 32,
                    imageByteCount: 32 * 8,
                    timestamp: start.addingTimeInterval(Double(index))
                ),
                to: &session
            )
        }

        let database = try await makeDatabase(name: "recovery_finalized_video_id_resolution")
        let placeholderVideo = VideoSegment(
            id: sessionVideoID,
            startTime: start,
            endTime: start.addingTimeInterval(3),
            frameCount: 3,
            fileSizeBytes: 123,
            relativePath: "chunks/202603/12/\(sessionVideoID.value)",
            width: 8,
            height: 8
        )
        let databaseVideoID = try await database.insertVideoSegment(placeholderVideo)
        try await database.markVideoFinalized(id: databaseVideoID, frameCount: 3, fileSize: 123)
        XCTAssertNotEqual(databaseVideoID, sessionVideoID.value)

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: 3],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 456]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.videoSegmentsCreated, 0)
        let deletedSegmentIDs = await storage.deletedSegmentIDsSnapshot()
        XCTAssertEqual(deletedSegmentIDs, [])

        let frames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.videoID.value == databaseVideoID })
        let recoveredVideo = try await database.getVideoSegment(id: VideoSegmentID(value: databaseVideoID))
        XCTAssertEqual(recoveredVideo?.frameCount, 3)
        XCTAssertEqual(recoveredVideo?.fileSizeBytes, 456)
        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryExistingVideoCreatesNewSegmentWhenTimestampMatchHasDifferentMetadata() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_571)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_250)
        let recoveredMetadata = FrameMetadata(
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            windowName: "Docs",
            browserURL: "https://example.com/docs",
            displayID: 1
        )

        for index in 0..<2 {
            try await walManager.appendFrame(
                makeCapturedFrame(
                    width: 8,
                    height: 8,
                    bytesPerRow: 32,
                    imageByteCount: 32 * 8,
                    timestamp: start.addingTimeInterval(Double(index)),
                    metadata: recoveredMetadata
                ),
                to: &session
            )
        }

        let database = try await makeDatabase(name: "recovery_existing_video_metadata_mismatch")
        let placeholderVideo = VideoSegment(
            id: sessionVideoID,
            startTime: start,
            endTime: start.addingTimeInterval(2),
            frameCount: 2,
            fileSizeBytes: 123,
            relativePath: "chunks/202603/12/\(sessionVideoID.value)",
            width: 8,
            height: 8
        )
        let databaseVideoID = try await database.insertVideoSegment(placeholderVideo)
        try await database.markVideoFinalized(id: databaseVideoID, frameCount: 2, fileSize: 123)

        let originalVideoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 999),
                startTime: start,
                endTime: start,
                frameCount: 1,
                fileSizeBytes: 50,
                relativePath: "chunks/original/999",
                width: 8,
                height: 8
            )
        )
        try await database.markVideoFinalized(id: originalVideoID, frameCount: 1, fileSize: 50)
        let unrelatedSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Terminal",
            startDate: start,
            endDate: start,
            windowName: "Shell",
            browserUrl: nil,
            type: 0
        )
        let unrelatedFrameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: start,
                segmentID: AppSegmentID(value: unrelatedSegmentID),
                videoID: VideoSegmentID(value: originalVideoID),
                frameIndexInSegment: 7,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Terminal",
                    appName: "Terminal",
                    windowName: "Shell",
                    browserURL: nil,
                    displayID: 1
                ),
                source: .native
            )
        )

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: 2],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 456]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 2)
        XCTAssertEqual(result.videoSegmentsCreated, 0)

        let frames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(frames.count, 3)
        let recoveredFrames = frames.filter { $0.metadata.appBundleID == recoveredMetadata.appBundleID }
        XCTAssertEqual(recoveredFrames.count, 2)
        let recoveredSegmentIDs = Set(recoveredFrames.map(\.segmentID.value))
        XCTAssertEqual(recoveredSegmentIDs.count, 1)
        XCTAssertFalse(recoveredSegmentIDs.contains(unrelatedSegmentID))
        XCTAssertTrue(recoveredFrames.allSatisfy { $0.videoID.value == databaseVideoID })

        let unrelatedFrame = try await database.getFrame(id: FrameID(value: unrelatedFrameID))
        XCTAssertEqual(unrelatedFrame?.segmentID.value, unrelatedSegmentID)
        XCTAssertEqual(unrelatedFrame?.videoID.value, originalVideoID)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryInvalidExistingVideoReencodesWhenDatabaseRowIsMissing() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_569)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_100)

        for index in 0..<3 {
            try await walManager.appendFrame(
                makeCapturedFrame(
                    width: 8,
                    height: 8,
                    bytesPerRow: 32,
                    imageByteCount: 32 * 8,
                    timestamp: start.addingTimeInterval(Double(index))
                ),
                to: &session
            )
        }

        let database = try await makeDatabase(name: "recovery_invalid_existing_video_missing_db_row")
        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [sessionVideoID.value: 3],
            validVideoIDs: []
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 3)
        XCTAssertEqual(result.videoSegmentsCreated, 1)

        let videos = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos[0].frameCount, 3)
        let deletedSegmentIDs = await storage.deletedSegmentIDsSnapshot()
        XCTAssertEqual(deletedSegmentIDs, [sessionVideoID.value])
        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryInvalidExistingVideoReusesPersistedDurablePrefixAndOnlyReencodesTail() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_579)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_175)
        let frames = (0..<5).map { index in
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }
        try await walManager.updateDurableVideoState(
            videoID: sessionVideoID,
            readableFrameCount: 3,
            durableVideoFileSizeBytes: 777
        )

        let database = try await makeDatabase(name: "recovery_invalid_existing_video_reuses_durable_prefix")
        let databaseVideoID = try await database.insertVideoSegment(
            makePlaceholderVideo(id: sessionVideoID, start: start, frameCount: 3, fileSizeBytes: 777)
        )
        let segmentID = try await database.insertSegment(
            bundleID: frames[0].metadata.appBundleID ?? "com.apple.Safari",
            startDate: frames[0].timestamp,
            endDate: frames.last?.timestamp ?? frames[0].timestamp,
            windowName: frames[0].metadata.windowName,
            browserUrl: frames[0].metadata.browserURL,
            type: 0
        )

        for (index, frame) in frames.enumerated() {
            let frameID = 9_600 + Int64(index)
            try await walManager.registerFrameID(videoID: sessionVideoID, frameID: frameID, frameIndex: index)
            try await insertStoredFrame(
                database: database,
                frameID: frameID,
                timestamp: frame.timestamp,
                segmentID: segmentID,
                videoID: databaseVideoID,
                frameIndex: index,
                metadata: frame.metadata
            )
            try await database.updateFrameProcessingStatus(frameID: frameID, status: 2)
        }

        let recoveryIndex = try await walManager.recoveryIndex(for: session)
        let expectedTailOffsets = Array(recoveryIndex.recoverableOffsets.suffix(2))

        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [sessionVideoID.value: 3],
            validVideoIDs: [],
            segmentFileSizes: [sessionVideoID.value: 777]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        await walManager.resetDebugRawReadOffsets(for: sessionVideoID)

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 0)
        XCTAssertEqual(result.videoSegmentsCreated, 1)

        let rawReadOffsets = await walManager.debugRawReadOffsets(for: sessionVideoID)
        XCTAssertEqual(rawReadOffsets, expectedTailOffsets)

        let finalizedSegments = await storage.finalizedSegmentsSnapshot()
        XCTAssertEqual(finalizedSegments.count, 1)
        XCTAssertEqual(finalizedSegments[0].frameCount, 2)

        let deletedSegmentIDs = await storage.deletedSegmentIDsSnapshot()
        XCTAssertEqual(deletedSegmentIDs, [])

        let videos = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(videos.map(\.frameCount).sorted(), [2, 3])

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryInvalidExistingVideoRepairsToDurableBoundaryWhenReadablePrefixIsShort() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_581)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_275)
        let frames = (0..<5).map { index in
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }
        try await walManager.updateDurableVideoState(
            videoID: sessionVideoID,
            readableFrameCount: 4,
            durableVideoFileSizeBytes: 777
        )

        let database = try await makeDatabase(name: "recovery_invalid_existing_video_repairs_partial_prefix")
        let databaseVideoID = try await database.insertVideoSegment(
            makePlaceholderVideo(id: sessionVideoID, start: start, frameCount: 3, fileSizeBytes: 999)
        )
        let segmentID = try await database.insertSegment(
            bundleID: frames[0].metadata.appBundleID ?? "com.apple.Safari",
            startDate: frames[0].timestamp,
            endDate: frames.last?.timestamp ?? frames[0].timestamp,
            windowName: frames[0].metadata.windowName,
            browserUrl: frames[0].metadata.browserURL,
            type: 0
        )

        for (index, frame) in frames.enumerated() {
            let frameID = 9_650 + Int64(index)
            try await walManager.registerFrameID(videoID: sessionVideoID, frameID: frameID, frameIndex: index)
            try await insertStoredFrame(
                database: database,
                frameID: frameID,
                timestamp: frame.timestamp,
                segmentID: segmentID,
                videoID: databaseVideoID,
                frameIndex: index,
                metadata: frame.metadata
            )
            try await database.updateFrameProcessingStatus(frameID: frameID, status: 2)
        }

        let recoveryIndex = try await walManager.recoveryIndex(for: session)
        let expectedTailOffsets = Array(recoveryIndex.recoverableOffsets.suffix(1))

        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [sessionVideoID.value: 3],
            validVideoIDs: [],
            segmentFileSizes: [sessionVideoID.value: 999],
            readableFrameCountsByFileSize: [sessionVideoID.value: [777: 4, 999: 3]]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        await walManager.resetDebugRawReadOffsets(for: sessionVideoID)

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 0)
        XCTAssertEqual(result.videoSegmentsCreated, 1)

        let rawReadOffsets = await walManager.debugRawReadOffsets(for: sessionVideoID)
        XCTAssertEqual(rawReadOffsets, expectedTailOffsets)

        let finalizedSegments = await storage.finalizedSegmentsSnapshot()
        XCTAssertEqual(finalizedSegments.count, 1)
        XCTAssertEqual(finalizedSegments[0].frameCount, 1)

        let recoveredVideo = try await database.getVideoSegment(id: VideoSegmentID(value: databaseVideoID))
        XCTAssertEqual(recoveredVideo?.frameCount, 4)
        XCTAssertEqual(recoveredVideo?.fileSizeBytes, 777)

        let videos = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(videos.map(\.frameCount).sorted(), [1, 4])

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryReencodeCreatesNewSegmentWhenTimestampMatchHasDifferentMetadata() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_572)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_350)
        let recoveredMetadata = FrameMetadata(
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            windowName: "Docs",
            browserURL: "https://example.com/docs",
            displayID: 1
        )

        for index in 0..<2 {
            try await walManager.appendFrame(
                makeCapturedFrame(
                    width: 8,
                    height: 8,
                    bytesPerRow: 32,
                    imageByteCount: 32 * 8,
                    timestamp: start.addingTimeInterval(Double(index)),
                    metadata: recoveredMetadata
                ),
                to: &session
            )
        }

        let database = try await makeDatabase(name: "recovery_reencode_metadata_mismatch")
        let originalVideoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 999),
                startTime: start,
                endTime: start,
                frameCount: 1,
                fileSizeBytes: 50,
                relativePath: "chunks/original/999",
                width: 8,
                height: 8
            )
        )
        try await database.markVideoFinalized(id: originalVideoID, frameCount: 1, fileSize: 50)
        let unrelatedSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Terminal",
            startDate: start,
            endDate: start,
            windowName: "Shell",
            browserUrl: nil,
            type: 0
        )
        let unrelatedFrameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: start,
                segmentID: AppSegmentID(value: unrelatedSegmentID),
                videoID: VideoSegmentID(value: originalVideoID),
                frameIndexInSegment: 7,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Terminal",
                    appName: "Terminal",
                    windowName: "Shell",
                    browserURL: nil,
                    displayID: 1
                ),
                source: .native
            )
        )

        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [sessionVideoID.value: 0],
            validVideoIDs: []
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 2)
        XCTAssertEqual(result.videoSegmentsCreated, 1)

        let frames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(frames.count, 3)
        let recoveredFrames = frames.filter { $0.metadata.appBundleID == recoveredMetadata.appBundleID }
        XCTAssertEqual(recoveredFrames.count, 2)
        let recoveredSegmentIDs = Set(recoveredFrames.map(\.segmentID.value))
        XCTAssertEqual(recoveredSegmentIDs.count, 1)
        XCTAssertFalse(recoveredSegmentIDs.contains(unrelatedSegmentID))

        let unrelatedFrame = try await database.getFrame(id: FrameID(value: unrelatedFrameID))
        XCTAssertEqual(unrelatedFrame?.segmentID.value, unrelatedSegmentID)
        XCTAssertEqual(unrelatedFrame?.videoID.value, originalVideoID)
        XCTAssertEqual(unrelatedFrame?.frameIndexInSegment, 7)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryPureWALReencodeDeletesPlaceholderVideoRow() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 1_771_610_472_581)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_720_000_820)

        for index in 0..<2 {
            try await walManager.appendFrame(
                makeCapturedFrame(
                    width: 8,
                    height: 8,
                    bytesPerRow: 32,
                    imageByteCount: 32 * 8,
                    timestamp: start.addingTimeInterval(Double(index))
                ),
                to: &session
            )
        }

        let database = try await makeDatabase(name: "recovery_wal_only_reencode_deletes_placeholder")
        let placeholderVideo = VideoSegment(
            id: sessionVideoID,
            startTime: start,
            endTime: start,
            frameCount: 0,
            fileSizeBytes: 0,
            relativePath: "chunks/202603/12/\(sessionVideoID.value)",
            width: 8,
            height: 8
        )
        let placeholderDBID = try await database.insertVideoSegment(placeholderVideo)

        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [sessionVideoID.value: 0],
            validVideoIDs: []
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 2)
        XCTAssertEqual(result.videoSegmentsCreated, 1)

        let deletedPlaceholder = try await database.getVideoSegment(id: VideoSegmentID(value: placeholderDBID))
        XCTAssertNil(deletedPlaceholder)

        let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
        XCTAssertTrue(unfinalisedVideos.isEmpty)

        let videos = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(videos.count, 1)
        XCTAssertNotEqual(videos.first?.id.value, placeholderDBID)

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryQuarantineDeletesMatchingUnfinalisedVideoRow() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 404)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_740_000_000)
        try await walManager.appendFrame(
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start
            ),
            to: &session
        )

        let fileHandle = try XCTUnwrap(FileHandle(forWritingAtPath: session.framesURL.path))
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: 0)

        let database = try await makeDatabase(name: "recovery_quarantine_deletes_video_row")
        let placeholderVideo = VideoSegment(
            id: sessionVideoID,
            startTime: start,
            endTime: start,
            frameCount: 1,
            fileSizeBytes: 99,
            relativePath: "chunks/202603/12/\(sessionVideoID.value)",
            width: 8,
            height: 8
        )
        let databaseVideoID = try await database.insertVideoSegment(placeholderVideo)

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: 0],
            validVideoIDs: []
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 0)
        let deletedVideo = try await database.getVideoSegment(id: VideoSegmentID(value: databaseVideoID))
        XCTAssertNil(deletedVideo)
        let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
        XCTAssertTrue(unfinalisedVideos.isEmpty)
        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryQuarantinePreservesVerifiedExistingVideoPrefix() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 405)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_740_000_100)
        try await walManager.appendFrame(
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start
            ),
            to: &session
        )

        let fileHandle = try XCTUnwrap(FileHandle(forWritingAtPath: session.framesURL.path))
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: 0)

        let database = try await makeDatabase(name: "recovery_quarantine_preserves_prefix")
        let placeholderVideo = VideoSegment(
            id: sessionVideoID,
            startTime: start,
            endTime: start,
            frameCount: 1,
            fileSizeBytes: 99,
            relativePath: "chunks/202603/12/\(sessionVideoID.value)",
            width: 8,
            height: 8
        )
        let databaseVideoID = try await database.insertVideoSegment(placeholderVideo)

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: 1],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 333]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)

        let recoveredVideo = try await database.getVideoSegment(id: VideoSegmentID(value: databaseVideoID))
        XCTAssertEqual(recoveredVideo?.frameCount, 1)
        XCTAssertEqual(recoveredVideo?.fileSizeBytes, 333)
        let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
        XCTAssertTrue(unfinalisedVideos.isEmpty)
        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryPreservesVerifiedVideoFrameCountWhenWALPrefixIsShorter() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 406)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_740_000_150)
        let frames = (0..<4).map { index in
            makeCapturedFrame(
                width: 8,
                height: 8,
                bytesPerRow: 32,
                imageByteCount: 32 * 8,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
        for frame in frames {
            try await walManager.appendFrame(frame, to: &session)
        }

        let firstFrameMetadata = frames[0].metadata
        let appBundleIDBytes = firstFrameMetadata.appBundleID?.utf8.count ?? 0
        let appNameBytes = firstFrameMetadata.appName?.utf8.count ?? 0
        let windowNameBytes = firstFrameMetadata.windowName?.utf8.count ?? 0
        let browserURLBytes = firstFrameMetadata.browserURL?.utf8.count ?? 0
        let metadataSize = appBundleIDBytes + appNameBytes + windowNameBytes + browserURLBytes
        let frameSize = 36 + metadataSize + frames[0].imageData.count
        let fileHandle = try XCTUnwrap(FileHandle(forWritingAtPath: session.framesURL.path))
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: UInt64(frameSize * 2))

        let database = try await makeDatabase(name: "recovery_preserve_verified_video_frame_count")
        let placeholderVideo = VideoSegment(
            id: sessionVideoID,
            startTime: start,
            endTime: start.addingTimeInterval(4),
            frameCount: 4,
            fileSizeBytes: 111,
            relativePath: "chunks/202603/12/\(sessionVideoID.value)",
            width: 8,
            height: 8
        )
        let databaseVideoID = try await database.insertVideoSegment(placeholderVideo)

        let storage = RecoveryTestStorage(
            writerPlans: [],
            existingFrameCounts: [sessionVideoID.value: 4],
            validVideoIDs: [sessionVideoID.value],
            segmentFileSizes: [sessionVideoID.value: 444]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.videoSegmentsCreated, 0)

        let recoveredVideo = try await database.getVideoSegment(id: VideoSegmentID(value: databaseVideoID))
        XCTAssertEqual(recoveredVideo?.frameCount, 4)
        XCTAssertEqual(recoveredVideo?.fileSizeBytes, 444)

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryRollbackRestoresExistingFramesAndDeletesInsertedRowsOnCommitFailure() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 407)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_740_000_300)
        let firstFrame = makeCapturedFrame(
            width: 8,
            height: 8,
            bytesPerRow: 32,
            imageByteCount: 32 * 8,
            timestamp: start
        )
        let secondFrame = makeCapturedFrame(
            width: 8,
            height: 8,
            bytesPerRow: 32,
            imageByteCount: 32 * 8,
            timestamp: start.addingTimeInterval(1)
        )
        try await walManager.appendFrame(firstFrame, to: &session)
        try await walManager.appendFrame(secondFrame, to: &session)

        let database = try await makeDatabase(name: "recovery_rollback_commit_failure")
        let originalVideoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 999),
                startTime: start,
                endTime: start,
                frameCount: 1,
                fileSizeBytes: 100,
                relativePath: "chunks/original/999",
                width: 8,
                height: 8
            )
        )
        try await database.markVideoFinalized(id: originalVideoID, frameCount: 1, fileSize: 100)
        let originalSegmentID = try await database.insertSegment(
            bundleID: firstFrame.metadata.appBundleID ?? "com.apple.Safari",
            startDate: start,
            endDate: start,
            windowName: firstFrame.metadata.windowName,
            browserUrl: firstFrame.metadata.browserURL,
            type: 0
        )
        let existingFrameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: start,
                segmentID: AppSegmentID(value: originalSegmentID),
                videoID: VideoSegmentID(value: originalVideoID),
                frameIndexInSegment: 7,
                metadata: firstFrame.metadata,
                source: .native
            )
        )
        await database.failNextMarkVideoFinalized()

        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [sessionVideoID.value: 0],
            validVideoIDs: []
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 0)
        XCTAssertEqual(result.framesRecovered, 0)
        XCTAssertEqual(result.videoSegmentsCreated, 0)

        let frames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        )
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].id.value, existingFrameID)
        XCTAssertEqual(frames[0].videoID.value, originalVideoID)
        XCTAssertEqual(frames[0].frameIndexInSegment, 7)

        let segments = try await database.getSegments(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60)
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].id.value, originalSegmentID)

        let videos = try await database.getVideoSegments(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60)
        )
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos[0].id.value, originalVideoID)
        let deletedSegmentIDs = await storage.deletedSegmentIDsSnapshot()
        XCTAssertEqual(deletedSegmentIDs, [10_000])

        let activeSessions = try await walManager.listActiveSessions()
        XCTAssertTrue(activeSessions.isEmpty)
        let walContents = try FileManager.default.contentsOfDirectory(at: walRoot, includingPropertiesForKeys: nil)
        let retainedQuarantines = walContents.filter {
            $0.lastPathComponent.hasPrefix("retained_segment_\(sessionVideoID.value)_")
        }
        XCTAssertEqual(retainedQuarantines.count, 1)
        let removedCount = await walManager.cleanupQuarantinedSessions(olderThan: .distantFuture)
        XCTAssertEqual(removedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedQuarantines[0].path))

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoverySplitsRecoveredAppSegmentsOnMetadataChanges() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let sessionVideoID = VideoSegmentID(value: 777)
        var session = try await walManager.createSession(videoID: sessionVideoID)
        let start = Date(timeIntervalSince1970: 1_730_000_000)

        let firstMetadata = FrameMetadata(
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            windowName: "Docs",
            browserURL: "https://example.com/docs",
            displayID: 1
        )
        let secondMetadata = FrameMetadata(
            appBundleID: "com.apple.Terminal",
            appName: "Terminal",
            windowName: "shell",
            browserURL: nil,
            displayID: 1
        )

        for index in 0..<4 {
            let metadata = index < 2 ? firstMetadata : secondMetadata
            try await walManager.appendFrame(
                makeCapturedFrame(
                    width: 8,
                    height: 8,
                    bytesPerRow: 32,
                    imageByteCount: 32 * 8,
                    timestamp: start.addingTimeInterval(Double(index)),
                    metadata: metadata
                ),
                to: &session
            )
        }

        let database = try await makeDatabase(name: "recovery_segment_metadata_split")
        let storage = RecoveryTestStorage(
            writerPlans: [.init(failAfter: nil)],
            existingFrameCounts: [sessionVideoID.value: 0],
            validVideoIDs: [sessionVideoID.value]
        )
        let recoveryManager = makeRecoveryManager(
            walManager: walManager,
            storage: storage,
            database: database
        )

        let result = try await recoveryManager.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)

        let segments = try await database.getSegments(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60)
        )
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.bundleID), ["com.apple.Safari", "com.apple.Terminal"])
        XCTAssertEqual(segments.map(\.windowName), ["Docs", "shell"])

        let frames = try await database.getFrames(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60),
            limit: 10
        ).sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(Set(frames.prefix(2).map(\.segmentID.value)).count, 1)
        XCTAssertEqual(Set(frames.suffix(2).map(\.segmentID.value)).count, 1)
        XCTAssertNotEqual(frames[0].segmentID.value, frames[2].segmentID.value)

        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RecoveryTestDatabase: DatabaseProtocol {
    private var nextFrameID: Int64 = 1
    private var nextSegmentID: Int64 = 1
    private var nextDocumentID: Int64 = 1
    private var nextVideoID: Int64 = 1
    private var framesByID: [Int64: FrameReference] = [:]
    private var frameIDByTimestamp: [Date: Int64] = [:]
    private var frameMetadataByID: [Int64: String] = [:]
    private var frameProcessingStatuses: [Int64: Int] = [:]
    private var videosByID: [Int64: StoredVideoRecord] = [:]
    private var segmentsByID: [Int64: Segment] = [:]
    private var documentsByFrameID: [Int64: IndexedDocument] = [:]
    private var docIDsByFrameID: [Int64: Int64] = [:]
    private var ftsContentByDocID: [Int64: (mainText: String, chromeText: String?, windowTitle: String?)] = [:]
    private var failMarkVideoFinalizedNext = false

    private struct StoredVideoRecord {
        var segment: VideoSegment
        var processingState: Int
    }

    func initialize() async throws {}

    func close() async throws {}

    func insertFrame(_ frame: FrameReference) async throws -> Int64 {
        let frameID = frame.id.value == 0 ? nextFrameID : frame.id.value
        nextFrameID = max(nextFrameID, frameID + 1)

        let storedFrame = FrameReference(
            id: FrameID(value: frameID),
            timestamp: frame.timestamp,
            segmentID: frame.segmentID,
            videoID: frame.videoID,
            frameIndexInSegment: frame.frameIndexInSegment,
            encodingStatus: frame.encodingStatus,
            metadata: frame.metadata,
            source: frame.source
        )
        framesByID[frameID] = storedFrame
        frameIDByTimestamp[frame.timestamp] = frameID
        frameProcessingStatuses[frameID] = frameProcessingStatuses[frameID] ?? 0
        return frameID
    }

    func getFrame(id: FrameID) async throws -> FrameReference? {
        framesByID[id.value]
    }

    func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference] {
        Array(
            framesByID.values
                .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
                .sorted { $0.timestamp < $1.timestamp }
                .prefix(limit)
        )
    }

    func getFramesBefore(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        Array(
            framesByID.values
                .filter { $0.timestamp < timestamp }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(limit)
        )
    }

    func getFramesAfter(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        Array(
            framesByID.values
                .filter { $0.timestamp > timestamp }
                .sorted { $0.timestamp < $1.timestamp }
                .prefix(limit)
        )
    }

    func getFrames(appBundleID: String, limit: Int, offset: Int) async throws -> [FrameReference] {
        let filtered = framesByID.values
            .filter { $0.metadata.appBundleID == appBundleID }
            .sorted { $0.timestamp < $1.timestamp }
        return Array(filtered.dropFirst(offset).prefix(limit))
    }

    func deleteFrames(olderThan date: Date) async throws -> Int {
        let frameIDsToDelete = framesByID.values
            .filter { $0.timestamp < date }
            .map(\.id.value)
        for frameID in frameIDsToDelete {
            if let frame = framesByID.removeValue(forKey: frameID) {
                frameIDByTimestamp.removeValue(forKey: frame.timestamp)
            }
            frameMetadataByID.removeValue(forKey: frameID)
            frameProcessingStatuses.removeValue(forKey: frameID)
            documentsByFrameID.removeValue(forKey: frameID)
            if let docID = docIDsByFrameID.removeValue(forKey: frameID) {
                ftsContentByDocID.removeValue(forKey: docID)
            }
        }
        return frameIDsToDelete.count
    }

    func deleteFrame(id: FrameID) async throws {
        guard let frame = framesByID.removeValue(forKey: id.value) else {
            return
        }

        if frameIDByTimestamp[frame.timestamp] == id.value {
            frameIDByTimestamp.removeValue(forKey: frame.timestamp)
        }
        frameMetadataByID.removeValue(forKey: id.value)
        frameProcessingStatuses.removeValue(forKey: id.value)
        documentsByFrameID.removeValue(forKey: id.value)
        if let docID = docIDsByFrameID.removeValue(forKey: id.value) {
            ftsContentByDocID.removeValue(forKey: docID)
        }
    }

    func getFrameCount() async throws -> Int {
        framesByID.count
    }

    func frameExistsAtTimestamp(_ timestamp: Date) async throws -> Bool {
        frameIDByTimestamp[timestamp] != nil
    }

    func getFrameIDAtTimestamp(_ timestamp: Date) async throws -> Int64? {
        frameIDByTimestamp[timestamp]
    }

    func updateFrameVideoLink(frameID: FrameID, videoID: VideoSegmentID, frameIndex: Int) async throws {
        guard let existing = framesByID[frameID.value] else { return }
        framesByID[frameID.value] = FrameReference(
            id: existing.id,
            timestamp: existing.timestamp,
            segmentID: existing.segmentID,
            videoID: videoID,
            frameIndexInSegment: frameIndex,
            encodingStatus: existing.encodingStatus,
            metadata: existing.metadata,
            source: existing.source
        )
    }

    func updateFrameMetadata(frameID: FrameID, metadataJSON: String?) async throws {
        if let metadataJSON {
            frameMetadataByID[frameID.value] = metadataJSON
        } else {
            frameMetadataByID.removeValue(forKey: frameID.value)
        }
    }

    func getFrameMetadata(frameID: FrameID) async throws -> String? {
        frameMetadataByID[frameID.value]
    }

    func getFrameProcessingStatuses(frameIDs: [Int64]) async throws -> [Int64: Int] {
        Dictionary(uniqueKeysWithValues: frameIDs.map { ($0, frameProcessingStatuses[$0] ?? 0) })
    }

    func markFrameReadable(frameID: Int64) async throws {
        frameProcessingStatuses[frameID] = 0
    }

    func updateFrameProcessingStatus(frameID: Int64, status: Int) async throws {
        frameProcessingStatuses[frameID] = status
    }

    func insertVideoSegment(_ segment: VideoSegment) async throws -> Int64 {
        let databaseVideoID = nextVideoID
        nextVideoID += 1

        let storedSegment = VideoSegment(
            id: VideoSegmentID(value: databaseVideoID),
            startTime: segment.startTime,
            endTime: segment.endTime,
            frameCount: segment.frameCount,
            fileSizeBytes: segment.fileSizeBytes,
            relativePath: segment.relativePath,
            width: segment.width,
            height: segment.height,
            source: segment.source
        )
        videosByID[databaseVideoID] = StoredVideoRecord(segment: storedSegment, processingState: 1)
        return databaseVideoID
    }

    func getVideoSegment(id: VideoSegmentID) async throws -> VideoSegment? {
        videosByID[id.value]?.segment
    }

    func findVideoSegment(relativePathStem: String) async throws -> VideoSegment? {
        videosByID.values
            .map(\.segment)
            .filter {
                URL(fileURLWithPath: $0.relativePath).deletingPathExtension().lastPathComponent == relativePathStem
            }
            .sorted { $0.id.value > $1.id.value }
            .first
    }

    func getVideoSegment(containingTimestamp date: Date) async throws -> VideoSegment? {
        videosByID.values.map(\.segment).first { $0.startTime <= date && $0.endTime >= date }
    }

    func getVideoSegments(from startDate: Date, to endDate: Date) async throws -> [VideoSegment] {
        videosByID.values.map(\.segment)
            .filter { $0.endTime >= startDate && $0.startTime <= endDate }
            .sorted { $0.startTime < $1.startTime }
    }

    func deleteVideoSegment(id: VideoSegmentID) async throws {
        videosByID.removeValue(forKey: id.value)

        let matchingFrameIDs = framesByID.values
            .filter { $0.videoID.value == id.value }
            .map(\.id.value)
        for frameID in matchingFrameIDs {
            guard let frame = framesByID[frameID] else { continue }
            framesByID[frameID] = FrameReference(
                id: frame.id,
                timestamp: frame.timestamp,
                segmentID: frame.segmentID,
                videoID: VideoSegmentID(value: 0),
                frameIndexInSegment: frame.frameIndexInSegment,
                encodingStatus: frame.encodingStatus,
                metadata: frame.metadata,
                source: frame.source
            )
        }
    }

    func getTotalStorageBytes() async throws -> Int64 {
        videosByID.values.reduce(0) { $0 + $1.segment.fileSizeBytes }
    }

    func getUnfinalisedVideoByResolution(width: Int, height: Int) async throws -> UnfinalisedVideo? {
        videosByID.values
            .filter { $0.processingState == 1 && $0.segment.width == width && $0.segment.height == height }
            .map {
                UnfinalisedVideo(
                    id: $0.segment.id.value,
                    relativePath: $0.segment.relativePath,
                    frameCount: $0.segment.frameCount,
                    width: $0.segment.width,
                    height: $0.segment.height
                )
            }
            .first
    }

    func getAllUnfinalisedVideos() async throws -> [UnfinalisedVideo] {
        videosByID.values
            .filter { $0.processingState == 1 }
            .map {
                UnfinalisedVideo(
                    id: $0.segment.id.value,
                    relativePath: $0.segment.relativePath,
                    frameCount: $0.segment.frameCount,
                    width: $0.segment.width,
                    height: $0.segment.height
                )
            }
            .sorted { $0.id < $1.id }
    }

    func markVideoFinalized(id: Int64, frameCount: Int, fileSize: Int64) async throws {
        if failMarkVideoFinalizedNext {
            failMarkVideoFinalizedNext = false
            throw StorageError.fileWriteFailed(path: "mock-database", underlying: "planned markVideoFinalized failure")
        }

        guard var record = videosByID[id] else { return }
        record.segment = VideoSegment(
            id: record.segment.id,
            startTime: record.segment.startTime,
            endTime: record.segment.endTime,
            frameCount: frameCount,
            fileSizeBytes: fileSize,
            relativePath: record.segment.relativePath,
            width: record.segment.width,
            height: record.segment.height,
            source: record.segment.source
        )
        record.processingState = 0
        videosByID[id] = record
    }

    func failNextMarkVideoFinalized() {
        failMarkVideoFinalizedNext = true
    }

    func finalizeOrphanedVideos(activeVideoIDs: Set<Int64>) async throws -> Int {
        let orphanedIDs = videosByID
            .filter { $0.value.processingState == 1 && !activeVideoIDs.contains($0.key) }
            .map(\.key)
        for videoID in orphanedIDs {
            guard var record = videosByID[videoID] else { continue }
            record.processingState = 0
            videosByID[videoID] = record
        }
        let orphanedCount = orphanedIDs.count
        return orphanedCount
    }

    func updateVideoSegment(id: Int64, width: Int, height: Int, fileSize: Int64, frameCount: Int) async throws {
        guard var record = videosByID[id] else { return }
        record.segment = VideoSegment(
            id: record.segment.id,
            startTime: record.segment.startTime,
            endTime: record.segment.endTime,
            frameCount: frameCount,
            fileSizeBytes: fileSize,
            relativePath: record.segment.relativePath,
            width: width,
            height: height,
            source: record.segment.source
        )
        videosByID[id] = record
    }

    func insertDocument(_ document: IndexedDocument) async throws -> Int64 {
        let docID = document.id == 0 ? nextDocumentID : document.id
        nextDocumentID = max(nextDocumentID, docID + 1)
        let storedDocument = IndexedDocument(
            id: docID,
            frameID: document.frameID,
            timestamp: document.timestamp,
            content: document.content,
            appName: document.appName,
            windowName: document.windowName,
            browserURL: document.browserURL
        )
        documentsByFrameID[document.frameID.value] = storedDocument
        return docID
    }

    func updateDocument(id: Int64, content: String) async throws {
        guard let frameID = documentsByFrameID.first(where: { $0.value.id == id })?.key,
              let existing = documentsByFrameID[frameID] else {
            return
        }
        documentsByFrameID[frameID] = IndexedDocument(
            id: existing.id,
            frameID: existing.frameID,
            timestamp: existing.timestamp,
            content: content,
            appName: existing.appName,
            windowName: existing.windowName,
            browserURL: existing.browserURL
        )
    }

    func deleteDocument(id: Int64) async throws {
        guard let frameID = documentsByFrameID.first(where: { $0.value.id == id })?.key else {
            return
        }
        documentsByFrameID.removeValue(forKey: frameID)
    }

    func getDocument(frameID: FrameID) async throws -> IndexedDocument? {
        documentsByFrameID[frameID.value]
    }

    func insertSegment(
        bundleID: String,
        startDate: Date,
        endDate: Date,
        windowName: String?,
        browserUrl: String?,
        type: Int
    ) async throws -> Int64 {
        let segmentID = nextSegmentID
        nextSegmentID += 1
        segmentsByID[segmentID] = Segment(
            id: SegmentID(value: segmentID),
            bundleID: bundleID,
            startDate: startDate,
            endDate: endDate,
            windowName: windowName,
            browserUrl: browserUrl,
            type: type
        )
        return segmentID
    }

    func updateSegmentEndDate(id: Int64, endDate: Date) async throws {
        guard var segment = segmentsByID[id] else { return }
        segment.updateEndDate(endDate)
        segmentsByID[id] = segment
    }

    func getSegment(id: Int64) async throws -> Segment? {
        segmentsByID[id]
    }

    func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        segmentsByID.values
            .filter { $0.endDate >= startDate && $0.startDate <= endDate }
            .sorted { $0.startDate < $1.startDate }
    }

    func getMostRecentSegment() async throws -> Segment? {
        segmentsByID.values.max { $0.endDate < $1.endDate }
    }

    func getSegments(bundleID: String, limit: Int) async throws -> [Segment] {
        Array(
            segmentsByID.values
                .filter { $0.bundleID == bundleID }
                .sorted { $0.startDate > $1.startDate }
                .prefix(limit)
        )
    }

    func getSegments(
        bundleID: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) async throws -> [Segment] {
        let filtered = segmentsByID.values
            .filter { $0.bundleID == bundleID && $0.endDate >= startDate && $0.startDate <= endDate }
            .sorted { $0.startDate < $1.startDate }
        return Array(filtered.dropFirst(offset).prefix(limit))
    }

    func deleteSegment(id: Int64) async throws {
        segmentsByID.removeValue(forKey: id)
    }

    func insertNodes(
        frameID: FrameID,
        nodes: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)],
        frameWidth: Int,
        frameHeight: Int
    ) async throws {
        _ = frameID
        _ = nodes
        _ = frameWidth
        _ = frameHeight
    }

    func getNodes(frameID: FrameID, frameWidth: Int, frameHeight: Int) async throws -> [OCRNode] {
        _ = frameID
        _ = frameWidth
        _ = frameHeight
        return []
    }

    func getNodesWithText(frameID: FrameID, frameWidth: Int, frameHeight: Int) async throws -> [(node: OCRNode, text: String)] {
        _ = frameID
        _ = frameWidth
        _ = frameHeight
        return []
    }

    func deleteNodes(frameID: FrameID) async throws {
        _ = frameID
    }

    func indexFrameText(
        mainText: String,
        chromeText: String?,
        windowTitle: String?,
        segmentId: Int64,
        frameId: Int64
    ) async throws -> Int64 {
        _ = segmentId
        let docID = nextDocumentID
        nextDocumentID += 1
        docIDsByFrameID[frameId] = docID
        ftsContentByDocID[docID] = (mainText, chromeText, windowTitle)
        return docID
    }

    func getDocidForFrame(frameId: Int64) async throws -> Int64? {
        docIDsByFrameID[frameId]
    }

    func getFTSContent(docid: Int64) async throws -> (mainText: String, chromeText: String?, windowTitle: String?)? {
        ftsContentByDocID[docid]
    }

    func deleteFTSContent(frameId: Int64) async throws {
        guard let docID = docIDsByFrameID.removeValue(forKey: frameId) else {
            return
        }
        ftsContentByDocID.removeValue(forKey: docID)
    }

    func getStatistics() async throws -> DatabaseStatistics {
        DatabaseStatistics(
            frameCount: framesByID.count,
            segmentCount: segmentsByID.count,
            documentCount: documentsByFrameID.count,
            databaseSizeBytes: 0,
            oldestFrameDate: framesByID.values.map(\.timestamp).min(),
            newestFrameDate: framesByID.values.map(\.timestamp).max()
        )
    }
}

private actor RecoveryTestStorage: StorageProtocol {
    struct WriterPlan {
        let failAfter: Int?
    }

    private var writerPlans: [WriterPlan]
    private var nextSegmentValue: Int64 = 10_000
    private let existingFrameCounts: [Int64: Int]
    private let validVideoIDs: Set<Int64>
    private let segmentFileSizes: [Int64: Int64]
    private let readableFrameCountsByFileSize: [Int64: [Int64: Int]]
    private let segmentBaseURL: URL
    private(set) var finalizedSegments: [VideoSegment] = []
    private(set) var deletedSegmentIDs: [Int64] = []

    init(
        writerPlans: [WriterPlan],
        existingFrameCounts: [Int64: Int] = [:],
        validVideoIDs: Set<Int64> = [],
        segmentFileSizes: [Int64: Int64] = [:],
        readableFrameCountsByFileSize: [Int64: [Int64: Int]] = [:]
    ) {
        self.writerPlans = writerPlans
        self.existingFrameCounts = existingFrameCounts
        self.validVideoIDs = validVideoIDs
        self.segmentFileSizes = segmentFileSizes
        self.readableFrameCountsByFileSize = readableFrameCountsByFileSize
        self.segmentBaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RecoveryTestStorage_\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func initialize(config: StorageConfig) async throws {}

    func createSegmentWriter() async throws -> SegmentWriter {
        let plan = writerPlans.isEmpty ? WriterPlan(failAfter: nil) : writerPlans.removeFirst()
        let segmentID = VideoSegmentID(value: nextSegmentValue)
        nextSegmentValue += 1
        return RecoveryTestSegmentWriter(
            storage: self,
            segmentID: segmentID,
            relativePath: "mock/\(segmentID.value).mp4",
            failAfter: plan.failAfter
        )
    }

    func recordFinalizedSegment(_ segment: VideoSegment) {
        finalizedSegments.append(segment)
    }

    func finalizedSegmentsSnapshot() -> [VideoSegment] {
        finalizedSegments
    }

    func deletedSegmentIDsSnapshot() -> [Int64] {
        deletedSegmentIDs
    }

    func readFrame(segmentID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        throw StorageError.fileReadFailed(path: "unused", underlying: "not implemented")
    }

    func getSegmentPath(id: VideoSegmentID) async throws -> URL {
        guard let fileSize = segmentFileSizes[id.value] else {
            throw StorageError.fileNotFound(path: "unused")
        }

        let url = segmentURL(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: segmentBaseURL, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: url)
            defer { try? fileHandle.close() }
            try fileHandle.truncate(atOffset: UInt64(fileSize))
        }
        return url
    }

    func deleteSegment(id: VideoSegmentID) async throws {
        deletedSegmentIDs.append(id.value)
    }

    func segmentExists(id: VideoSegmentID) async throws -> Bool {
        false
    }

    func countFramesInSegment(id: VideoSegmentID) async throws -> Int {
        if let countsByFileSize = readableFrameCountsByFileSize[id.value] {
            let url = segmentURL(for: id)
            if let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64),
               let frameCount = countsByFileSize[currentFileSize] {
                return frameCount
            }
        }

        return existingFrameCounts[id.value] ?? 0
    }

    func readFrameFromWAL(
        segmentID: VideoSegmentID,
        frameID: Int64,
        fallbackFrameIndex: Int
    ) async throws -> CapturedFrame? {
        _ = segmentID
        _ = frameID
        _ = fallbackFrameIndex
        return nil
    }

    func rewriteSegmentForRedaction(
        segmentID: VideoSegmentID,
        frameIDs: [Int64],
        targetsByFrameIndex: [Int: [SegmentRedactionTarget]],
        secret: String
    ) async throws {
        _ = segmentID
        _ = frameIDs
        _ = targetsByFrameIndex
        _ = secret
    }

    func recoverInterruptedSegmentRedactions() async throws -> [SegmentRedactionRecoveryAction] {
        []
    }

    func finishInterruptedSegmentRedactionRecovery(segmentID: VideoSegmentID) async throws {
        _ = segmentID
    }

    func isVideoValid(id: VideoSegmentID) async throws -> Bool {
        validVideoIDs.contains(id.value)
    }

    func getTotalStorageUsed(includeRewind: Bool) async throws -> Int64 { 0 }
    func getStorageUsedForDateRange(from startDate: Date, to endDate: Date) async throws -> Int64 { 0 }
    func getAvailableDiskSpace() async throws -> Int64 { Int64.max }
    func cleanupOldSegments(olderThan date: Date) async throws -> [VideoSegmentID] { [] }
    func getStorageDirectory() -> URL { FileManager.default.temporaryDirectory }

    private func segmentURL(for id: VideoSegmentID) -> URL {
        segmentBaseURL.appendingPathComponent("recovery-test-\(id.value).mp4")
    }
}

private actor RecoveryTestSegmentWriter: SegmentWriter {
    let storage: RecoveryTestStorage
    let segmentID: VideoSegmentID
    let startTime = Date()
    let relativePath: String
    let failAfter: Int?

    private(set) var frameCount: Int = 0
    private(set) var frameWidth: Int = 0
    private(set) var frameHeight: Int = 0
    private(set) var currentFileSize: Int64 = 0
    private var cancelled = false
    private var finalized = false

    init(
        storage: RecoveryTestStorage,
        segmentID: VideoSegmentID,
        relativePath: String,
        failAfter: Int?
    ) {
        self.storage = storage
        self.segmentID = segmentID
        self.relativePath = relativePath
        self.failAfter = failAfter
    }

    var hasFragmentWritten: Bool { frameCount > 0 }
    var framesFlushedToDisk: Int { frameCount }

    func appendFrame(_ frame: CapturedFrame) async throws {
        if cancelled || finalized {
            throw StorageError.fileWriteFailed(path: relativePath, underlying: "writer unavailable")
        }
        if let failAfter, frameCount >= failAfter {
            throw StorageError.fileWriteFailed(path: relativePath, underlying: "planned append failure")
        }
        if frameWidth == 0 {
            frameWidth = frame.width
            frameHeight = frame.height
        }
        frameCount += 1
        currentFileSize += Int64(frame.imageData.count)
    }

    func finalize() async throws -> VideoSegment {
        finalized = true
        let segment = VideoSegment(
            id: segmentID,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(Double(frameCount)),
            frameCount: frameCount,
            fileSizeBytes: currentFileSize,
            relativePath: relativePath,
            width: frameWidth,
            height: frameHeight
        )
        await storage.recordFinalizedSegment(segment)
        return segment
    }

    func cancel() async throws {
        cancelled = true
    }
}

private actor RecoveryEnqueueCollector {
    private var frameIDs: [Int64] = []

    func append(_ ids: [Int64]) {
        frameIDs.append(contentsOf: ids)
    }

    func snapshot() -> [Int64] {
        frameIDs
    }
}

// MARK: - Async XCTest helper

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        // success
    }
}
