import Foundation
import XCTest
import Shared
@testable import Storage

/// Covers the compressed WAL payload format (LZ4, lossless):
/// - a stored frame is compressed on disk and round-trips byte-for-byte, stride included
/// - pre-existing raw BGRA records (legacy layout, identical header) read unchanged
/// - a non-raw-sized record without the compressed signature is rejected
/// - a record carrying the signature that fails to decompress is rejected
/// - invalid header dimensions/stride are rejected
/// - an incompressible frame is stored raw (fallback)
final class WALManagerCompressedPayloadTests: XCTestCase {
    private var walRoot: URL!

    override func setUp() {
        super.setUp()
        walRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wal-compressed-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let walRoot {
            try? FileManager.default.removeItem(at: walRoot)
        }
        super.tearDown()
    }

    // MARK: - Lossless round-trip

    func testStoredFrameIsCompressedAndRoundTripsExactly() async throws {
        let wal = WALManager(walRoot: walRoot)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 1))
        // Padded stride on purpose: lossless storage must preserve it exactly.
        let frame = Self.makeGradientFrame(width: 64, height: 64, bytesPerRow: 64 * 4 + 16, seed: 30)

        try await wal.appendFrame(frame, to: &session)

        let framesSize = try Self.fileSize(session.framesURL)
        XCTAssertGreaterThan(framesSize, 0)
        XCTAssertLessThan(framesSize, frame.imageData.count, "frames.bin should hold a compressed payload, not raw BGRA")

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.imageData, frame.imageData, "lossless: pixels must round-trip byte-for-byte")
        XCTAssertEqual(read.width, frame.width)
        XCTAssertEqual(read.height, frame.height)
        XCTAssertEqual(read.bytesPerRow, frame.bytesPerRow, "original stride must be preserved")
        XCTAssertEqual(read.metadata.appBundleID, frame.metadata.appBundleID)
        XCTAssertEqual(read.metadata.windowName, frame.metadata.windowName)
    }

    // MARK: - Backward compatibility

    func testLegacyRawRecordStillReadsUnchanged() async throws {
        let wal = WALManager(walRoot: walRoot)
        let session = try await wal.createSession(videoID: VideoSegmentID(value: 2))
        let width = 8, height = 4, bytesPerRow = 40
        let raw = Data((0..<(bytesPerRow * height)).map { UInt8($0 % 251) })
        try Self.writeRecord(to: session.framesURL, payload: raw, width: width, height: height, bytesPerRow: bytesPerRow)

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.imageData, raw, "raw payload must be returned byte-for-byte")
        XCTAssertEqual(read.bytesPerRow, bytesPerRow, "raw path must preserve the original bytesPerRow")
    }

    // MARK: - Malformed records

    func testNonRawSizedPayloadWithoutSignatureIsRejected() async throws {
        let wal = WALManager(walRoot: walRoot)
        let session = try await wal.createSession(videoID: VideoSegmentID(value: 3))
        // Not raw-sized (64*4*64 = 16384) and no RWZ4 prefix: must not be treated as raw.
        try Self.writeRecord(
            to: session.framesURL,
            payload: Data(repeating: 0x5A, count: 100),
            width: 64, height: 64, bytesPerRow: 64 * 4
        )
        await Self.assertThrows(try await wal.readFrame(videoID: session.videoID, frameIndex: 0),
                                "a short payload without the signature must be rejected")
    }

    func testCorruptCompressedRecordIsRejected() async throws {
        let wal = WALManager(walRoot: walRoot)
        let session = try await wal.createSession(videoID: VideoSegmentID(value: 4))
        var corrupt = Data("RWZ4".utf8)
        corrupt.append(Data((0..<200).map { _ in UInt8.random(in: 0...255) }))
        try Self.writeRecord(to: session.framesURL, payload: corrupt, width: 64, height: 64, bytesPerRow: 64 * 4)
        await Self.assertThrows(try await wal.readFrame(videoID: session.videoID, frameIndex: 0),
                                "a signed payload that does not decompress to the raw size must be rejected")
    }

    func testInvalidHeaderStrideIsRejected() async throws {
        let wal = WALManager(walRoot: walRoot)
        let session = try await wal.createSession(videoID: VideoSegmentID(value: 5))
        // bytesPerRow smaller than width*4 can never describe a BGRA frame.
        let bogus = Data(repeating: 0x11, count: 8 * 4)
        try Self.writeRecord(to: session.framesURL, payload: bogus, width: 8, height: 4, bytesPerRow: 8)
        await Self.assertThrows(try await wal.readFrame(videoID: session.videoID, frameIndex: 0),
                                "an impossible stride must be rejected")
    }

    // MARK: - Fallback

    func testIncompressibleFrameIsStoredRaw() async throws {
        let wal = WALManager(walRoot: walRoot)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 6))
        // Random bytes cannot shrink under LZ4 (and the prefix adds 4 bytes), so raw wins.
        let raw = Data((0..<(8 * 4 * 8)).map { _ in UInt8.random(in: 0...255) })
        let frame = CapturedFrame(imageData: raw, width: 8, height: 8, bytesPerRow: 8 * 4)

        try await wal.appendFrame(frame, to: &session)

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.imageData, raw, "raw fallback must be byte-for-byte")
        XCTAssertEqual(read.bytesPerRow, frame.bytesPerRow)
    }

    // MARK: - Helpers

    private static func makeGradientFrame(width: Int, height: Int, bytesPerRow: Int, seed: UInt8) -> CapturedFrame {
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

    private static func assertThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail(message, file: file, line: line)
        } catch {
            // expected
        }
    }

    /// Writes one record in the on-disk layout: 36-byte header (native endianness,
    /// same field order as WALFrameHeader), no metadata strings, then the payload.
    private static func writeRecord(to framesURL: URL, payload: Data, width: Int, height: Int, bytesPerRow: Int) throws {
        var record = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { record.append(contentsOf: $0) } }
        append(Double(1_700_000_000))   // timestamp
        append(UInt32(width))
        append(UInt32(height))
        append(UInt32(bytesPerRow))
        append(UInt32(payload.count))   // dataSize
        append(UInt32(1))               // displayID
        append(UInt16(0)); append(UInt16(0)); append(UInt16(0)); append(UInt16(0))
        XCTAssertEqual(record.count, 36, "header must be 36 bytes")
        record.append(payload)
        try record.write(to: framesURL)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
