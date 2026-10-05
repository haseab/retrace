import Foundation
import XCTest
import Shared
@testable import Storage

/// Covers the WAL payload changes:
/// - disk-backed sessions store a compressed (JPEG) payload and decode it back to BGRA
/// - pre-existing raw BGRA records (legacy layout, same header) still read unchanged
/// - memory-backed sessions write no pixel data, serve reads by frameID/index, and
///   spill to disk on demand so recovery-style disk-truth queries see every frame
final class WALManagerPayloadTests: XCTestCase {
    private var walRoot: URL!

    override func setUp() {
        super.setUp()
        walRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wal-payload-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let walRoot {
            try? FileManager.default.removeItem(at: walRoot)
        }
        super.tearDown()
    }

    // MARK: - Disk-backed: compressed payload round-trip

    func testDiskBackedSessionStoresCompressedPayloadAndDecodesBackToBGRA() async throws {
        let wal = WALManager(walRoot: walRoot, memoryBackedSessionsEnabled: false)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 1))
        let frame = Self.makeGradientFrame(width: 64, height: 64, seed: 30)

        try await wal.appendFrame(frame, to: &session)

        let framesSize = try Self.fileSize(session.framesURL)
        XCTAssertGreaterThan(framesSize, 0)
        XCTAssertLessThan(
            framesSize,
            frame.imageData.count,
            "frames.bin should hold a compressed payload, not raw BGRA"
        )

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.width, 64)
        XCTAssertEqual(read.height, 64)
        XCTAssertEqual(read.bytesPerRow, 64 * 4)
        XCTAssertEqual(read.imageData.count, 64 * 4 * 64)
        XCTAssertEqual(read.metadata.appBundleID, frame.metadata.appBundleID)
        XCTAssertEqual(read.metadata.windowName, frame.metadata.windowName)
        XCTAssertEqual(read.imageData, frame.imageData, "lossless: pixels must match exactly")
    }

    // MARK: - Backward compatibility: legacy raw records

    func testLegacyRawRecordStillReadsUnchanged() async throws {
        let wal = WALManager(walRoot: walRoot, memoryBackedSessionsEnabled: false)
        let session = try await wal.createSession(videoID: VideoSegmentID(value: 2))

        // A raw record written by the previous (uncompressed) implementation:
        // deliberately padded bytesPerRow so we can prove the raw path preserves it.
        let width = 8, height = 4, bytesPerRow = 40
        let raw = Data((0..<(bytesPerRow * height)).map { UInt8($0 % 251) })
        try Self.writeLegacyRawRecord(
            to: session.framesURL,
            raw: raw,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.imageData, raw, "raw payload must be returned byte-for-byte")
        XCTAssertEqual(read.width, width)
        XCTAssertEqual(read.height, height)
        XCTAssertEqual(read.bytesPerRow, bytesPerRow, "raw path must preserve the original bytesPerRow")
    }

    // MARK: - Memory-backed: no pixel writes, reads served, spill on demand

    func testMemoryBackedSessionWritesNoPixelDataAndServesReads() async throws {
        let wal = WALManager(walRoot: walRoot) // memory-backed by default
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 3))
        let frames = (0..<3).map { Self.makeGradientFrame(width: 64, height: 64, seed: UInt8($0 * 60)) }

        for (index, frame) in frames.enumerated() {
            try await wal.appendFrame(frame, to: &session)
            try await wal.registerFrameID(videoID: session.videoID, frameID: Int64(100 + index), frameIndex: index)
        }

        XCTAssertEqual(session.metadata.frameCount, 3)
        XCTAssertEqual(
            try Self.fileSize(session.framesURL),
            0,
            "a memory-backed session must not write pixel data to frames.bin"
        )

        let byID = try await wal.readFrame(videoID: session.videoID, frameID: 101, fallbackFrameIndex: 1)
        XCTAssertEqual(byID.imageData, frames[1].imageData, "lossless: pixels must match exactly")
        let byIndex = try await wal.readFrame(videoID: session.videoID, frameIndex: 2)
        XCTAssertEqual(byIndex.imageData, frames[2].imageData, "lossless: pixels must match exactly")

        // A disk-truth query spills the session: recovery must see every frame.
        let recoverable = try await wal.recoverableFrameCountIfPresent(videoID: session.videoID)
        XCTAssertEqual(recoverable, 3)
        XCTAssertGreaterThan(try Self.fileSize(session.framesURL), 0, "spill must materialize frames.bin")

        // After the spill, frameID lookups keep working via the replayed on-disk map.
        let afterSpill = try await wal.readFrame(videoID: session.videoID, frameID: 100, fallbackFrameIndex: 0)
        XCTAssertEqual(afterSpill.imageData, frames[0].imageData, "lossless: pixels must match exactly")

        try await wal.finalizeSession(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.sessionDir.path))
    }

    func testMemoryBackedReadByUnregisteredFrameIDRefusesIndexFallback() async throws {
        let wal = WALManager(walRoot: walRoot)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 4))
        try await wal.appendFrame(Self.makeGradientFrame(width: 64, height: 64, seed: 0), to: &session)

        do {
            _ = try await wal.readFrame(videoID: session.videoID, frameID: 999, fallbackFrameIndex: 0)
            XCTFail("reading an unregistered frameID must throw rather than fall back to the index")
        } catch {
            // expected: the no-index-fallback contract is preserved in memory mode
        }
    }

    func testFailedFrameSpillPreservesMemoryAndCanRetry() async throws {
        try await assertFailedSpillCanRetry(blockedName: "frames.bin")
    }

    func testFailedMapSpillPreservesMemoryAndCanRetry() async throws {
        try await assertFailedSpillCanRetry(blockedName: "frame_id_map.bin")
    }

    private func assertFailedSpillCanRetry(blockedName: String) async throws {
        let wal = WALManager(walRoot: walRoot)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 5))
        let first = Self.makeGradientFrame(width: 64, height: 64, seed: 20)
        let second = Self.makeGradientFrame(width: 64, height: 64, seed: 80)
        try await wal.appendFrame(first, to: &session)
        try await wal.registerFrameID(videoID: session.videoID, frameID: 101, frameIndex: 0)

        // Use a real filesystem failure, including a late failure after frames
        // have been written but the frame-ID map cannot be published.
        let blockedURL = session.sessionDir.appendingPathComponent(blockedName)
        try FileManager.default.removeItem(at: blockedURL)
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: false)
        try Data([1]).write(to: blockedURL.appendingPathComponent("blocker"))
        do {
            _ = try await wal.recoverableFrameCountIfPresent(videoID: session.videoID)
            XCTFail("Spill must report failure when its destination is blocked")
        } catch {
            // The complete memory copy must still serve reads and accept appends.
        }
        let retained = try await wal.readFrame(videoID: session.videoID, frameID: 101, fallbackFrameIndex: 999)
        XCTAssertEqual(retained.imageData, first.imageData, "lossless: pixels must match exactly")
        try await wal.appendFrame(second, to: &session)
        try await wal.registerFrameID(videoID: session.videoID, frameID: 102, frameIndex: 1)

        try FileManager.default.removeItem(at: blockedURL)
        try Data().write(to: blockedURL)
        let count = try await wal.recoverableFrameCountIfPresent(videoID: session.videoID)
        XCTAssertEqual(count, 2, "Retry must replace partial spill output, never append duplicates")

        // A fresh manager has no in-memory frames or cached mappings.
        let reopened = WALManager(walRoot: walRoot)
        let readFirst = try await reopened.readFrame(videoID: session.videoID, frameID: 101, fallbackFrameIndex: 999)
        let readSecond = try await reopened.readFrame(videoID: session.videoID, frameID: 102, fallbackFrameIndex: 999)
        XCTAssertEqual(readFirst.imageData, first.imageData, "lossless: pixels must match exactly")
        XCTAssertEqual(readSecond.imageData, second.imageData, "lossless: pixels must match exactly")
    }

    // MARK: - Budget is a hard bound

    func testAppendBeyondBudgetSpillsSessionToDiskAndContinuesThere() async throws {
        // 8x8 frames are stored raw (a JPEG would be larger), so each payload is
        // exactly 256 bytes and the arithmetic below is deterministic.
        let wal = WALManager(walRoot: walRoot, memoryBudgetBytes: 600)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 6))
        let frames = (0..<4).map { Self.makeGradientFrame(width: 8, height: 8, seed: UInt8($0 * 50)) }

        try await wal.appendFrame(frames[0], to: &session) // 256 in memory
        try await wal.appendFrame(frames[1], to: &session) // 512 in memory
        XCTAssertEqual(try Self.fileSize(session.framesURL), 0, "still within budget: nothing on disk")

        try await wal.appendFrame(frames[2], to: &session) // 768 > 600: spill, then disk
        XCTAssertGreaterThan(
            try Self.fileSize(session.framesURL),
            0,
            "exceeding the budget must spill the session to disk"
        )
        try await wal.appendFrame(frames[3], to: &session) // session is disk-backed now

        XCTAssertEqual(session.metadata.frameCount, 4)
        for index in 0..<4 {
            let read = try await wal.readFrame(videoID: session.videoID, frameIndex: index)
            XCTAssertEqual(read.imageData, frames[index].imageData, "frame \(index) must survive the spill intact and in order")
        }
        let recoverable = try await wal.recoverableFrameCountIfPresent(videoID: session.videoID)
        XCTAssertEqual(recoverable, 4)
    }

    // MARK: - Relaunch without a spill (crash-recovery view)

    func testRelaunchSeesUnspilledMemoryBackedSessionAsEmptyFramesBin() async throws {
        let wal = WALManager(walRoot: walRoot)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 7))
        try await wal.appendFrame(Self.makeGradientFrame(width: 64, height: 64, seed: 10), to: &session)
        try await wal.appendFrame(Self.makeGradientFrame(width: 64, height: 64, seed: 20), to: &session)

        // A new manager over the same root simulates a relaunch: the previous
        // process's memory is gone; only the sidecars and an empty frames.bin remain.
        let relaunched = WALManager(walRoot: walRoot)
        let active = try await relaunched.listActiveSessions()
        let found = active.first { $0.videoID.value == 7 }
        XCTAssertNotNil(found, "the session directory must still be listed after relaunch")
        XCTAssertEqual(found?.metadata.frameCount, 2, "metadata sidecar must reflect the appended frames")
        let recoverable = try await relaunched.recoverableFrameCountIfPresent(videoID: session.videoID)
        XCTAssertEqual(
            recoverable,
            0,
            "an unspilled memory-backed session leaves no recoverable WAL frames; recovery keeps the durable fMP4 prefix"
        )
    }

    // MARK: - Kill switch

    func testDisablingMemoryModeWritesToDisk() async throws {
        let wal = WALManager(walRoot: walRoot, memoryBackedSessionsEnabled: false)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 8))
        try await wal.appendFrame(Self.makeGradientFrame(width: 64, height: 64, seed: 5), to: &session)
        XCTAssertGreaterThan(try Self.fileSize(session.framesURL), 0, "disk-backed mode must write frames.bin")
    }

    // MARK: - Helpers

    /// Smooth BGRA gradient: compresses well with low JPEG error, and its size
    /// (64x64x4 = 16KB) is large enough that the JPEG is smaller than raw.
    private static func makeGradientFrame(width: Int, height: Int, seed: UInt8) -> CapturedFrame {
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { buffer in
            let base = buffer.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    base[offset] = UInt8(min(255, x * 4))     // B
                    base[offset + 1] = UInt8(min(255, y * 4)) // G
                    base[offset + 2] = seed                   // R
                    base[offset + 3] = 255                    // A
                }
            }
        }
        return CapturedFrame(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            imageData: data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "Example",
                windowName: "Window \(seed)",
                browserURL: nil,
                displayID: 1
            )
        )
    }

    /// Writes a record in the legacy layout: 36-byte header (native endianness,
    /// same field order as WALFrameHeader), no metadata strings, raw BGRA payload.
    private static func writeLegacyRawRecord(
        to framesURL: URL,
        raw: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws {
        var record = Data()
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { record.append(contentsOf: $0) }
        }
        append(Double(1_700_000_000))   // timestamp
        append(UInt32(width))
        append(UInt32(height))
        append(UInt32(bytesPerRow))
        append(UInt32(raw.count))       // dataSize == bytesPerRow*height -> raw
        append(UInt32(1))               // displayID
        append(UInt16(0))               // appBundleIDLength
        append(UInt16(0))               // appNameLength
        append(UInt16(0))               // windowNameLength
        append(UInt16(0))               // browserURLLength
        XCTAssertEqual(record.count, 36, "legacy header must be 36 bytes")
        record.append(raw)
        try record.write(to: framesURL)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
