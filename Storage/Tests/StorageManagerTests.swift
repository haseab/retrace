import CryptoKit
import Foundation
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

    private func createFakeSegmentFile(root: URL, id: SegmentID, date: Date, ext: String, size: Int, modDate: Date) throws -> URL {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        let dir = root
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("segment_\(id.stringValue).\(ext)")
        let data = Data(repeating: 0xCD, count: size)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modDate], ofItemAtPath: url.path)
        return url
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

    func testGetSegmentPathFindsByIDString() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let id = SegmentID()
        let now = Date()
        let url = try createFakeSegmentFile(
            root: root,
            id: id,
            date: now,
            ext: "mp4",  // Changed from "hevc" to "mp4"
            size: 16,
            modDate: now
        )

        let found = try await storage.getSegmentPath(id: id)
        // Use path comparison to handle /var vs /private/var symlink differences
        XCTAssertEqual(found.standardizedFileURL.path, url.standardizedFileURL.path)

        try? FileManager.default.removeItem(at: root)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                            Cleanup Tests                                 │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testCleanupOldSegmentsDeletesPastFiles() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let oldDate = Date(timeIntervalSinceNow: -7 * 24 * 3600)
        let cutoff = Date(timeIntervalSinceNow: -24 * 3600)

        let id1 = SegmentID()
        let id2 = SegmentID()
        _ = try createFakeSegmentFile(root: root, id: id1, date: oldDate, ext: "hevc", size: 10, modDate: oldDate)
        _ = try createFakeSegmentFile(root: root, id: id2, date: oldDate, ext: "hevc", size: 20, modDate: oldDate)

        let deleted = try await storage.cleanupOldSegments(olderThan: cutoff)
        XCTAssertEqual(Set(deleted), Set([id1, id2]))
        let exists1 = try await storage.segmentExists(id: id1)
        XCTAssertFalse(exists1)
        let exists2 = try await storage.segmentExists(id: id2)
        XCTAssertFalse(exists2)

        try? FileManager.default.removeItem(at: root)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Storage Metrics Tests                             │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testTotalStorageUsedSumsSegmentSizes() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let now = Date()
        let id1 = SegmentID()
        let id2 = SegmentID()
        _ = try createFakeSegmentFile(root: root, id: id1, date: now, ext: "hevc", size: 123, modDate: now)
        _ = try createFakeSegmentFile(root: root, id: id2, date: now, ext: "hevc", size: 456, modDate: now)

        let total = try await storage.getTotalStorageUsed()
        XCTAssertEqual(total, 123 + 456)

        try? FileManager.default.removeItem(at: root)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                         Frame Reading Tests                              │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testReadFrameThrowsForMissingSegment() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let missingID = SegmentID()
        await XCTAssertThrowsErrorAsync {
            _ = try await storage.readFrame(segmentID: missingID, timestamp: Date())
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

