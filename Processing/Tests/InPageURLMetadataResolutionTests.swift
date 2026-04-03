import XCTest
import Foundation
import CoreGraphics
import Shared
import Database
@testable import Processing

private actor InPageURLNoopSearch: SearchProtocol {
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

private actor InPageURLNoopProcessing: ProcessingProtocol {
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

private actor InPageURLStubSegmentWriter: SegmentWriter {
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

private actor InPageURLRewriteTrackingStorage: StorageProtocol {
    private var rewriteAttemptCount = 0

    func initialize(config: StorageConfig) async throws {}

    func createSegmentWriter() async throws -> SegmentWriter {
        InPageURLStubSegmentWriter()
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

    func rewriteAttempts() -> Int {
        rewriteAttemptCount
    }
}

final class InPageURLMetadataResolutionTests: XCTestCase {
    private var database: DatabaseManager!
    private var queue: FrameProcessingQueue!
    private var storage: InPageURLRewriteTrackingStorage!

    override func setUp() async throws {
        let uniqueDBPath = "file:memdb_processing_\(UUID().uuidString)?mode=memory&cache=private"
        database = DatabaseManager(databasePath: uniqueDBPath)
        try await database.initialize()

        storage = InPageURLRewriteTrackingStorage()
        queue = FrameProcessingQueue(
            database: database,
            storage: storage,
            processing: InPageURLNoopProcessing(),
            search: InPageURLNoopSearch()
        )
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
        queue = nil
        storage = nil
    }

    func testResolveInPageURLMetadataSucceedsWhenRetriedAfterNodesArrive() async throws {
        let fixture = try await insertFrameFixture()
        let metadataJSON = makeRawLinkMetadataJSON(
            pageURL: "https://example.com/articles/current",
            linkURL: "https://example.com/docs/install",
            linkText: "Install guide",
            left: 0.10,
            top: 0.20,
            width: 0.30,
            height: 0.05
        )

        try await database.updateFrameMetadata(frameID: fixture.frameID, metadataJSON: metadataJSON)

        try await queue.resolveInPageURLMetadataIfPossible(frameID: fixture.frameID.value)

        let pendingMetadata = try await database.getFrameMetadata(frameID: fixture.frameID)
        let pendingRows = try await database.getFrameInPageURLRows(frameID: fixture.frameID)
        XCTAssertEqual(pendingMetadata, metadataJSON)
        XCTAssertTrue(pendingRows.isEmpty)

        try await insertIndexedNode(
            frameID: fixture.frameID,
            segmentID: fixture.segmentID,
            text: "Install guide",
            bounds: CGRect(x: 100, y: 200, width: 300, height: 50)
        )

        try await queue.resolveInPageURLMetadataIfPossible(frameID: fixture.frameID.value)

        let rows = try await database.getFrameInPageURLRows(frameID: fixture.frameID)
        let storedNodes = try await database.getNodes(
            frameID: fixture.frameID,
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        let clearedMetadata = try await database.getFrameMetadata(frameID: fixture.frameID)
        let storedNodeID = try XCTUnwrap(storedNodes.first?.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.url, "/docs/install")
        XCTAssertEqual(rows.first?.nodeID, Int(storedNodeID))
        XCTAssertNil(clearedMetadata)
    }

    func testResolveInPageURLMetadataKeepsPendingMetadataWhenNoNodeMatches() async throws {
        let fixture = try await insertFrameFixture()
        let metadataJSON = makeRawLinkMetadataJSON(
            pageURL: "https://example.com/articles/current",
            linkURL: "https://example.com/docs/install",
            linkText: "Install guide",
            left: 0.75,
            top: 0.75,
            width: 0.10,
            height: 0.04
        )

        try await database.updateFrameMetadata(frameID: fixture.frameID, metadataJSON: metadataJSON)
        try await insertIndexedNode(
            frameID: fixture.frameID,
            segmentID: fixture.segmentID,
            text: "Dashboard",
            bounds: CGRect(x: 100, y: 200, width: 180, height: 40)
        )

        try await queue.resolveInPageURLMetadataIfPossible(frameID: fixture.frameID.value)

        let retainedMetadata = try await database.getFrameMetadata(frameID: fixture.frameID)
        let unresolvedRows = try await database.getFrameInPageURLRows(frameID: fixture.frameID)
        XCTAssertEqual(retainedMetadata, metadataJSON)
        XCTAssertTrue(unresolvedRows.isEmpty)
    }

    func testResolveInPageURLMetadataKeepsExistingCapturedMousePosition() async throws {
        let fixture = try await insertFrameFixture()

        try await database.replaceFrameInPageURLData(
            frameID: fixture.frameID,
            state: FrameInPageURLState(
                mouseX: 321.25,
                mouseY: 654.75,
                scrollX: nil,
                scrollY: nil,
                videoCurrentTime: nil
            ),
            rows: []
        )

        let metadataJSON = try makeRawLinkMetadataJSONWithState(
            pageURL: "https://example.com/articles/current",
            linkURL: "https://example.com/docs/install",
            linkText: "Install guide",
            left: 0.10,
            top: 0.20,
            width: 0.30,
            height: 0.05,
            mouseX: 900.5,
            mouseY: 500.25,
            scrollX: 12.0,
            scrollY: 34.0
        )

        try await database.updateFrameMetadata(frameID: fixture.frameID, metadataJSON: metadataJSON)
        try await insertIndexedNode(
            frameID: fixture.frameID,
            segmentID: fixture.segmentID,
            text: "Install guide",
            bounds: CGRect(x: 100, y: 200, width: 300, height: 50)
        )

        try await queue.resolveInPageURLMetadataIfPossible(frameID: fixture.frameID.value)

        let state = try await database.getFrameInPageURLState(frameID: fixture.frameID)
        let rows = try await database.getFrameInPageURLRows(frameID: fixture.frameID)
        let clearedMetadata = try await database.getFrameMetadata(frameID: fixture.frameID)

        let resolvedState = try XCTUnwrap(state)
        XCTAssertEqual(try XCTUnwrap(resolvedState.mouseX), 321.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(resolvedState.mouseY), 654.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(resolvedState.scrollX), 12.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(resolvedState.scrollY), 34.0, accuracy: 0.0001)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(clearedMetadata)
    }

    func testResolveInPageURLMetadataDoesNotPersistBrowserMousePosition() async throws {
        let fixture = try await insertFrameFixture()
        let metadataJSON = try makeRawLinkMetadataJSONWithState(
            pageURL: "https://example.com/articles/current",
            linkURL: "https://example.com/docs/install",
            linkText: "Install guide",
            left: 0.10,
            top: 0.20,
            width: 0.30,
            height: 0.05,
            mouseX: 900.5,
            mouseY: 500.25,
            scrollX: 12.0,
            scrollY: 34.0
        )

        try await database.updateFrameMetadata(frameID: fixture.frameID, metadataJSON: metadataJSON)
        try await insertIndexedNode(
            frameID: fixture.frameID,
            segmentID: fixture.segmentID,
            text: "Install guide",
            bounds: CGRect(x: 100, y: 200, width: 300, height: 50)
        )

        try await queue.resolveInPageURLMetadataIfPossible(frameID: fixture.frameID.value)

        let state = try await database.getFrameInPageURLState(frameID: fixture.frameID)
        let clearedMetadata = try await database.getFrameMetadata(frameID: fixture.frameID)

        let resolvedState = try XCTUnwrap(state)
        XCTAssertNil(resolvedState.mouseX)
        XCTAssertNil(resolvedState.mouseY)
        XCTAssertEqual(try XCTUnwrap(resolvedState.scrollX), 12.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(resolvedState.scrollY), 34.0, accuracy: 0.0001)
        XCTAssertNil(clearedMetadata)
    }

    func testProcessPendingRewritesDefersUntilVideoOCRQuiescesEvenAfterFinalization() async throws {
        let fixture = try await insertFrameFixture(finalizeVideo: true)
        let pendingFrameID = try await insertFrame(
            videoID: fixture.videoID,
            segmentID: fixture.segmentID,
            timestamp: fixture.timestamp.addingTimeInterval(2),
            frameIndex: 1
        )

        try await insertIndexedNode(
            frameID: fixture.frameID,
            segmentID: fixture.segmentID,
            text: "secret phrase",
            bounds: CGRect(x: 100, y: 200, width: 300, height: 50),
            redactedNodeOrders: [0]
        )

        try await database.updateFrameProcessingStatus(
            frameID: fixture.frameID.value,
            status: FrameProcessingStatus.rewritePending.rawValue,
            rewritePurpose: "redaction"
        )
        try await database.updateFrameProcessingStatus(
            frameID: pendingFrameID.value,
            status: FrameProcessingStatus.processing.rawValue
        )

        let outcome = try await queue.processPendingRewrites(for: fixture.videoID.value)

        let statuses = try await database.getFrameProcessingStatuses(
            frameIDs: [fixture.frameID.value, pendingFrameID.value]
        )
        let rewriteAttempts = await storage.rewriteAttempts()
        XCTAssertEqual(outcome, .deferred(.pendingOCR))
        XCTAssertEqual(statuses[fixture.frameID.value], FrameProcessingStatus.rewritePending.rawValue)
        XCTAssertEqual(statuses[pendingFrameID.value], FrameProcessingStatus.processing.rawValue)
        XCTAssertEqual(rewriteAttempts, 0)
    }

    func testProcessPendingRewritesDefersMixedDeletionAndRedactionUntilVideoOCRQuiesces() async throws {
        let fixture = try await insertFrameFixture()
        let deletionFrameID = try await insertFrame(
            videoID: fixture.videoID,
            segmentID: fixture.segmentID,
            timestamp: fixture.timestamp.addingTimeInterval(1),
            frameIndex: 1
        )
        let pendingFrameID = try await insertFrame(
            videoID: fixture.videoID,
            segmentID: fixture.segmentID,
            timestamp: fixture.timestamp.addingTimeInterval(2),
            frameIndex: 2
        )
        try await database.markVideoFinalized(
            id: fixture.videoID.value,
            frameCount: 3,
            fileSize: 1_024
        )

        try await insertIndexedNode(
            frameID: fixture.frameID,
            segmentID: fixture.segmentID,
            text: "secret phrase",
            bounds: CGRect(x: 100, y: 200, width: 300, height: 50),
            redactedNodeOrders: [0]
        )

        try await database.updateFrameProcessingStatus(
            frameID: fixture.frameID.value,
            status: FrameProcessingStatus.rewritePending.rawValue,
            rewritePurpose: "redaction"
        )
        try await database.updateFrameProcessingStatus(
            frameID: deletionFrameID.value,
            status: FrameProcessingStatus.rewritePending.rawValue,
            rewritePurpose: "deletion"
        )
        try await database.updateFrameProcessingStatus(
            frameID: pendingFrameID.value,
            status: FrameProcessingStatus.processing.rawValue
        )

        let outcome = try await queue.processPendingRewrites(for: fixture.videoID.value)

        let statuses = try await database.getFrameProcessingStatuses(
            frameIDs: [fixture.frameID.value, deletionFrameID.value, pendingFrameID.value]
        )
        let rewriteAttempts = await storage.rewriteAttempts()
        XCTAssertEqual(outcome, .deferred(.pendingOCR))
        XCTAssertEqual(statuses[fixture.frameID.value], FrameProcessingStatus.rewritePending.rawValue)
        XCTAssertEqual(statuses[deletionFrameID.value], FrameProcessingStatus.rewritePending.rawValue)
        XCTAssertEqual(statuses[pendingFrameID.value], FrameProcessingStatus.processing.rawValue)
        XCTAssertEqual(rewriteAttempts, 0)
    }

    func testProcessPendingRewritesDefersWhileTimelineIsVisible() async throws {
        let fixture = try await insertFrameFixture(finalizeVideo: true)
        try await database.updateFrameProcessingStatus(
            frameID: fixture.frameID.value,
            status: FrameProcessingStatus.rewritePending.rawValue,
            rewritePurpose: "deletion"
        )

        await queue.setTimelineVisibleForRewriteScheduling(true)
        let outcome = try await queue.processPendingRewrites(for: fixture.videoID.value)

        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [fixture.frameID.value])
        let rewriteAttempts = await storage.rewriteAttempts()
        XCTAssertEqual(outcome, .deferred(.timelineInteraction))
        XCTAssertEqual(statuses[fixture.frameID.value], FrameProcessingStatus.rewritePending.rawValue)
        XCTAssertEqual(rewriteAttempts, 0)
    }

    func testProcessPendingRewritesResumeAfterTimelineScrubbingEnds() async throws {
        let fixture = try await insertFrameFixture(finalizeVideo: true)
        try await database.updateFrameProcessingStatus(
            frameID: fixture.frameID.value,
            status: FrameProcessingStatus.rewritePending.rawValue,
            rewritePurpose: "deletion"
        )

        await queue.setTimelineScrubbingForRewriteScheduling(true)
        let deferredOutcome = try await queue.processPendingRewrites(for: fixture.videoID.value)
        XCTAssertEqual(deferredOutcome, .deferred(.timelineInteraction))

        await queue.setTimelineScrubbingForRewriteScheduling(false)
        try await waitForRewriteAttemptCount(1)

        let frame = try await database.getFrame(id: fixture.frameID)
        XCTAssertNil(frame)
    }

    private func waitForRewriteAttemptCount(
        _ expectedCount: Int,
        timeoutNs: UInt64 = 2_000_000_000
    ) async throws {
        let start = ContinuousClock.now

        while ContinuousClock.now - start < .nanoseconds(Int64(timeoutNs)) {
            if await storage.rewriteAttempts() == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(25), clock: .continuous)
        }

        let rewriteAttempts = await storage.rewriteAttempts()
        XCTAssertEqual(rewriteAttempts, expectedCount)
    }

    private func insertFrameFixture(
        finalizeVideo: Bool = false,
        frameWidth: Int = 1_000,
        frameHeight: Int = 1_000
    ) async throws -> (frameID: FrameID, segmentID: Int64, videoID: VideoSegmentID, timestamp: Date) {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let insertedVideoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(120),
                frameCount: 1,
                fileSizeBytes: 1_024,
                relativePath: "segments/1700000000000",
                width: frameWidth,
                height: frameHeight,
                source: .native
            )
        )

        if finalizeVideo {
            try await database.markVideoFinalized(
                id: insertedVideoID,
                frameCount: 1,
                fileSize: 1_024
            )
        }

        let segmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(120),
            windowName: "Example",
            browserUrl: "https://example.com/articles/current",
            type: 0
        )

        let insertedFrameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: segmentID),
                videoID: VideoSegmentID(value: insertedVideoID),
                frameIndexInSegment: 0,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    browserURL: "https://example.com/articles/current",
                    displayID: 1
                ),
                source: .native
            )
        )

        return (
            FrameID(value: insertedFrameID),
            segmentID,
            VideoSegmentID(value: insertedVideoID),
            timestamp
        )
    }

    private func insertFrame(
        videoID: VideoSegmentID,
        segmentID: Int64,
        timestamp: Date,
        frameIndex: Int
    ) async throws -> FrameID {
        let insertedFrameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: segmentID),
                videoID: videoID,
                frameIndexInSegment: frameIndex,
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
        redactedNodeOrders: Set<Int> = [],
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

        if redactedNodeOrders.isEmpty {
            try await database.insertNodes(
                frameID: frameID,
                nodes: [node],
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )
        } else {
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

    private func makeRawLinkMetadataJSON(
        pageURL: String,
        linkURL: String,
        linkText: String,
        left: Double,
        top: Double,
        width: Double,
        height: Double
    ) -> String {
        "{\"pageurl\":\"\(pageURL)\",\"rawlinks\":[{\"url\":\"\(linkURL)\",\"text\":\"\(linkText)\",\"left\":\(left),\"top\":\(top),\"width\":\(width),\"height\":\(height)}],\"urls\":[]}"
    }

    private func makeRawLinkMetadataJSONWithState(
        pageURL: String,
        linkURL: String,
        linkText: String,
        left: Double,
        top: Double,
        width: Double,
        height: Double,
        mouseX: Double,
        mouseY: Double,
        scrollX: Double,
        scrollY: Double
    ) throws -> String {
        let payload: [String: Any] = [
            "pageurl": pageURL,
            "rawlinks": [[
                "url": linkURL,
                "text": linkText,
                "left": left,
                "top": top,
                "width": width,
                "height": height
            ]],
            "urls": [],
            "mouseposition": [
                "x": mouseX,
                "y": mouseY
            ],
            "scrollposition": [
                "x": scrollX,
                "y": scrollY
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(decoding: data, as: UTF8.self)
    }
}
