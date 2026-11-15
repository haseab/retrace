import AppKit
import XCTest
@testable import Retrace

final class PreviewCacheMaintenanceTests: XCTestCase {
    func testOneFrameEvictionDoesNotCancelUnrelatedQueuedWrite() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "preview-entry-eviction-test")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        defer { gate.signal() }
        let worker = PreviewCacheDiskWorker(queue: queue)
        var entries = PreviewCacheEntryEpochs<Int>()
        let first = entries.epoch(for: 1)
        let firstToken = first.current
        let second = entries.epoch(for: 2)
        let secondToken = second.current
        let data = try fixtureJPEG()
        worker.enqueueWrite(data, to: root.appendingPathComponent("one.jpg"), allowed: { first.matches(firstToken) })
        worker.enqueueWrite(data, to: root.appendingPathComponent("two.jpg"), allowed: { second.matches(secondToken) })
        entries.invalidate([2])
        gate.signal()
        await worker.flush()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("one.jpg")), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("two.jpg").path))
    }

    func testFinishedMissesReleaseEpochsWithoutCancellingSameFrameWriter() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var entries = PreviewCacheEntryEpochs<Int>()
        for key in 0..<1000 {
            let epoch = entries.epoch(for: key)
            entries.finish(key, epoch: epoch, keep: false)
        }
        XCTAssertEqual(entries.count, 0)
        let read = entries.epoch(for: 1)
        let write = entries.epoch(for: 1)
        let token = write.current
        entries.finish(1, epoch: read, keep: false)
        let worker = PreviewCacheDiskWorker()
        let data = try fixtureJPEG()
        worker.enqueueWrite(data, to: root.appendingPathComponent("one.jpg"), allowed: { write.matches(token) })
        await worker.flush()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("one.jpg")), data)
        entries.finish(1, epoch: write, keep: true)
        entries.invalidate([1])
        XCTAssertFalse(write.matches(token))
        XCTAssertEqual(entries.count, 0)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("preview-cache-" + UUID().uuidString)
    }

    func testBurstWritesShareOneTrimAndStayWithinDiskBudget() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = PreviewCacheDiskWorker()
        let data = try fixtureJPEG()
        for index in 0..<30 {
            worker.enqueueWrite(data, to: root.appendingPathComponent("\(index).jpg"), allowed: { true }, trim: .init(directory: root, maxBytes: Int64(data.count * 5), maxAge: 3600))
        }
        await worker.flush()
        let stats = await worker.statistics()
        XCTAssertEqual(stats.trimPasses, 1)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        XCTAssertLessThanOrEqual(bytes, data.count * 5)
    }

    func testQueuedDeletionCannotDeleteLaterWriteToSamePath() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = PreviewCacheDiskWorker()
        let url = root.appendingPathComponent("1.jpg")
        let data = try fixtureJPEG()
        worker.enqueueWrite(data, to: url, allowed: { true })
        worker.removeFiles([url])
        worker.enqueueWrite(data, to: url, allowed: { true })
        await worker.flush()
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testInvalidatedQueuedWritesCannotRepopulateDisk() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "preview-test-blocked")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let worker = PreviewCacheDiskWorker(queue: queue)
        let epoch = PreviewCacheEpoch()
        let token = epoch.current
        let url = root.appendingPathComponent("1.jpg")
        worker.enqueueWrite(try fixtureJPEG(), to: url, allowed: { epoch.matches(token) })
        epoch.invalidate()
        gate.signal()
        await worker.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPruningPreservesNewAndUnrelatedFiles() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("1.jpg")
        let recent = root.appendingPathComponent("2.jpg")
        let unrelated = root.appendingPathComponent("notes.txt")
        for url in [old, recent, unrelated] { try fixtureJPEG().write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        let worker = PreviewCacheDiskWorker()
        worker.pruneTimelineFiles(in: root, olderThan: Date().addingTimeInterval(-60))
        await worker.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testByteAccountingTracksRealFileReplacementTouchAndRemoval() throws {
        struct Entry { let bytes: Int64; var access: Int }
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("1.jpg")
        let data = try fixtureJPEG()
        try data.write(to: url)
        var index = ByteCountedCacheIndex<String, Entry>(cost: { $0.bytes })
        index["frame"] = Entry(bytes: Int64(try Data(contentsOf: url).count), access: 0)
        index["frame"]?.access = 1
        XCTAssertEqual(index.totalBytes, Int64(data.count))
        try data.prefix(data.count / 2).write(to: url)
        index["frame"] = Entry(bytes: Int64(try Data(contentsOf: url).count), access: 2)
        XCTAssertEqual(index.totalBytes, Int64(data.count / 2))
        index.removeValue(forKey: "frame")
        XCTAssertEqual(index.totalBytes, 0)
        index.removeAll()
        XCTAssertEqual(index.count, 0)
    }

    func testDifferentCropsAndRevisionsUseIndependentDiskImages() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try XCTUnwrap(NSImage(data: fixtureJPEG()))
        let source = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let worker = PreviewCacheDiskWorker()
        var urls: [URL] = []
        var payloads: [Data] = []
        for (index, normalized) in [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)].enumerated() {
            let crop = try XCTUnwrap(source.cropping(to: CGRect(x: normalized.minX * Double(source.width), y: 0, width: normalized.width * Double(source.width), height: Double(source.height))))
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: crop).representation(using: .jpeg, properties: [.compressionFactor: 0.7]))
            let key = PreviewThumbnailIdentity.key(source: "native", frameID: 1, videoID: 2, frameIndex: 0, timestamp: 1000, size: CGSize(width: 280, height: 175), highlight: normalized, revision: "original")
            let url = root.appendingPathComponent(Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".jpg")
            worker.enqueueWrite(data, to: url, allowed: { true })
            urls.append(url); payloads.append(data)
            XCTAssertTrue(index == 0 || urls[0] != urls[1])
        }
        await worker.flush()
        XCTAssertTrue(payloads[0] != payloads[1])
        for (url, expected) in zip(urls, payloads) { XCTAssertEqual(try Data(contentsOf: url), expected) }
        let revised = PreviewThumbnailIdentity.key(source: "native", frameID: 1, videoID: 2, frameIndex: 0, timestamp: 1000, size: CGSize(width: 280, height: 175), highlight: nil, revision: "redacted")
        let original = PreviewThumbnailIdentity.key(source: "native", frameID: 1, videoID: 2, frameIndex: 0, timestamp: 1000, size: CGSize(width: 280, height: 175), highlight: nil, revision: "original")
        XCTAssertTrue(revised != original)
    }

    func testInvalidationDuringWriteRemovesTheWrittenPreview() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = PreviewCacheDiskWorker()
        let epoch = PreviewCacheEpoch()
        let token = epoch.current
        let url = root.appendingPathComponent("1.jpg")
        worker.enqueueWrite(try fixtureJPEG(), to: url, allowed: {
            defer { epoch.invalidate() }
            return epoch.matches(token)
        })
        await worker.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBackloggedPayloadsAreBounded() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = PreviewCacheDiskWorker(maximumPendingBytes: 1)
        let url = root.appendingPathComponent("1.jpg")
        let data = try fixtureJPEG()
        let retained = await withCheckedContinuation { continuation in
            worker.enqueueWrite(data, to: url, allowed: { true }, completion: { continuation.resume(returning: $0) })
        }
        await worker.flush()
        XCTAssertFalse(retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTrimRunsAutomaticallyWithoutExplicitFlush() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try fixtureJPEG()
        for index in 0..<8 { try data.write(to: root.appendingPathComponent("\(index).jpg")) }
        let worker = PreviewCacheDiskWorker()
        worker.requestTrim(.init(directory: root, maxBytes: Int64(data.count * 3), maxAge: 3600))
        var passes = 0
        for _ in 0..<200 {
            passes = await worker.statistics().trimPasses
            if passes > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(passes, 1)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        worker.removeFiles(files)
        await worker.flush()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    private func fixtureJPEG() throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let image = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("UI/Assets.xcassets/InPageURLInstructions.imageset/safari_instructions.png")))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]))
    }
}
