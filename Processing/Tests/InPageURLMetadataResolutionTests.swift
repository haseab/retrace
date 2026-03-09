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
}
