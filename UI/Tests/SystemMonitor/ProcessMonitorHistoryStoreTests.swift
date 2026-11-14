import Foundation
import XCTest
@testable import Retrace

final class ProcessMonitorHistoryStoreTests: XCTestCase {
    struct Bucket: ProcessMonitorHistoryBucket {
        let startTimestamp: TimeInterval
        var cpuNanoseconds: UInt64
    }

    struct State: ProcessMonitorHistoryState {
        var latestSampleTimestamp: TimeInterval
        var buckets: [Bucket]
    }

    private func withDirectory(_ test: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(root.appendingPathComponent("tally.json"))
    }

    private func state(_ count: Int = 180) -> State {
        State(latestSampleTimestamp: 10_800, buckets: (0..<count).map {
            Bucket(startTimestamp: Double($0 * 60), cpuNanoseconds: UInt64($0 + 1))
        })
    }

    func testIncrementalWriteLeavesCheckpointAndJournalPrefixUnchanged() throws {
        try withDirectory { url in
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            var history = state()
            try store.save(history, at: Date(timeIntervalSince1970: 0))
            let checkpoint = try Data(contentsOf: url)
            history.latestSampleTimestamp += 15
            history.buckets[179].cpuNanoseconds += 10
            try store.save(history, at: Date(timeIntervalSince1970: 15))
            let prefix = try Data(contentsOf: store.journalURL)
            history.latestSampleTimestamp += 15
            history.buckets[179].cpuNanoseconds += 20
            try store.save(history, at: Date(timeIntervalSince1970: 30))
            let journal = try Data(contentsOf: store.journalURL)
            XCTAssertEqual(try Data(contentsOf: url), checkpoint)
            XCTAssertTrue(journal.starts(with: prefix))
            XCTAssertLessThan(journal.count, checkpoint.count / 5)
            XCTAssertEqual(try ProcessMonitorHistoryStore<State>(checkpointURL: url).load(), history)
        }
    }

    func testPrunedAndDownsampledBucketsSurviveRelaunch() throws {
        try withDirectory { url in
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            var history = state()
            try store.save(history)
            history.buckets.removeFirst(30)
            history.buckets.replaceSubrange(0..<5, with: [Bucket(startTimestamp: 1800, cpuNanoseconds: 1234)])
            history.latestSampleTimestamp += 60
            try store.save(history)
            XCTAssertEqual(try ProcessMonitorHistoryStore<State>(checkpointURL: url).load(), history)
        }
    }

    func testReadsLegacyJSONAndMigratesWithoutLosingHistory() throws {
        try withDirectory { url in
            var history = state()
            try JSONEncoder().encode(history).write(to: url)
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            XCTAssertEqual(try store.load(), history)
            history.buckets[179].cpuNanoseconds += 30
            try store.save(history)
            XCTAssertEqual(try ProcessMonitorHistoryStore<State>(checkpointURL: url).load(), history)
        }
    }

    func testIncompleteAppendIsDiscardedBeforeNextSave() throws {
        try withDirectory { url in
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            var history = state()
            try store.save(history)
            history.latestSampleTimestamp += 15
            try store.save(history)
            let handle = try FileHandle(forWritingTo: store.journalURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"partial\":".utf8))
            try handle.close()
            let reopened = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            XCTAssertEqual(try reopened.load(), history)
            history.latestSampleTimestamp += 15
            try reopened.save(history)
            XCTAssertEqual(try ProcessMonitorHistoryStore<State>(checkpointURL: url).load(), history)
        }
    }

    func testCheckpointReplayDoesNotDoubleCountOldJournal() throws {
        try withDirectory { url in
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url, checkpointInterval: 60)
            var history = state()
            try store.save(history, at: Date(timeIntervalSince1970: 0))
            history.latestSampleTimestamp += 15
            try store.save(history, at: Date(timeIntervalSince1970: 15))
            let oldJournal = try Data(contentsOf: store.journalURL)
            history.buckets[179].cpuNanoseconds += 10
            try store.save(history, at: Date(timeIntervalSince1970: 60))
            // Simulate interruption after the atomic checkpoint but before journal truncation.
            try oldJournal.write(to: store.journalURL)
            XCTAssertEqual(try ProcessMonitorHistoryStore<State>(checkpointURL: url).load(), history)
        }
    }

    func testResetCannotResurrectOldBucketsFromJournal() throws {
        try withDirectory { url in
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            var history = state()
            try store.save(history)
            history.latestSampleTimestamp += 15
            try store.save(history)
            let oldJournal = try Data(contentsOf: store.journalURL)
            let empty = state(0)
            try store.reset(to: empty)
            try oldJournal.write(to: store.journalURL)
            XCTAssertEqual(try ProcessMonitorHistoryStore<State>(checkpointURL: url).load(), empty)
        }
    }

    func testSizeLimitCompactsJournal() throws {
        try withDirectory { url in
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url, maximumJournalBytes: 512)
            var history = state()
            try store.save(history)
            for _ in 0..<30 {
                history.latestSampleTimestamp += 15
                history.buckets[179].cpuNanoseconds += 1
                try store.save(history)
                XCTAssertLessThanOrEqual(try Data(contentsOf: store.journalURL).count, 512)
            }
            XCTAssertEqual(try ProcessMonitorHistoryStore<State>(checkpointURL: url).load(), history)
        }
    }

    func testFailedAppendCanRetryWithoutLosingPendingUpdate() throws {
        try withDirectory { url in
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            var history = state()
            try store.save(history)
            try FileManager.default.removeItem(at: store.journalURL)
            try FileManager.default.createDirectory(at: store.journalURL, withIntermediateDirectories: false)
            history.buckets[179].cpuNanoseconds += 10
            XCTAssertThrowsError(try store.save(history))
            try FileManager.default.removeItem(at: store.journalURL)
            try store.save(history)
            XCTAssertEqual(try ProcessMonitorHistoryStore<State>(checkpointURL: url).load(), history)
        }
    }

    func testUnchangedHistoryDoesNotWrite() throws {
        try withDirectory { url in
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            let history = state()
            try store.save(history)
            let checkpoint = try Data(contentsOf: url)
            try store.save(history)
            XCTAssertEqual(try Data(contentsOf: url), checkpoint)
            XCTAssertEqual(try Data(contentsOf: store.journalURL).count, 0)
        }
    }

    func testMalformedCompleteRecordFailsWithoutOverwritingEvidence() throws {
        try withDirectory { url in
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            try store.save(state())
            let damaged = Data("invalid record\n".utf8)
            try damaged.write(to: store.journalURL)
            let reopened = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            XCTAssertThrowsError(try reopened.load())
            XCTAssertThrowsError(try reopened.save(state()))
            XCTAssertEqual(try Data(contentsOf: store.journalURL), damaged)
        }
    }

    func testExplicitResetCanDiscardCorruptHistory() throws {
        try withDirectory { url in
            try Data("corrupt checkpoint".utf8).write(to: url)
            let store = ProcessMonitorHistoryStore<State>(checkpointURL: url)
            try Data("corrupt journal\n".utf8).write(to: store.journalURL)
            let empty = state(0)
            try store.reset(to: empty)
            XCTAssertEqual(try ProcessMonitorHistoryStore<State>(checkpointURL: url).load(), empty)
        }
    }

    func testLiveSamplerKeepsIdleHistoryAndFlushesPendingSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sampler = ProcessCPULogSampler(storageRoot: root)
        let now = Date()
        let url = root.appendingPathComponent("logs/cpu_process_usage_tally.json")
        let journal = url.appendingPathExtension("updates")
        // Read actual OS CPU/memory counters; only the sampling clock is advanced for the save interval.
        for offset: TimeInterval in [0, 15] {
            _ = await sampler.sampleAndMaybeLoadSnapshot(
                windowDuration: 43_200, expectedIntervalSeconds: 15,
                shouldBuildSnapshot: false, at: now.addingTimeInterval(offset)
            )
        }
        let checkpoint = try Data(contentsOf: url)
        _ = await sampler.sampleAndMaybeLoadSnapshot(
            windowDuration: 43_200, expectedIntervalSeconds: 15,
            shouldBuildSnapshot: false, at: now.addingTimeInterval(30)
        )
        XCTAssertEqual(try Data(contentsOf: url), checkpoint)
        XCTAssertEqual(try Data(contentsOf: journal).count, 0)
        _ = await sampler.sampleAndMaybeLoadSnapshot(
            windowDuration: 43_200, expectedIntervalSeconds: 15,
            shouldBuildSnapshot: false, at: now.addingTimeInterval(75)
        )
        XCTAssertEqual(try Data(contentsOf: url), checkpoint)
        XCTAssertGreaterThan(try Data(contentsOf: journal).count, 0)
        _ = await sampler.sampleAndMaybeLoadSnapshot(
            windowDuration: 43_200, expectedIntervalSeconds: 15,
            shouldBuildSnapshot: false, at: now.addingTimeInterval(90)
        )
        let beforeFlush = try Data(contentsOf: journal).count
        await sampler.flush()
        XCTAssertGreaterThan(try Data(contentsOf: journal).count, beforeFlush)
        let reopened = ProcessCPULogSampler(storageRoot: root)
        let snapshot = await reopened.cachedSnapshotFromTally(windowDuration: 43_200)
        XCTAssertEqual(snapshot?.latestSampleTimestamp, now.addingTimeInterval(90).timeIntervalSince1970)
        XCTAssertGreaterThan(snapshot?.totalTrackedCurrentResidentBytes ?? 0, 0)
        await reopened.enterIdleMode(windowDuration: 43_200, warmWindowDuration: 60)
        let afterIdle = await reopened.cachedSnapshotFromTally(windowDuration: 43_200)
        XCTAssertEqual(afterIdle?.latestSampleTimestamp, snapshot?.latestSampleTimestamp)
        _ = await reopened.resetAndLoadSnapshot(windowDuration: 43_200, expectedIntervalSeconds: 15)
        let afterReset = ProcessCPULogSampler(storageRoot: root)
        let resetSnapshot = await afterReset.cachedSnapshotFromTally(windowDuration: 43_200)
        XCTAssertNil(resetSnapshot)
    }

}
