import XCTest
import Foundation
import CoreGraphics
import Shared
import Database
import Storage
@testable import Processing

private actor NoopSearch: SearchProtocol {
    func initialize(config: SearchConfig) async throws {}

    func search(query: SearchQuery) async throws -> SearchResults {
        SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: 0)
    }

    func search(text: String, limit: Int) async throws -> SearchResults {
        SearchResults(
            query: SearchQuery(text: text, limit: limit),
            results: [],
            totalCount: 0,
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

final class InPageURLMetadataResolutionTests: XCTestCase {
    private var database: DatabaseManager!
    private var queue: FrameProcessingQueue!

    override func setUp() async throws {
        let uniqueDBPath = "file:memdb_processing_\(UUID().uuidString)?mode=memory&cache=private"
        database = DatabaseManager(databasePath: uniqueDBPath)
        try await database.initialize()

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceProcessingQueueTests_\(UUID().uuidString)", isDirectory: true)
        queue = FrameProcessingQueue(
            database: database,
            storage: StorageManager(storageRoot: storageRoot),
            processing: ProcessingManager(),
            search: NoopSearch()
        )
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
        queue = nil
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

    private func insertFrameFixture(
        frameWidth: Int = 1_000,
        frameHeight: Int = 1_000
    ) async throws -> (frameID: FrameID, segmentID: Int64) {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let insertedVideoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(120),
                frameCount: 1,
                fileSizeBytes: 1_024,
                relativePath: "segments/in-page-resolution-test.mp4",
                width: frameWidth,
                height: frameHeight,
                source: .native
            )
        )

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
                encodingStatus: .success,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    browserURL: "https://example.com/articles/current",
                    displayID: 1
                ),
                source: .native
            )
        )

        return (FrameID(value: insertedFrameID), segmentID)
    }

    private func insertIndexedNode(
        frameID: FrameID,
        segmentID: Int64,
        text: String,
        bounds: CGRect,
        frameWidth: Int = 1_000,
        frameHeight: Int = 1_000
    ) async throws {
        _ = try await database.indexFrameText(
            mainText: text,
            chromeText: nil,
            windowTitle: nil,
            segmentId: segmentID,
            frameId: frameID.value
        )

        try await database.insertNodes(
            frameID: frameID,
            nodes: [(
                textOffset: 0,
                textLength: text.count,
                bounds: bounds,
                windowIndex: nil
            )],
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
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

final class OCRMemoryBackpressurePolicyTests: XCTestCase {
    func testHysteresisPausesAndResumesAtDifferentThresholds() {
        let policy = OCRMemoryBackpressurePolicy(
            enabled: true,
            pauseThresholdBytes: 100,
            resumeThresholdBytes: 60,
            pollIntervalNs: 1_000_000_000
        )

        XCTAssertFalse(policy.shouldPause(footprintBytes: 99, currentlyPaused: false))
        XCTAssertTrue(policy.shouldPause(footprintBytes: 100, currentlyPaused: false))
        XCTAssertTrue(policy.shouldPause(footprintBytes: 80, currentlyPaused: true))
        XCTAssertFalse(policy.shouldPause(footprintBytes: 59, currentlyPaused: true))
    }

    func testDefaultsUseBaseThresholdsForReferenceDisplaySize() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.reference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: OCRMemoryBackpressurePolicy.referenceDisplayPixelCount
        )

        XCTAssertTrue(policy.enabled)
        XCTAssertEqual(policy.pauseThresholdBytes, OCRMemoryBackpressurePolicy.defaultPauseThresholdBytes)
        XCTAssertEqual(policy.resumeThresholdBytes, OCRMemoryBackpressurePolicy.defaultResumeThresholdBytes)
        XCTAssertEqual(policy.pollIntervalNs, 1_000_000_000)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsScaleUpForUltraWideDisplays() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.ultrawide.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: 5_120 * 1_440
        )

        XCTAssertEqual(policy.pauseThresholdBytes, 2_172 * 1024 * 1024)
        XCTAssertEqual(policy.resumeThresholdBytes, 2_028 * 1024 * 1024)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsClampResumeBelowPauseThreshold() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(900, forKey: OCRMemoryBackpressurePolicy.pauseThresholdDefaultsKey)
        defaults.set(950, forKey: OCRMemoryBackpressurePolicy.resumeThresholdDefaultsKey)
        defaults.set(false, forKey: OCRMemoryBackpressurePolicy.enabledDefaultsKey)
        defaults.set(250, forKey: OCRMemoryBackpressurePolicy.pollIntervalDefaultsKey)

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: 5_120 * 1_440
        )

        XCTAssertFalse(policy.enabled)
        XCTAssertEqual(policy.pauseThresholdBytes, 900 * 1024 * 1024)
        XCTAssertEqual(policy.resumeThresholdBytes, 899 * 1024 * 1024)
        XCTAssertEqual(policy.pollIntervalNs, 250 * 1_000_000)

        defaults.removePersistentDomain(forName: suiteName)
    }
}
