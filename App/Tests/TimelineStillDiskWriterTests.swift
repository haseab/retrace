import XCTest
import Shared
import Database
@testable import App

final class TimelineStillDiskWriterTests: XCTestCase {
    func testCaptureWriterPrunesExpiredStillsWithoutOpeningTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let expired = directory.appendingPathComponent("100.jpg")
        let recent = directory.appendingPathComponent("101.jpg")
        let unrelated = directory.appendingPathComponent("notes.jpg")
        for url in [expired, recent, unrelated] {
            try Data(repeating: 1, count: 16).write(to: url)
        }
        for url in [expired, unrelated] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-21 * 60)],
                ofItemAtPath: url.path
            )
        }
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedStill = nested.appendingPathComponent("99.jpg")
        try Data([9]).write(to: nestedStill)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-21 * 60)], ofItemAtPath: nestedStill.path
        )
        let link = directory.appendingPathComponent("98.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nestedStill)

        let writer = TimelineStillDiskWriter(
            bufferLimit: 1,
            destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData },
            warningLogger: { _ in },
            processingStatuses: { Dictionary(uniqueKeysWithValues: $0.map { ($0, 2) }) }
        )
        await writer.enqueue(frameID: 102, frame: makeCapturedFrame(marker: 2))
        await waitForCleanups(1, writer: writer)
        await writer.shutdown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try Data(contentsOf: nestedStill), Data([9]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), nestedStill.path)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("102.jpg")), Data(repeating: 2, count: 16))
    }

    func testCaptureWriterRepeatsCleanupAsRecordingContinues() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TimelineStillDiskWriter(
            bufferLimit: 1,
            destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData },
            warningLogger: { _ in },
            cleanupPolicy: .init(interval: 0),
            processingStatuses: { Dictionary(uniqueKeysWithValues: $0.map { ($0, 2) }) }
        )
        await writer.enqueue(frameID: 1, frame: makeCapturedFrame(marker: 1))
        await waitForCleanups(1, writer: writer)
        let first = directory.appendingPathComponent("1.jpg")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-21 * 60)], ofItemAtPath: first.path
        )

        await writer.enqueue(frameID: 2, frame: makeCapturedFrame(marker: 2))
        await waitForCleanups(2, writer: writer)
        await writer.shutdown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("2.jpg")), Data(repeating: 2, count: 16))
    }

    func testCaptureWriterThrottlesDirectorySweepsBetweenWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TimelineStillDiskWriter(
            bufferLimit: 1,
            destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData },
            warningLogger: { _ in },
            processingStatuses: { Dictionary(uniqueKeysWithValues: $0.map { ($0, 2) }) }
        )
        await writer.enqueue(frameID: 1, frame: makeCapturedFrame(marker: 1))
        await waitForCleanups(1, writer: writer)
        let first = directory.appendingPathComponent("1.jpg")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-21 * 60)], ofItemAtPath: first.path
        )

        await writer.enqueue(frameID: 2, frame: makeCapturedFrame(marker: 2))
        await writer.shutdown()

        // The first sweep has already run; do not rescan the directory on every capture.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testCaptureWriterEvictsOldestRecentStillsWhenOverByteBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        for id in 1...3 {
            let url = directory.appendingPathComponent("\(id).jpg")
            try Data(repeating: UInt8(id), count: 16).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(TimeInterval(id - 10))], ofItemAtPath: url.path
            )
        }
        let writer = TimelineStillDiskWriter(
            bufferLimit: 1,
            destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData },
            warningLogger: { _ in },
            cleanupPolicy: .init(maxBytes: 32),
            processingStatuses: { Dictionary(uniqueKeysWithValues: $0.map { ($0, 2) }) }
        )
        await writer.enqueue(frameID: 4, frame: makeCapturedFrame(marker: 4))
        await waitForCleanups(1, writer: writer)
        await writer.shutdown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("1.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("2.jpg").path))
        for id in 3...4 {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("\(id).jpg")), Data(repeating: UInt8(id), count: 16))
        }
    }

    private func waitForWrites(_ count: Int, writer: TimelineStillDiskWriter) async {
        for _ in 0..<200 {
            if await writer.diagnosticsSnapshot().writtenCount >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for capture still writer")
    }

    func testCleanupPreservesUnreadableStillsUntilDatabaseMarksThemReadable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = DatabaseManager()
        try await database.initialize()
        let segmentID = try await database.insertSegment(
            bundleID: "test.cache", startDate: Date(), endDate: Date(),
            windowName: nil, browserUrl: nil, type: 0
        )
        var frameIDs: [Int64] = []
        for index in 0..<2 {
            let id = try await database.insertFrame(FrameReference(
                id: FrameID(value: 0), timestamp: Date(), segmentID: AppSegmentID(value: segmentID),
                frameIndexInSegment: index, metadata: .empty, source: .native
            ))
            frameIDs.append(id)
            let url = directory.appendingPathComponent("\(id).jpg")
            try Data(repeating: 1, count: 16).write(to: url)
            if index == 0 {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-21 * 60)], ofItemAtPath: url.path
                )
            }
        }
        let writer = TimelineStillDiskWriter(
            bufferLimit: 1,
            destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData }, warningLogger: { _ in },
            cleanupPolicy: .init(interval: 0, maxBytes: 0),
            processingStatuses: { try await database.getFrameProcessingStatuses(frameIDs: $0) }
        )
        await writer.enqueue(frameID: 900, frame: makeCapturedFrame(marker: 1))
        await waitForCleanups(1, writer: writer)
        for id in frameIDs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).jpg").path))
            try await database.markFrameReadable(frameID: id)
        }
        await writer.enqueue(frameID: 901, frame: makeCapturedFrame(marker: 2))
        await waitForCleanups(2, writer: writer)
        for id in frameIDs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).jpg").path))
        }
        // Missing database rows must not be assumed readable.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("900.jpg").path))
        await writer.shutdown()
        try await database.close()
    }

    func testSlowCleanupDoesNotBlockNewPreviewsOrShutdown() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = directory.appendingPathComponent("100.jpg")
        try Data([1]).write(to: expired)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-21 * 60)], ofItemAtPath: expired.path
        )
        let gate = CleanupGate()
        let entered = expectation(description: "cleanup reached status lookup")
        let writer = TimelineStillDiskWriter(
            bufferLimit: 1,
            destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData }, warningLogger: { _ in },
            cleanupPolicy: .init(interval: 0),
            processingStatuses: { ids in
                entered.fulfill()
                await gate.wait()
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, 2) })
            }
        )
        await writer.enqueue(frameID: 1, frame: makeCapturedFrame(marker: 1))
        await fulfillment(of: [entered], timeout: 2)
        for id in 2...6 {
            await writer.enqueue(frameID: Int64(id), frame: makeCapturedFrame(marker: UInt8(id)))
            await waitForWrites(id, writer: writer)
        }
        let shutdownFinished = expectation(description: "shutdown without waiting for cleanup")
        Task {
            await writer.shutdown()
            shutdownFinished.fulfill()
        }
        await fulfillment(of: [shutdownFinished], timeout: 2)
        await gate.release()
        await waitForCleanups(1, writer: writer)
        let diagnostics = await writer.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.droppedCount, 0)
        XCTAssertEqual(diagnostics.cleanupCount, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("6.jpg")), Data(repeating: 6, count: 16))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expired.path), "Cancelled cleanup must not delete after status lookup resumes")
    }

    func testCleanupPreservesStillsWhenStatusLookupFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = directory.appendingPathComponent("100.jpg")
        try Data([1]).write(to: expired)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-21 * 60)], ofItemAtPath: expired.path
        )
        let writer = TimelineStillDiskWriter(
            bufferLimit: 1, destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData }, warningLogger: { _ in },
            cleanupPolicy: .init(maxBytes: 0),
            processingStatuses: { _ in throw NSError(domain: "DatabaseUnavailable", code: 1) }
        )
        await writer.enqueue(frameID: 1, frame: makeCapturedFrame(marker: 1))
        await waitForCleanups(1, writer: writer)
        await writer.shutdown()
        XCTAssertEqual(try Data(contentsOf: expired), Data([1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("1.jpg").path))
    }

    func testFailedPreviewWriteStillSchedulesCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = directory.appendingPathComponent("100.jpg")
        try Data([1]).write(to: expired)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-21 * 60)], ofItemAtPath: expired.path
        )
        // A directory at the destination makes the atomic JPEG write fail using real filesystem I/O.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("1.jpg"), withIntermediateDirectories: true)
        let writer = TimelineStillDiskWriter(
            bufferLimit: 1, destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData }, warningLogger: { _ in },
            processingStatuses: { Dictionary(uniqueKeysWithValues: $0.map { ($0, 2) }) }
        )
        await writer.enqueue(frameID: 1, frame: makeCapturedFrame(marker: 1))
        await waitForCleanups(1, writer: writer)
        await writer.shutdown()
        let diagnostics = await writer.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.failureCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
    }

    func testCleanupPreservesPreviewReplacedWhileCheckingDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = directory.appendingPathComponent("100.jpg")
        try Data([1]).write(to: expired)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-21 * 60)], ofItemAtPath: expired.path
        )
        let replacement = Data(repeating: 9, count: 64)
        let writer = TimelineStillDiskWriter(
            bufferLimit: 1, destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData }, warningLogger: { _ in },
            processingStatuses: { ids in
                // Reproduce an atomic timeline cache write during the database await.
                try replacement.write(to: expired, options: [.atomic])
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, 2) })
            }
        )
        await writer.enqueue(frameID: 1, frame: makeCapturedFrame(marker: 1))
        await waitForCleanups(1, writer: writer)
        await writer.shutdown()
        XCTAssertEqual(try Data(contentsOf: expired), replacement)
    }

    func testLargeBacklogCleanupUsesBoundedStatusQueries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in 100...4195 {
            let url = directory.appendingPathComponent("\(id).jpg")
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-21 * 60)], ofItemAtPath: url.path
            )
        }
        let writer = TimelineStillDiskWriter(
            bufferLimit: 1, destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData }, warningLogger: { _ in },
            processingStatuses: { ids in
                XCTAssertLessThanOrEqual(ids.count, 128)
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, 2) })
            }
        )
        await writer.enqueue(frameID: 1, frame: makeCapturedFrame(marker: 1))
        await waitForCleanups(1, writer: writer)
        await writer.shutdown()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["1.jpg"])
    }

    private actor CleanupGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func waitForCleanups(_ count: Int, writer: TimelineStillDiskWriter) async {
        for _ in 0..<500 {
            if await writer.diagnosticsSnapshot().cleanupCount >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for cache cleanup")
    }

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
