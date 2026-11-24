import Foundation
import CoreGraphics
import ImageIO
import SQLCipher
import Shared
import Database
@testable import App

import XCTest

final class RecordingDatabaseFailureTests: XCTestCase {
    func testFrameInsertFailureDoesNotDesynchronizeEncoderCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingDatabaseFailure_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = StorageConfig(storageRootPath: root.path, retentionDays: nil, maxStorageGB: nil, segmentDurationSeconds: 300)
        let services = ServiceContainer(databasePath: root.appendingPathComponent("test.db").path, storageConfig: config,
                                        storageCrashReportDirectory: root.appendingPathComponent("crash_reports").path)
        let database = await services.database
        let storage = await services.storage
        try await database.initialize()
        try await storage.initialize(config: config)
        do {
            let connection = await database.getConnection()
            let db = try XCTUnwrap(connection)
            let frame = try screenshotFrame()
            let stream = AsyncStream<CapturedFrame> { continuation in
                for index in 0..<3 {
                    continuation.yield(CapturedFrame(
                        timestamp: frame.timestamp.addingTimeInterval(Double(index)), imageData: frame.imageData,
                        width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, metadata: frame.metadata
                    ))
                }
                continuation.finish()
            }
            let coordinator = AppCoordinator(services: services)
            // Keep the one-shot failure outside the database transaction. A
            // trigger counter rolls back with the failed native insert and
            // accidentally fails every frame rather than only the first one.
            let failure = FrameInsertFailureGate()
            sqlite3_set_authorizer(db, { context, action, table, _, _, _ in
                guard action == SQLITE_INSERT, let table, String(cString: table) == "frame",
                      let context else { return SQLITE_OK }
                let failure = Unmanaged<FrameInsertFailureGate>.fromOpaque(context).takeUnretainedValue()
                guard !failure.didFail else { return SQLITE_OK }
                failure.didFail = true
                return SQLITE_DENY
            }, Unmanaged.passUnretained(failure).toOpaque())
            await coordinator.runPipeline(frameStream: stream, cacheCapturedStills: false, reportUnexpectedStops: false)
            sqlite3_set_authorizer(db, nil, nil)
            XCTAssertTrue(failure.didFail)
            let frames = try await database.getFrames(from: frame.timestamp.addingTimeInterval(-1), to: frame.timestamp.addingTimeInterval(5), limit: 10)
            XCTAssertEqual(frames.count, 2)
            XCTAssertEqual(frames.map(\.frameIndexInSegment).sorted(), [1, 2])
            let firstFrame = try XCTUnwrap(frames.first)
            let videoResult = try await database.getVideoSegment(id: firstFrame.videoID)
            let video = try XCTUnwrap(videoResult)
            XCTAssertEqual(video.frameCount, 3)
            let bytes = try await storage.readFrame(segmentID: VideoSegmentID(value: Int64(video.relativePath.split(separator: "/").last!)!), frameIndex: 2)
            XCTAssertFalse(bytes.isEmpty)
            try await database.close()
        } catch {
            try? await database.close()
            throw error
        }
    }

    private func screenshotFrame() throws -> CapturedFrame {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent("UI/Assets.xcassets/InPageURLInstructions.imageset/safari_instructions.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = 320, height = 240, stride = width * 4
        var data = Data(count: stride * height)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_775_300_000), imageData: data, width: width, height: height,
                             bytesPerRow: stride, metadata: FrameMetadata(appBundleID: "com.example.recording-regression", appName: "Recording regression"))
    }
}

private final class FrameInsertFailureGate {
    var didFail = false
}
