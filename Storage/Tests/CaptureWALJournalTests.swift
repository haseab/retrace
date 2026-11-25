import XCTest
import ImageIO
import Shared
@testable import Storage

final class CaptureWALJournalTests: XCTestCase {
    private func screenshot(_ sequence: Int = 0) throws -> CapturedFrame {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent("UI/Assets.xcassets/InPageURLInstructions.imageset/safari_instructions.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = try BGRAImageUtilities.makeData(from: image)
        return CapturedFrame(timestamp: Date(timeIntervalSince1970: Double(sequence)), imageData: pixels,
            width: image.width, height: image.height, bytesPerRow: image.width * 4,
            metadata: FrameMetadata(appBundleID: "com.example.editor", displayID: 7, isFocused: false))
    }

    func testJournalIsRecoverableBeforeAnyFrameIsEncoded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageRoot: root, crashReportDirectory: root.appendingPathComponent("crash").path)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let journal = CaptureWALJournal(storage: storage)
        let input = try screenshot()
        let persisted = try await journal.persist(input)
        let receipt = try XCTUnwrap(persisted.journalReceipt)
        let encodedCount = await receipt.writer.frameCount
        XCTAssertEqual(encodedCount, 0)
        let restarted = WALManager(walRoot: root.appendingPathComponent("wal"))
        let sessions = try await restarted.listActiveSessions()
        XCTAssertEqual(sessions.count, 1)
        let recovered = try await restarted.readFrames(from: try XCTUnwrap(sessions.first))
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.imageData, input.imageData)
        XCTAssertEqual(recovered.first?.metadata.displayID, 7)
        XCTAssertEqual(recovered.first?.metadata.isFocused, false)
    }

    func testRotationPreservesPreviouslyJournaledFramesAndStartsANewWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageRoot: root, crashReportDirectory: root.appendingPathComponent("crash").path)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let journal = CaptureWALJournal(storage: storage)
        let first = try await journal.persist(screenshot())
        await journal.rotate()
        let second = try await journal.persist(screenshot(1))
        let firstReceipt = try XCTUnwrap(first.journalReceipt)
        let secondReceipt = try XCTUnwrap(second.journalReceipt)
        XCTAssertNotEqual(firstReceipt.segmentID, secondReceipt.segmentID)
        for frame in [first, second] {
            let receipt = try XCTUnwrap(frame.journalReceipt)
            try await receipt.writer.appendFrame(frame)
            _ = try await receipt.writer.finalize()
        }
        let wal = await storage.getWALManager()
        let sessions = try await wal.listActiveSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testEncodingJournaledFrameDoesNotAppendDuplicateWALRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageRoot: root, crashReportDirectory: root.appendingPathComponent("crash").path)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let journal = CaptureWALJournal(storage: storage)
        let first = try await journal.persist(screenshot())
        _ = try await journal.persist(screenshot(1)) // queue/encoder hasn't consumed this frame
        let receipt = try XCTUnwrap(first.journalReceipt)
        try await receipt.writer.appendFrame(first)
        let wal = await storage.getWALManager()
        let sessions = try await wal.listActiveSessions()
        let frames = try await wal.readFrames(from: try XCTUnwrap(sessions.first))
        XCTAssertEqual(frames.count, 2)
        // A prematurely finalized encoded prefix must not delete the unencoded tail.
        _ = try await receipt.writer.finalize()
        let retained = try await wal.listActiveSessions()
        XCTAssertEqual(retained.count, 1)
        let tailFrames = try await wal.readFrames(from: try XCTUnwrap(retained.first))
        XCTAssertEqual(tailFrames.count, 2)
    }
}
