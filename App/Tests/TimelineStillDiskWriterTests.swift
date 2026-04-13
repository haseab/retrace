import XCTest
import Shared
@testable import App

final class TimelineStillDiskWriterTests: XCTestCase {
    private func makeCapturedFrame(marker: UInt8) -> CapturedFrame {
        CapturedFrame(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(marker)),
            imageData: Data(repeating: marker, count: 16),
            width: 2,
            height: 2,
            bytesPerRow: 8,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Frame \(marker)",
                browserURL: "https://example.com/\(marker)",
                displayID: 1
            )
        )
    }

    func testTimelineStillDiskWriterDropsBackloggedFramesAndKeepsNewestPendingFrame() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let writer = TimelineStillDiskWriter(
            bufferLimit: 1,
            destinationResolver: { frameID in
                outputDirectory.appendingPathComponent("\(frameID).jpg")
            },
            encoder: { frame in
                Thread.sleep(forTimeInterval: 0.05)
                return frame.imageData
            },
            warningLogger: { _ in }
        )

        for marker in UInt8(1)...5 {
            await writer.enqueue(frameID: Int64(marker), frame: makeCapturedFrame(marker: marker))
        }

        await writer.shutdown()

        let diagnostics = await writer.diagnosticsSnapshot()
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        XCTAssertGreaterThanOrEqual(diagnostics.droppedCount, 1)
        XCTAssertEqual(diagnostics.failureCount, 0)
        XCTAssertEqual(diagnostics.terminatedEnqueueCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.writtenCount, 2)
        XCTAssertLessThanOrEqual(fileURLs.count, 2)

        let newestFrameURL = outputDirectory.appendingPathComponent("5.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newestFrameURL.path))
        XCTAssertEqual(try Data(contentsOf: newestFrameURL), Data(repeating: 5, count: 16))
    }
}
