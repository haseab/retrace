import XCTest
import CoreGraphics
import ImageIO
import SQLCipher
import Shared
import Database
import Storage
@testable import App

final class CaptureJournalPipelineTests: XCTestCase {
    private func screenshot(_ sequence: Int, metadata: FrameMetadata? = nil) throws -> CapturedFrame {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent("UI/Assets.xcassets/InPageURLInstructions.imageset/safari_instructions.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = Data(count: 320 * 240 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 320, height: 240,
                bitsPerComponent: 8, bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        return CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_780_000_000 + Double(sequence)),
            imageData: pixels, width: 320, height: 240, bytesPerRow: 1280,
            metadata: metadata ?? FrameMetadata(appBundleID: "com.example.editor", displayID: 7, isFocused: false))
    }

    func testJournalReceiptsFlowThroughRealEncodingAndDatabaseWithoutDuplicateRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = StorageConfig(storageRootPath: root.path)
        let services = ServiceContainer(databasePath: root.appendingPathComponent("test.db").path,
            storageConfig: config, storageCrashReportDirectory: root.appendingPathComponent("crash").path)
        let db = await services.database
        let storage = await services.storage
        try await db.initialize()
        try await storage.initialize(config: config)
        let journal = CaptureWALJournal(storage: storage, segmentFrameLimit: 2)
        var staged: [CapturedFrame] = []
        for index in 0..<3 { staged.append(try await journal.persist(screenshot(index))) }
        let stream = AsyncStream<CapturedFrame> { continuation in
            staged.forEach { continuation.yield($0) }
            continuation.finish()
        }
        let coordinator = AppCoordinator(services: services)
        // Accepted captures still drain if the timeline opens before encoding.
        // New captures are gated upstream before they enter the journal.
        await coordinator.setTimelineVisible(true)
        await coordinator.runPipeline(frameStream: stream,
            cacheCapturedStills: false, reportUnexpectedStops: false)
        let frames = try await db.getFrames(from: Date(timeIntervalSince1970: 1_779_999_999),
            to: Date(timeIntervalSince1970: 1_780_000_010), limit: 10)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(Set(frames.map(\.videoID)).count, 2)
        let wal = await storage.getWALManager()
        let sessions = try await wal.listActiveSessions()
        XCTAssertTrue(sessions.isEmpty)
        try await db.close()
    }

    func testCrashBeforeEncodingRecoversJournaledScreenshotIntoRealDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = StorageConfig(storageRootPath: root.path)
        let services = ServiceContainer(databasePath: root.appendingPathComponent("test.db").path,
            storageConfig: config, storageCrashReportDirectory: root.appendingPathComponent("crash").path)
        let db = await services.database
        let storage = await services.storage
        try await db.initialize()
        try await storage.initialize(config: config)
        _ = try await CaptureWALJournal(storage: storage).persist(screenshot(0))
        let restarted = WALManager(walRoot: root.appendingPathComponent("wal"))
        let recovery = RecoveryManager(walManager: restarted, storage: storage, database: db)
        let result = try await recovery.recoverAll()
        XCTAssertEqual(result.framesRecovered, 1)
        let frames = try await db.getFrames(from: Date(timeIntervalSince1970: 1_779_999_999),
            to: Date(timeIntervalSince1970: 1_780_000_010), limit: 10)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.metadata.displayID, 7)
        XCTAssertEqual(frames.first?.metadata.isFocused, false)
        try await db.close()
    }

    func testSimultaneousDisplaysWithDifferentVisibleAppsAreBothEncodedAndIndexed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = StorageConfig(storageRootPath: root.path)
        let services = ServiceContainer(databasePath: root.appendingPathComponent("test.db").path,
            storageConfig: config, storageCrashReportDirectory: root.appendingPathComponent("crash").path)
        let db = await services.database
        let storage = await services.storage
        try await db.initialize()
        try await storage.initialize(config: config)
        let journal = CaptureWALJournal(storage: storage)
        let primary = try await journal.persist(screenshot(0, metadata: FrameMetadata(
            appBundleID: "com.example.editor", displayID: 7, isFocused: true)))
        let secondary = try await journal.persist(screenshot(0, metadata: FrameMetadata(
            appBundleID: "com.example.calculator", displayID: 8, isFocused: false)))
        let stream = AsyncStream<CapturedFrame> { continuation in
            continuation.yield(primary)
            continuation.yield(secondary)
            continuation.finish()
        }
        let coordinator = AppCoordinator(services: services)
        await coordinator.runPipeline(frameStream: stream,
            cacheCapturedStills: false, reportUnexpectedStops: false)
        let frames = try await db.getFrames(from: primary.timestamp.addingTimeInterval(-1),
            to: primary.timestamp.addingTimeInterval(1), limit: 10)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(Set(frames.map { $0.metadata.displayID }), Set([UInt32(7), UInt32(8)]))
        XCTAssertEqual(Set(frames.map(\.videoID)).count, 2)
        let byDisplay = Dictionary(uniqueKeysWithValues: frames.map { ($0.metadata.displayID, $0) })
        XCTAssertEqual(byDisplay[7]?.metadata.appBundleID, "com.example.editor")
        XCTAssertEqual(byDisplay[8]?.metadata.appBundleID, "com.example.calculator")
        XCTAssertEqual(byDisplay[7]?.metadata.isFocused, true)
        XCTAssertEqual(byDisplay[8]?.metadata.isFocused, false)
        let wal = await storage.getWALManager()
        let sessions = try await wal.listActiveSessions()
        XCTAssertTrue(sessions.isEmpty)
        try await db.close()
    }

    func testDisconnectDrainsQueuedFramesAndFinalizesWhileOtherDisplayContinues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = StorageConfig(storageRootPath: root.path)
        let services = ServiceContainer(databasePath: root.appendingPathComponent("test.db").path,
            storageConfig: config, storageCrashReportDirectory: root.appendingPathComponent("crash").path)
        let db = await services.database
        let storage = await services.storage
        try await db.initialize()
        try await storage.initialize(config: config)
        let journal = CaptureWALJournal(storage: storage)
        let secondary = try await journal.persist(screenshot(0, metadata: FrameMetadata(
            appBundleID: "com.example.calculator", displayID: 8, isFocused: false)))
        let secondaryTail = try await journal.persist(screenshot(1, metadata: secondary.metadata))
        let primary = try await journal.persist(screenshot(2))
        await journal.retireDisconnectedDisplays(keeping: [7])
        let (stream, continuation) = AsyncStream<CaptureStreamEvent>.makeStream()
        // Retirement is behind every accepted receipt, including queued tails.
        continuation.yield(.frame(secondary))
        continuation.yield(.frame(secondaryTail))
        continuation.yield(.frame(primary))
        continuation.yield(.retainDisplays([7]))
        let coordinator = AppCoordinator(services: services)
        let pipeline = Task { await coordinator.runPipeline(eventStream: stream,
            cacheCapturedStills: false, reportUnexpectedStops: false) }
        let wal = await storage.getWALManager()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let frames = try await db.getFrames(from: secondary.timestamp.addingTimeInterval(-1),
                to: primary.timestamp.addingTimeInterval(1), limit: 10)
            let pending = try await db.getUnfinalisedVideoByDisplayAndResolution(displayID: 8, width: 320, height: 240)
            if frames.count == 3 && pending == nil { break }
            await Task.yield()
        }
        let inactive = try await db.getUnfinalisedVideoByDisplayAndResolution(displayID: 8, width: 320, height: 240)
        XCTAssertNil(inactive)
        let active = try await db.getUnfinalisedVideoByDisplayAndResolution(displayID: 7, width: 320, height: 240)
        XCTAssertNotNil(active)
        let sessions = try await wal.listActiveSessions()
        XCTAssertEqual(sessions.count, 1, "Disconnected display WAL and encoder close without stopping the pipeline")
        // A reconnect starts a fresh writer rather than reusing a finalized receipt.
        let reconnected = try await journal.persist(screenshot(3, metadata: secondary.metadata))
        XCTAssertNotEqual(reconnected.journalReceipt?.segmentID, secondary.journalReceipt?.segmentID)
        continuation.yield(.retainDisplays([7, 8]))
        continuation.yield(.frame(reconnected))
        continuation.finish()
        await pipeline.value
        let frames = try await db.getFrames(from: secondary.timestamp.addingTimeInterval(-1),
            to: reconnected.timestamp.addingTimeInterval(1), limit: 10)
        XCTAssertEqual(frames.count, 4)
        let remaining = try await wal.listActiveSessions()
        XCTAssertTrue(remaining.isEmpty)
        try await db.close()
    }

    func testResolutionChangeClosesPreviousWriterBeforeRecordingStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = StorageConfig(storageRootPath: root.path)
        let services = ServiceContainer(databasePath: root.appendingPathComponent("test.db").path,
            storageConfig: config, storageCrashReportDirectory: root.appendingPathComponent("crash").path)
        let db = await services.database
        let storage = await services.storage
        try await db.initialize()
        try await storage.initialize(config: config)
        let journal = CaptureWALJournal(storage: storage)
        let original = try screenshot(0)
        let changed = CapturedFrame(timestamp: original.timestamp.addingTimeInterval(1),
            imageData: Data(original.imageData.prefix(320 * 120 * 4)), width: 320, height: 120,
            bytesPerRow: 1280, metadata: original.metadata)
        let first = try await journal.persist(original)
        let second = try await journal.persist(changed)
        let (stream, continuation) = AsyncStream<CaptureStreamEvent>.makeStream()
        continuation.yield(.frame(first))
        continuation.yield(.frame(second))
        let coordinator = AppCoordinator(services: services)
        let pipeline = Task { await coordinator.runPipeline(eventStream: stream,
            cacheCapturedStills: false, reportUnexpectedStops: false) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await db.getFrames(from: original.timestamp.addingTimeInterval(-1),
                to: changed.timestamp.addingTimeInterval(1), limit: 10).count == 2 { break }
            await Task.yield()
        }
        let old = try await db.getUnfinalisedVideoByDisplayAndResolution(displayID: 7, width: 320, height: 240)
        XCTAssertNil(old)
        let current = try await db.getUnfinalisedVideoByDisplayAndResolution(displayID: 7, width: 320, height: 120)
        XCTAssertNotNil(current)
        continuation.finish()
        await pipeline.value
        let wal = await storage.getWALManager()
        let sessions = try await wal.listActiveSessions()
        XCTAssertTrue(sessions.isEmpty)
        try await db.close()
    }

    func testDisconnectFinalizationMetadataFailurePreservesEncodedVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = StorageConfig(storageRootPath: root.path)
        let services = ServiceContainer(databasePath: root.appendingPathComponent("test.db").path,
            storageConfig: config, storageCrashReportDirectory: root.appendingPathComponent("crash").path)
        let db = await services.database
        let storage = await services.storage
        try await db.initialize()
        try await storage.initialize(config: config)
        let connection = await db.getConnection()
        let handle = try XCTUnwrap(connection)
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TRIGGER reject_finalization BEFORE UPDATE OF processingState ON video
            WHEN NEW.processingState = 0
            BEGIN SELECT RAISE(FAIL, 'injected finalization metadata failure'); END;
            """, nil, nil, nil), SQLITE_OK)
        let journal = CaptureWALJournal(storage: storage)
        let frame = try await journal.persist(screenshot(0))
        await journal.retireDisconnectedDisplays(keeping: [])
        let stream = AsyncStream<CaptureStreamEvent> { continuation in
            continuation.yield(.frame(frame))
            continuation.yield(.retainDisplays([]))
            continuation.finish()
        }
        let coordinator = AppCoordinator(services: services)
        await coordinator.runPipeline(eventStream: stream, cacheCapturedStills: false, reportUnexpectedStops: false)
        let receipt = try XCTUnwrap(frame.journalReceipt)
        let path = try await storage.getSegmentPath(id: receipt.segmentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
            "A database error after successful encoding must not delete the only durable pixels")
        try await db.close()
    }
}
