import XCTest
import Foundation
import CoreGraphics
import Shared
import Database
@testable import Processing

private actor RewriteRetryNoopSearch: SearchProtocol {
    func initialize(config: SearchConfig) async throws {}

    func search(query: SearchQuery) async throws -> SearchResults {
        SearchResults(query: query, results: [], searchTimeMs: 0)
    }

    func search(text: String, limit: Int) async throws -> SearchResults {
        SearchResults(
            query: SearchQuery(text: text, limit: limit),
            results: [],
            searchTimeMs: 0
        )
    }

    func getSuggestions(prefix: String, limit: Int) async throws -> [String] {
        []
    }

    func index(text: ExtractedText, segmentId: Int64, frameId: Int64) async throws -> Int64 {
        0
    }

    func removeFromIndex(frameID: FrameID) async throws {}

    func rebuildIndex() async throws {}

    func getStatistics() async -> SearchStatistics {
        SearchStatistics(totalDocuments: 0, totalSearches: 0, averageSearchTimeMs: 0)
    }
}

private actor RewriteRetryNoopProcessing: ProcessingProtocol {
    private var config = ProcessingConfig.default

    func initialize(config: ProcessingConfig) async throws {
        self.config = config
    }

    func extractText(from frame: CapturedFrame) async throws -> ExtractedText {
        ExtractedText(frameID: FrameID(value: 0), timestamp: Date(), regions: [])
    }

    func extractTextViaOCR(from frame: CapturedFrame) async throws -> [TextRegion] {
        []
    }

    func extractTextViaAccessibility() async throws -> [TextRegion] {
        []
    }

    func updateConfig(_ config: ProcessingConfig) async {
        self.config = config
    }

    func getConfig() async -> ProcessingConfig {
        config
    }
}

private enum RewriteRetryStorageError: Error {
    case simulatedFailure
}

private protocol RewriteAttemptCountingStorage: Actor {
    func appliedRewriteAttemptCount() -> Int
}

private actor RewriteRetryStubSegmentWriter: SegmentWriter {
    let segmentID = VideoSegmentID(value: 0)
    let frameCount = 0
    let startTime = Date(timeIntervalSince1970: 0)
    let relativePath = "segments/test"
    let frameWidth = 0
    let frameHeight = 0
    let currentFileSize: Int64 = 0
    let hasFragmentWritten = false
    let framesFlushedToDisk = 0

    func appendFrame(_ frame: CapturedFrame) async throws {}

    func finalize() async throws -> VideoSegment {
        VideoSegment(
            id: segmentID,
            startTime: startTime,
            endTime: startTime,
            frameCount: frameCount,
            fileSizeBytes: currentFileSize,
            relativePath: relativePath,
            width: frameWidth,
            height: frameHeight
        )
    }

    func cancel() async throws {}
}

private actor FailingRewriteStorage: StorageProtocol, RewriteAttemptCountingStorage {
    private let failureCount: Int
    private var rewriteAttemptCount = 0

    init(failureCount: Int) {
        self.failureCount = failureCount
    }

    func initialize(config: StorageConfig) async throws {}

    func createSegmentWriter() async throws -> SegmentWriter {
        RewriteRetryStubSegmentWriter()
    }

    func readFrame(segmentID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        Data()
    }

    func getSegmentPath(id: VideoSegmentID) async throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(id.stringValue)
    }

    func deleteSegment(id: VideoSegmentID) async throws {}

    func segmentExists(id: VideoSegmentID) async throws -> Bool {
        true
    }

    func countFramesInSegment(id: VideoSegmentID) async throws -> Int {
        0
    }

    func readFrameFromWAL(
        segmentID: VideoSegmentID,
        frameID: Int64,
        fallbackFrameIndex: Int
    ) async throws -> CapturedFrame? {
        nil
    }

    func applySegmentRewrite(
        segmentID: VideoSegmentID,
        plan: SegmentRewritePlan,
        secret: String?
    ) async throws {
        rewriteAttemptCount += 1
        if rewriteAttemptCount <= failureCount {
            throw RewriteRetryStorageError.simulatedFailure
        }
    }

    func recoverInterruptedSegmentRewrites() async throws -> [SegmentRewriteRecoveryAction] {
        []
    }

    func finishInterruptedSegmentRewriteRecovery(segmentID: VideoSegmentID) async throws {}

    func isVideoValid(id: VideoSegmentID) async throws -> Bool {
        true
    }

    func getTotalStorageUsed(includeRewind: Bool) async throws -> Int64 {
        0
    }

    func getStorageUsedForDateRange(from startDate: Date, to endDate: Date) async throws -> Int64 {
        0
    }

    func getAvailableDiskSpace() async throws -> Int64 {
        0
    }

    func cleanupOldSegments(olderThan date: Date) async throws -> [VideoSegmentID] {
        []
    }

    func getStorageDirectory() -> URL {
        FileManager.default.temporaryDirectory
    }

    func appliedRewriteAttemptCount() -> Int {
        rewriteAttemptCount
    }
}

private actor BlockingRewriteStorage: StorageProtocol, RewriteAttemptCountingStorage {
    private var rewriteAttemptCount = 0
    private var firstRewriteStarted = false
    private var firstRewriteStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var firstRewriteReleaseContinuation: CheckedContinuation<Void, Never>?

    func initialize(config: StorageConfig) async throws {}

    func createSegmentWriter() async throws -> SegmentWriter {
        RewriteRetryStubSegmentWriter()
    }

    func readFrame(segmentID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        Data()
    }

    func getSegmentPath(id: VideoSegmentID) async throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(id.stringValue)
    }

    func deleteSegment(id: VideoSegmentID) async throws {}

    func segmentExists(id: VideoSegmentID) async throws -> Bool {
        true
    }

    func countFramesInSegment(id: VideoSegmentID) async throws -> Int {
        0
    }

    func readFrameFromWAL(
        segmentID: VideoSegmentID,
        frameID: Int64,
        fallbackFrameIndex: Int
    ) async throws -> CapturedFrame? {
        nil
    }

    func applySegmentRewrite(
        segmentID: VideoSegmentID,
        plan: SegmentRewritePlan,
        secret: String?
    ) async throws {
        rewriteAttemptCount += 1

        if rewriteAttemptCount == 1 {
            firstRewriteStarted = true
            let continuations = firstRewriteStartContinuations
            firstRewriteStartContinuations.removeAll(keepingCapacity: false)
            for continuation in continuations {
                continuation.resume()
            }

            await withCheckedContinuation { continuation in
                firstRewriteReleaseContinuation = continuation
            }
        }
    }

    func recoverInterruptedSegmentRewrites() async throws -> [SegmentRewriteRecoveryAction] {
        []
    }

    func finishInterruptedSegmentRewriteRecovery(segmentID: VideoSegmentID) async throws {}

    func isVideoValid(id: VideoSegmentID) async throws -> Bool {
        true
    }

    func getTotalStorageUsed(includeRewind: Bool) async throws -> Int64 {
        0
    }

    func getStorageUsedForDateRange(from startDate: Date, to endDate: Date) async throws -> Int64 {
        0
    }

    func getAvailableDiskSpace() async throws -> Int64 {
        0
    }

    func cleanupOldSegments(olderThan date: Date) async throws -> [VideoSegmentID] {
        []
    }

    func getStorageDirectory() -> URL {
        FileManager.default.temporaryDirectory
    }

    func waitForFirstRewriteToStart() async {
        guard !firstRewriteStarted else { return }

        await withCheckedContinuation { continuation in
            firstRewriteStartContinuations.append(continuation)
        }
    }

    func releaseFirstRewrite() {
        firstRewriteReleaseContinuation?.resume()
        firstRewriteReleaseContinuation = nil
    }

    func appliedRewriteAttemptCount() -> Int {
        rewriteAttemptCount
    }
}

final class RewriteRetryPolicyTests: XCTestCase {
    private var database: DatabaseManager!
    private var queue: FrameProcessingQueue!
    private var storage: FailingRewriteStorage!

    override func setUp() async throws {
        let uniqueDBPath = "file:memdb_processing_retry_\(UUID().uuidString)?mode=memory&cache=private"
        database = DatabaseManager(databasePath: uniqueDBPath)
        try await database.initialize()

        storage = FailingRewriteStorage(failureCount: 2)
        queue = FrameProcessingQueue(
            database: database,
            storage: storage,
            processing: RewriteRetryNoopProcessing(),
            search: RewriteRetryNoopSearch(),
            config: ProcessingQueueConfig(
                workerCount: 1,
                maxRetryAttempts: 3,
                maxQueueSize: 1000,
                retryableRewriteRetryDelayNs: 50_000_000
            )
        )
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
        queue = nil
        storage = nil
    }

    func testFailedRewriteRetriesOnceThenStopsRetryingAutomatically() async throws {
        let fixture = try await insertFrameFixture()

        try await insertIndexedNode(
            frameID: fixture.frameID,
            segmentID: fixture.segmentID,
            text: "secret phrase",
            bounds: CGRect(x: 100, y: 200, width: 300, height: 50),
            redactedNodeOrders: [0]
        )

        try await database.updateFrameProcessingStatus(
            frameID: fixture.frameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )

        _ = try? await queue.processPendingRewrites(for: fixture.videoID.value)

        let firstFailureStatuses = try await database.getFrameProcessingStatuses(
            frameIDs: [fixture.frameID.value]
        )
        XCTAssertEqual(firstFailureStatuses[fixture.frameID.value], 8)

        try await waitForRewriteAttemptCount(2, in: storage)

        let secondFailureStatuses = try await database.getFrameProcessingStatuses(
            frameIDs: [fixture.frameID.value]
        )
        XCTAssertEqual(secondFailureStatuses[fixture.frameID.value], 8)

        try await Task.sleep(for: .milliseconds(200), clock: .continuous)
        let finalRewriteAttemptCount = await storage.appliedRewriteAttemptCount()
        XCTAssertEqual(finalRewriteAttemptCount, 2)
    }

    func testDeferredRewriteForActiveVideoRedrainsAfterCurrentRewriteFinishes() async throws {
        let blockingStorage = BlockingRewriteStorage()
        let blockingQueue = FrameProcessingQueue(
            database: database,
            storage: blockingStorage,
            processing: RewriteRetryNoopProcessing(),
            search: RewriteRetryNoopSearch(),
            config: ProcessingQueueConfig(
                workerCount: 1,
                maxRetryAttempts: 3,
                maxQueueSize: 1000,
                retryableRewriteRetryDelayNs: 50_000_000
            )
        )

        let fixture = try await insertVideoFixture(frameCount: 2)
        let firstFrameID = try await insertFrameReference(
            segmentID: fixture.segmentID,
            videoID: fixture.videoID,
            timestamp: fixture.timestamp,
            frameIndexInSegment: 0
        )

        try await insertIndexedNode(
            frameID: firstFrameID,
            segmentID: fixture.segmentID,
            text: "first secret phrase",
            bounds: CGRect(x: 100, y: 200, width: 300, height: 50),
            redactedNodeOrders: [0]
        )
        try await database.updateFrameProcessingStatus(
            frameID: firstFrameID.value,
            status: FrameProcessingStatus.rewritePending.rawValue,
            rewritePurpose: "redaction"
        )

        let firstRewriteTask = Task {
            try await blockingQueue.processPendingRewrites(for: fixture.videoID.value)
        }
        await blockingStorage.waitForFirstRewriteToStart()

        let secondFrameID = try await insertFrameReference(
            segmentID: fixture.segmentID,
            videoID: fixture.videoID,
            timestamp: fixture.timestamp.addingTimeInterval(1),
            frameIndexInSegment: 1
        )
        try await insertIndexedNode(
            frameID: secondFrameID,
            segmentID: fixture.segmentID,
            text: "second secret phrase",
            bounds: CGRect(x: 150, y: 260, width: 320, height: 60),
            redactedNodeOrders: [0]
        )
        try await database.updateFrameProcessingStatus(
            frameID: secondFrameID.value,
            status: FrameProcessingStatus.rewritePending.rawValue,
            rewritePurpose: "redaction"
        )

        let deferredOutcome = try await blockingQueue.processPendingRewrites(for: fixture.videoID.value)
        XCTAssertEqual(deferredOutcome, .deferred(.rewriteAlreadyInProgress))

        await blockingStorage.releaseFirstRewrite()
        let firstRewriteOutcome = try await firstRewriteTask.value
        XCTAssertEqual(firstRewriteOutcome, .completed)

        try await waitForRewriteAttemptCount(2, in: blockingStorage)

        let statuses = try await database.getFrameProcessingStatuses(
            frameIDs: [firstFrameID.value, secondFrameID.value]
        )
        XCTAssertEqual(statuses[firstFrameID.value], FrameProcessingStatus.rewriteCompleted.rawValue)
        XCTAssertEqual(statuses[secondFrameID.value], FrameProcessingStatus.rewriteCompleted.rawValue)
    }

    private func waitForRewriteAttemptCount<Storage: RewriteAttemptCountingStorage>(
        _ expectedCount: Int,
        in storage: Storage,
        timeoutNs: UInt64 = 1_000_000_000
    ) async throws {
        let start = ContinuousClock.now

        while ContinuousClock.now - start < .nanoseconds(Int64(timeoutNs)) {
            if await storage.appliedRewriteAttemptCount() == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(25), clock: .continuous)
        }

        let actualRewriteAttemptCount = await storage.appliedRewriteAttemptCount()
        XCTAssertEqual(actualRewriteAttemptCount, expectedCount)
    }

    private func insertFrameFixture(
        frameWidth: Int = 1_000,
        frameHeight: Int = 1_000
    ) async throws -> (frameID: FrameID, segmentID: Int64, videoID: VideoSegmentID, timestamp: Date) {
        let fixture = try await insertVideoFixture(
            frameCount: 1,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
        let insertedFrameID = try await insertFrameReference(
            segmentID: fixture.segmentID,
            videoID: fixture.videoID,
            timestamp: fixture.timestamp,
            frameIndexInSegment: 0
        )

        return (
            insertedFrameID,
            fixture.segmentID,
            fixture.videoID,
            fixture.timestamp
        )
    }

    private func insertVideoFixture(
        frameCount: Int,
        frameWidth: Int = 1_000,
        frameHeight: Int = 1_000
    ) async throws -> (segmentID: Int64, videoID: VideoSegmentID, timestamp: Date) {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let insertedVideoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(120),
                frameCount: frameCount,
                fileSizeBytes: 1_024,
                relativePath: "segments/1700000000000",
                width: frameWidth,
                height: frameHeight,
                source: .native
            )
        )
        try await database.markVideoFinalized(
            id: insertedVideoID,
            frameCount: frameCount,
            fileSize: 1_024
        )

        let segmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(120),
            windowName: "Example",
            browserUrl: "https://example.com/articles/current",
            type: 0
        )

        return (
            segmentID,
            VideoSegmentID(value: insertedVideoID),
            timestamp
        )
    }

    private func insertFrameReference(
        segmentID: Int64,
        videoID: VideoSegmentID,
        timestamp: Date,
        frameIndexInSegment: Int
    ) async throws -> FrameID {
        let insertedFrameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: segmentID),
                videoID: videoID,
                frameIndexInSegment: frameIndexInSegment,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    browserURL: "https://example.com/articles/current",
                    displayID: 1
                ),
                source: .native
            )
        )

        return FrameID(value: insertedFrameID)
    }

    private func insertIndexedNode(
        frameID: FrameID,
        segmentID: Int64,
        text: String,
        bounds: CGRect,
        redactedNodeOrders: Set<Int>,
        frameWidth: Int = 1_000,
        frameHeight: Int = 1_000
    ) async throws {
        let indexedText = redactedNodeOrders.isEmpty
            ? text
            : String(repeating: " ", count: text.count)
        _ = try await database.indexFrameText(
            mainText: indexedText,
            chromeText: nil,
            windowTitle: nil,
            segmentId: segmentID,
            frameId: frameID.value
        )

        let node = (
            textOffset: 0,
            textLength: text.count,
            bounds: bounds,
            windowIndex: Optional<Int>.none
        )

        let encryptedText = ReversibleOCRScrambler.encryptOCRText(
            text,
            frameID: frameID.value,
            nodeOrder: 0,
            secret: "test-secret"
        ) ?? text
        try await database.insertNodes(
            frameID: frameID,
            nodes: [node],
            encryptedTexts: redactedNodeOrders.contains(0) ? [0: encryptedText] : [:],
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }
}
