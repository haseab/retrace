import XCTest
import CoreGraphics
import ImageIO
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
}
