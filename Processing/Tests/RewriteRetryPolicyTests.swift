import XCTest
import Foundation
import CoreGraphics
import Shared
import Database
import SQLCipher
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
    private var lastRewriteSecret: String?

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
        lastRewriteSecret = secret
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

    func appliedRewriteSecret() -> String? { lastRewriteSecret }
}

private struct RewriteTestTimeout: Error, CustomStringConvertible {
    let stage: String
    let seconds: Double

    var description: String {
        "Timed out after \(seconds)s waiting for: \(stage)"
    }
}

/// Delivers whichever of two racing tasks finishes first and ignores the loser.
private actor FirstRewriteTestOutcome<T: Sendable> {
    private var resolved: Result<T, Error>?
    private var waiter: CheckedContinuation<Result<T, Error>, Never>?

    func resolve(_ outcome: Result<T, Error>) {
        guard resolved == nil else { return }
        resolved = outcome

        if let waiter {
            self.waiter = nil
            waiter.resume(returning: outcome)
        }
    }

    func firstOutcome() async -> Result<T, Error> {
        if let resolved {
            return resolved
        }

        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

private actor BlockingRewriteStorage: StorageProtocol, RewriteAttemptCountingStorage {
    private var rewriteAttemptCount = 0
    private var recoveryScanCount = 0
    private var firstRewriteStarted = false
    private var firstRewriteReleased = false
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

            if !firstRewriteReleased {
                await withCheckedContinuation { continuation in
                    firstRewriteReleaseContinuation = continuation
                }
            }
        }
    }

    func recoverInterruptedSegmentRewrites() async throws -> [SegmentRewriteRecoveryAction] {
        recoveryScanCount += 1
        return []
    }

    func recoveryScans() -> Int { recoveryScanCount }

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
        firstRewriteReleased = true
        firstRewriteReleaseContinuation?.resume()
        firstRewriteReleaseContinuation = nil
    }

    func appliedRewriteAttemptCount() -> Int {
        rewriteAttemptCount
    }
}

final class RewriteRetryPolicyTests: XCTestCase {
    private static let testAppWideSecret = "test-secret"

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
            ),
            appWideSecretProvider: { Self.testAppWideSecret }
        )
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
        queue = nil
        storage = nil
    }

    func testMissingMasterKeyDefersScrambleRewriteWithoutStorageMutation() async throws {
        let fixture = try await insertFrameFixture()
        try await insertIndexedNode(frameID: fixture.frameID, segmentID: fixture.segmentID,
                                    text: "secret phrase", bounds: CGRect(x: 10, y: 10, width: 100, height: 30),
                                    redactedNodeOrders: [0])
        try await database.updateFrameProcessingStatus(frameID: fixture.frameID.value,
            status: FrameProcessingStatus.rewritePending.rawValue, rewritePurpose: "redaction")
        let noKeyQueue = FrameProcessingQueue(database: database, storage: storage,
            processing: RewriteRetryNoopProcessing(), search: RewriteRetryNoopSearch(),
            appWideSecretProvider: { nil })
        let outcome = try await noKeyQueue.processPendingRewrites(for: fixture.videoID.value)
        XCTAssertEqual(outcome, .deferred(.missingMasterKey))
        let attempts = await storage.appliedRewriteAttemptCount()
        XCTAssertEqual(attempts, 0)
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [fixture.frameID.value])
        XCTAssertEqual(statuses[fixture.frameID.value], FrameProcessingStatus.rewritePending.rawValue)
    }

    func testPermanentRewriteCompletesWithoutMasterKey() async throws {
        let fixture = try await insertFrameFixture()
        try await insertIndexedNode(frameID: fixture.frameID, segmentID: fixture.segmentID,
                                    text: "secret phrase", bounds: CGRect(x: 10, y: 10, width: 100, height: 30),
                                    mode: .permanent, redactedNodeOrders: [0])
        try await database.updateFrameProcessingStatus(frameID: fixture.frameID.value,
            status: FrameProcessingStatus.rewritePending.rawValue, rewritePurpose: "redaction")
        let permanentStorage = FailingRewriteStorage(failureCount: 0)
        let noKeyQueue = FrameProcessingQueue(database: database, storage: permanentStorage,
            processing: RewriteRetryNoopProcessing(), search: RewriteRetryNoopSearch(),
            appWideSecretProvider: { nil })
        let outcome = try await noKeyQueue.processPendingRewrites(for: fixture.videoID.value)
        XCTAssertEqual(outcome, .completed)
        let attempts = await permanentStorage.appliedRewriteAttemptCount()
        XCTAssertEqual(attempts, 1)
        let suppliedSecret = await permanentStorage.appliedRewriteSecret()
        XCTAssertNil(suppliedSecret)
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [fixture.frameID.value])
        XCTAssertEqual(statuses[fixture.frameID.value], FrameProcessingStatus.rewriteCompleted.rawValue)
    }

    func testTimeoutReturnsWhileOperationIsSuspendedWithoutCancellationSupport() async throws {
        let gate = FirstRewriteTestOutcome<Void>()
        let start = ContinuousClock.now
        do {
            try await withTestTimeout("blocked operation", seconds: 0.02) {
                try await gate.firstOutcome().get()
            }
            XCTFail("Expected the suspended operation to time out")
        } catch let error as RewriteTestTimeout {
            XCTAssertEqual(error.stage, "blocked operation")
            XCTAssertEqual(error.seconds, 0.02)
        }
        // Release the losing operation as well; no suspended task escapes the test.
        await gate.resolve(.success(()))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testDatabaseReadFailureDoesNotAuthorizeFrameDeletion() async throws {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO segment(id,bundleID,startDate,endDate,type) VALUES(1,'example',0,10,0);
            INSERT INTO video(id,height,width,path,fileSize,frameRate,processingState) VALUES(1,64,64,'segments/123',100,30,0);
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex) VALUES(1,1,'one',1,1,0);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_set_authorizer(db, { _, action, table, _, _, _ in
            if action == SQLITE_READ, let table, String(cString: table) == "video" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
        let shouldDelete = await queue.verifyFrameIsUnrecoverable(
            frameID: 1, error: StorageError.fileReadFailed(path: "segments/123", underlying: "Video file is empty")
        )
        sqlite3_set_authorizer(db, nil, nil)
        XCTAssertFalse(shouldDelete)
        let retained = try await database.getFrame(id: FrameID(value: 1))
        XCTAssertNotNil(retained)
    }

    func testEnqueueBatchIsAtomicAndUsesDatabaseBatch() async throws {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        let sql = "INSERT INTO frame(id,createdAt,imageFileName,processingStatus) VALUES (1,1000,'one',0),(2,2000,'two',0);"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        do {
            try await queue.enqueueBatch(frameIDs: [1,2,999], priority: 7)
            XCTFail("Expected the invalid frame to reject the whole batch")
        } catch {}
        let failedDepth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(failedDepth, 0, "The Processing entry point must not retain a partially enqueued prefix")
        try await queue.enqueueBatch(frameIDs: [1,2], priority: 7)
        try await queue.enqueueBatch(frameIDs: [])
        let depth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(depth, 2)
    }

    func testRecoveryNeverScansWhileAnotherRewriteIsActive() async throws {
        let blockingStorage = BlockingRewriteStorage()
        let blockingQueue = FrameProcessingQueue(database: database, storage: blockingStorage,
            processing: RewriteRetryNoopProcessing(), search: RewriteRetryNoopSearch(),
            config: ProcessingQueueConfig(workerCount: 1, maxRetryAttempts: 3, maxQueueSize: 1000),
            appWideSecretProvider: { Self.testAppWideSecret })
        let fixture = try await insertVideoFixture(frameCount: 2)
        let frameID = try await insertFrameReference(segmentID: fixture.segmentID, videoID: fixture.videoID,
            timestamp: fixture.timestamp, frameIndexInSegment: 0)
        let siblingID = try await insertFrameReference(segmentID: fixture.segmentID, videoID: fixture.videoID,
            timestamp: fixture.timestamp.addingTimeInterval(1), frameIndexInSegment: 1)
        try await database.updateFrameProcessingStatus(frameID: siblingID.value,
            status: FrameProcessingStatus.completed.rawValue)
        try await database.updateFrameProcessingStatus(frameID: frameID.value,
            status: FrameProcessingStatus.rewritePending.rawValue, rewritePurpose: "deletion")
        let rewrite = Task { try await blockingQueue.processPendingRewrites(for: fixture.videoID.value) }
        addTeardownBlock {
            await blockingStorage.releaseFirstRewrite()
            _ = try await self.withTestTimeout("recovery rewrite cleanup") { try await rewrite.value }
            await blockingQueue.stopWorkers()
        }
        try await withTestTimeout("first rewrite to start") {
            await blockingStorage.waitForFirstRewriteToStart()
        }
        await blockingQueue.startWorkers()
        await blockingQueue.recoverPendingRewritesIfPossible()
        let scansDuringRewrite = await blockingStorage.recoveryScans()
        // Release before asserting so a failed regression cannot strand a worker.
        await blockingStorage.releaseFirstRewrite()
        _ = try await withTestTimeout("recovery rewrite to finish") { try await rewrite.value }
        await blockingQueue.stopWorkers()
        XCTAssertEqual(scansDuringRewrite, 0)
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
        let suppliedSecret = await storage.appliedRewriteSecret()
        XCTAssertEqual(suppliedSecret, Self.testAppWideSecret)
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
            ),
            appWideSecretProvider: { Self.testAppWideSecret }
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
        addTeardownBlock {
            await blockingStorage.releaseFirstRewrite()
            _ = try await self.withTestTimeout("first rewrite cleanup") { try await firstRewriteTask.value }
        }
        try await withTestTimeout("first rewrite to start") {
            await blockingStorage.waitForFirstRewriteToStart()
        }

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

        let deferredOutcome = try await withTestTimeout("active-video rewrite to defer") {
            try await blockingQueue.processPendingRewrites(for: fixture.videoID.value)
        }
        XCTAssertEqual(deferredOutcome, .deferred(.rewriteAlreadyInProgress))

        await blockingStorage.releaseFirstRewrite()
        let firstRewriteOutcome = try await withTestTimeout("first rewrite to finish") {
            try await firstRewriteTask.value
        }
        XCTAssertEqual(firstRewriteOutcome, .completed)

        try await waitForRewriteAttemptCount(2, in: blockingStorage)

        // Attempt count is advanced at rewrite entry, before database finalization.
        // Observe the durable result rather than racing that in-flight update.
        let database = try XCTUnwrap(self.database)
        let statuses = try await withTestTimeout("deferred rewrite database completion") {
            while !Task.isCancelled {
                let statuses = try await database.getFrameProcessingStatuses(
                    frameIDs: [firstFrameID.value, secondFrameID.value]
                )
                if statuses[secondFrameID.value] == FrameProcessingStatus.rewriteCompleted.rawValue {
                    return statuses
                }
                try await Task.sleep(for: .milliseconds(5), clock: .continuous)
            }
            throw CancellationError()
        }
        XCTAssertEqual(statuses[firstFrameID.value], FrameProcessingStatus.rewriteCompleted.rawValue)
        XCTAssertEqual(statuses[secondFrameID.value], FrameProcessingStatus.rewriteCompleted.rawValue)
    }

    /// Bounds an await that would otherwise hang the whole test process.
    ///
    /// Task groups wait for every child, including continuations that ignore cancellation.
    /// Race unstructured tasks so a timeout can return; storage gates are released in teardown.
    private func withTestTimeout<T: Sendable>(
        _ stage: String,
        seconds: Double = 20,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let outcome = FirstRewriteTestOutcome<T>()

        let operationTask = Task {
            do {
                await outcome.resolve(.success(try await operation()))
            } catch {
                await outcome.resolve(.failure(error))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(seconds), clock: .continuous)
            } catch { return }
            await outcome.resolve(.failure(RewriteTestTimeout(stage: stage, seconds: seconds)))
        }
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }

        switch await outcome.firstOutcome() {
        case .success(let value):
            return value
        case .failure(let error):
            // Throwing from an async test already records a failure carrying this
            // error's description, so an XCTFail here would report the same timeout twice.
            throw error
        }
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
        throw RewriteTestTimeout(stage: "rewrite attempt count \(expectedCount) (observed \(actualRewriteAttemptCount))",
                                 seconds: Double(timeoutNs) / 1_000_000_000)
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
        mode: PhraseRedactionMode = .scramble,
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

        let encryptedText: String
        if mode == .permanent {
            encryptedText = PhraseRedactionMode.permanentTextMarker
        } else {
            encryptedText = try XCTUnwrap(ReversibleOCRScrambler.encryptOCRText(
                text,
                frameID: frameID.value,
                nodeOrder: 0,
                secret: Self.testAppWideSecret
            ))
        }
        try await database.insertNodes(
            frameID: frameID,
            nodes: [node],
            encryptedTexts: redactedNodeOrders.contains(0) ? [0: encryptedText] : [:],
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }
}
