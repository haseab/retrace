import XCTest
import Foundation
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                         FTS MANAGER TESTS                                    ║
// ║                                                                              ║
// ║  • Verify basic text search returns correct results                          ║
// ║  • Verify phrase search matches exact phrases                                ║
// ║  • Verify search filters (time range, app, window title)                     ║
// ║  • Verify match count returns accurate counts                                ║
// ║  • Verify pagination (limit/offset) works correctly                          ║
// ║  • Verify ranking orders results by relevance                                ║
// ║  • Verify FTS index maintenance (optimize, rebuild)                          ║
// ║  • Verify Boolean search operators (AND, OR, NOT)                            ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class FTSManagerTests: XCTestCase {

    var database: DatabaseManager!
    var ftsManager: FTSManager!
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        // Use one shared in-memory DB for both managers.
        // `:memory:` creates a separate DB per connection, so DatabaseManager() + FTSManager()
        // would not see the same schema/data.
        let sharedPath = "file:fts_tests_\(UUID().uuidString)?mode=memory&cache=shared"
        database = DatabaseManager(databasePath: sharedPath)
        ftsManager = FTSManager(databasePath: sharedPath)

        try await database.initialize()
        try await ftsManager.initialize()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    override func tearDown() async throws {
        try await database.close()
        try await ftsManager.close()
        database = nil
        ftsManager = nil
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ HELPER METHODS                                                          │
    // └─────────────────────────────────────────────────────────────────────────┘

    private func createTestData() async throws -> (SegmentID, FrameID, FrameID, FrameID) {
        let baseTime = Date()
        let frame1Time = baseTime.addingTimeInterval(-200)
        let frame2Time = baseTime.addingTimeInterval(-100)
        let frame3Time = baseTime.addingTimeInterval(-10)

        // Create a segment
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: frame1Time,
            endTime: frame3Time,
            frameCount: 3,
            fileSizeBytes: 1024 * 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Create frames
        let frame1 = FrameReference(
            id: FrameID(),
            timestamp: frame1Time,
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(appName: "Safari", windowTitle: "GitHub")
        )

        let frame2 = FrameReference(
            id: FrameID(),
            timestamp: frame2Time,
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: FrameMetadata(appName: "Xcode", windowTitle: "Retrace Project")
        )

        let frame3 = FrameReference(
            id: FrameID(),
            timestamp: frame3Time,
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 2,
            encodingStatus: .success,
            metadata: FrameMetadata(appName: "Terminal", windowTitle: "bash")
        )

        try await database.insertFrame(frame1)
        try await database.insertFrame(frame2)
        try await database.insertFrame(frame3)

        // Create documents with different content
        let doc1 = IndexedDocument(
            id: 0,
            frameID: frame1.id,
            timestamp: frame1Time,
            content: "Swift programming language documentation for macOS development",
            appName: "Safari",
            windowTitle: "GitHub"
        )

        let doc2 = IndexedDocument(
            id: 0,
            frameID: frame2.id,
            timestamp: frame2Time,
            content: "Retrace screen recording and search application source code",
            appName: "Xcode",
            windowTitle: "Retrace Project"
        )

        let doc3 = IndexedDocument(
            id: 0,
            frameID: frame3.id,
            timestamp: frame3Time,
            content: "Terminal commands for git commit and push operations",
            appName: "Terminal",
            windowTitle: "bash"
        )

        _ = try await database.insertDocument(doc1)
        _ = try await database.insertDocument(doc2)
        _ = try await database.insertDocument(doc3)

        return (segment.id, frame1.id, frame2.id, frame3.id)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ BASIC SEARCH TESTS                                                      │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testBasicSearch() async throws {
        _ = try await createTestData()

        // Search for "Swift"
        let results = try await ftsManager.search(query: "Swift", limit: 10, offset: 0)

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].snippet.contains("Swift"))
        XCTAssertEqual(results[0].appName, "Safari")
    }

    func testSearchMultipleResults() async throws {
        _ = try await createTestData()

        // Search for a common word
        let results = try await ftsManager.search(query: "application", limit: 10, offset: 0)

        // Should match both "documentation" (not present) and "application" (in doc2)
        XCTAssertGreaterThanOrEqual(results.count, 1)
    }

    func testSearchNoResults() async throws {
        _ = try await createTestData()

        // Search for something that doesn't exist
        let results = try await ftsManager.search(query: "quantum", limit: 10, offset: 0)

        XCTAssertEqual(results.count, 0)
    }

    func testSearchCaseInsensitive() async throws {
        _ = try await createTestData()

        // Search should be case-insensitive
        let results1 = try await ftsManager.search(query: "SWIFT", limit: 10, offset: 0)
        let results2 = try await ftsManager.search(query: "swift", limit: 10, offset: 0)

        XCTAssertEqual(results1.count, results2.count)
    }

    func testSearchSnippet() async throws {
        _ = try await createTestData()

        let results = try await ftsManager.search(query: "Retrace", limit: 10, offset: 0)

        XCTAssertEqual(results.count, 1)
        // Snippet should contain highlighted match
        XCTAssertTrue(results[0].snippet.contains("<mark>"))
        XCTAssertTrue(results[0].snippet.contains("</mark>"))
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ PHRASE SEARCH TESTS                                                     │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testPhraseSearch() async throws {
        _ = try await createTestData()

        // Search for exact phrase
        let results = try await ftsManager.search(query: "\"screen recording\"", limit: 10, offset: 0)

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].snippet.lowercased().contains("screen"))
        XCTAssertTrue(results[0].snippet.lowercased().contains("recording"))
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ FILTER TESTS                                                            │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testSearchWithTimeFilter() async throws {
        _ = try await createTestData()

        let now = Date()
        let filters = SearchFilters(
            startDate: now.addingTimeInterval(-50),  // Only get frames from last 50 seconds
            endDate: now.addingTimeInterval(50)
        )

        let results = try await ftsManager.search(
            query: "git",
            filters: filters,
            limit: 10,
            offset: 0
        )

        // Should only find the Terminal document (frame3) which is recent
        XCTAssertEqual(results.count, 1)
        guard results.count == 1 else { return }
        XCTAssertEqual(results[0].appName, "Terminal")
    }

    func testSearchWithOldTimeFilter() async throws {
        _ = try await createTestData()

        // Search for time range that's too old
        let filters = SearchFilters(
            startDate: Date().addingTimeInterval(-86400 * 365), // 1 year ago
            endDate: Date().addingTimeInterval(-86400 * 364)     // Still in the past
        )

        let results = try await ftsManager.search(
            query: "Swift",
            filters: filters,
            limit: 10,
            offset: 0
        )

        // Should find nothing because our test data is recent
        XCTAssertEqual(results.count, 0)
    }

    func testSearchWithAppFilter() async throws {
        _ = try await createTestData()

        // Search with app name filter (matches app_name in documents)
        let filters = SearchFilters(
            appBundleIDs: ["Safari"]
        )

        let results = try await ftsManager.search(
            query: "programming",
            filters: filters,
            limit: 10,
            offset: 0
        )

        // Should only find the Safari document
        XCTAssertEqual(results.count, 1)
        guard results.count == 1 else { return }
        XCTAssertEqual(results[0].appName, "Safari")
    }

    func testSearchWithAppBundleIDFilter() async throws {
        // Create test data with bundle IDs
        let baseTime = Date()
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: baseTime,
            endTime: baseTime.addingTimeInterval(100),
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        let frame1 = FrameReference(
            id: FrameID(),
            timestamp: baseTime,
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.google.Chrome",
                appName: "Chrome",
                windowTitle: "Test"
            )
        )

        let frame2 = FrameReference(
            id: FrameID(),
            timestamp: baseTime.addingTimeInterval(50),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowTitle: "Test"
            )
        )

        try await database.insertFrame(frame1)
        try await database.insertFrame(frame2)

        let doc1 = IndexedDocument(
            id: 0,
            frameID: frame1.id,
            timestamp: baseTime,
            content: "Chrome browser testing",
            appName: "Chrome",
            windowTitle: "Test"
        )

        let doc2 = IndexedDocument(
            id: 0,
            frameID: frame2.id,
            timestamp: baseTime.addingTimeInterval(50),
            content: "Safari browser testing",
            appName: "Safari",
            windowTitle: "Test"
        )

        _ = try await database.insertDocument(doc1)
        _ = try await database.insertDocument(doc2)

        // Test filtering by bundle ID
        let filters = SearchFilters(
            appBundleIDs: ["com.google.Chrome"]
        )

        let results = try await ftsManager.search(
            query: "browser",
            filters: filters,
            limit: 10,
            offset: 0
        )

        // Should only find the Chrome document
        XCTAssertEqual(results.count, 1)
        guard results.count == 1 else { return }
        XCTAssertEqual(results[0].appName, "Chrome")
    }

    func testSearchWithAppFilterPartialMatch() async throws {
        _ = try await createTestData()

        // Search with partial app name (should use LIKE pattern)
        let filters = SearchFilters(
            appBundleIDs: ["Saf"]  // Partial match for "Safari"
        )

        let results = try await ftsManager.search(
            query: "programming",
            filters: filters,
            limit: 10,
            offset: 0
        )

        // Should find the Safari document via partial match
        XCTAssertEqual(results.count, 1)
        guard results.count == 1 else { return }
        XCTAssertEqual(results[0].appName, "Safari")
    }

    func testSearchWithMultipleAppFilters() async throws {
        _ = try await createTestData()

        // Search with multiple app filters (OR condition)
        let filters = SearchFilters(
            appBundleIDs: ["Safari", "Xcode"]
        )

        let results = try await ftsManager.search(
            query: "code OR programming",
            filters: filters,
            limit: 10,
            offset: 0
        )

        // Should find documents from both Safari and Xcode
        XCTAssertGreaterThanOrEqual(results.count, 1)
        for result in results {
            XCTAssertTrue(result.appName == "Safari" || result.appName == "Xcode")
        }
    }

    func testSearchWithExcludedAppFilter() async throws {
        _ = try await createTestData()

        // Search excluding specific app
        let filters = SearchFilters(
            excludedAppBundleIDs: ["Terminal"]
        )

        let results = try await ftsManager.search(
            query: "git OR programming",
            filters: filters,
            limit: 10,
            offset: 0
        )

        // Should not find Terminal documents
        for result in results {
            XCTAssertNotEqual(result.appName, "Terminal")
        }
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ MATCH COUNT TESTS                                                       │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testGetMatchCount() async throws {
        _ = try await createTestData()

        // Count matches for a query
        let count = try await ftsManager.getMatchCount(query: "application", filters: .none)

        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testGetMatchCountWithFilters() async throws {
        _ = try await createTestData()

        let now = Date()
        let filters = SearchFilters(
            startDate: now.addingTimeInterval(-300),
            endDate: now.addingTimeInterval(300)
        )

        let count = try await ftsManager.getMatchCount(query: "Swift", filters: filters)

        XCTAssertEqual(count, 1)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ PAGINATION TESTS                                                        │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testSearchPagination() async throws {
        // Create more test data for pagination
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(600),
            frameCount: 5,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Create 5 frames with similar content
        for i in 0..<5 {
            let frame = FrameReference(
                id: FrameID(),
                timestamp: Date().addingTimeInterval(Double(i * 10)),
                segmentID: segment.id,
                frameIndexInSegment: i,
                metadata: .empty
            )
            try await database.insertFrame(frame)

            let doc = IndexedDocument(
                id: 0,
                frameID: frame.id,
                timestamp: Date().addingTimeInterval(Double(i * 10)),
                content: "Document number \(i) containing the word database"
            )
            _ = try await database.insertDocument(doc)
        }

        // Get first page
        let page1 = try await ftsManager.search(query: "database", limit: 2, offset: 0)
        XCTAssertEqual(page1.count, 2)

        // Get second page
        let page2 = try await ftsManager.search(query: "database", limit: 2, offset: 2)
        XCTAssertEqual(page2.count, 2)

        // Get third page
        let page3 = try await ftsManager.search(query: "database", limit: 2, offset: 4)
        XCTAssertEqual(page3.count, 1)

        // Ensure pages don't overlap
        let page1IDs = Set(page1.map { $0.documentID })
        let page2IDs = Set(page2.map { $0.documentID })
        XCTAssertTrue(page1IDs.isDisjoint(with: page2IDs))
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ RANKING TESTS                                                           │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testSearchRanking() async throws {
        let segment = VideoSegment(
            id: SegmentID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(600),
            frameCount: 3,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertSegment(segment)

        // Create documents with varying relevance
        let frame1 = FrameReference(
            id: FrameID(),
            timestamp: Date(),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty
        )

        let frame2 = FrameReference(
            id: FrameID(),
            timestamp: Date().addingTimeInterval(10),
            segmentID: segment.id,
            sessionID: nil,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty
        )

        try await database.insertFrame(frame1)
        try await database.insertFrame(frame2)

        // Document with single match
        let doc1 = IndexedDocument(
            id: 0,
            frameID: frame1.id,
            timestamp: Date(),
            content: "This document mentions Python once"
        )

        // Document with multiple matches (should rank higher)
        let doc2 = IndexedDocument(
            id: 0,
            frameID: frame2.id,
            timestamp: Date().addingTimeInterval(10),
            content: "Python Python Python - this document is all about Python programming"
        )

        _ = try await database.insertDocument(doc1)
        _ = try await database.insertDocument(doc2)

        let results = try await ftsManager.search(query: "Python", limit: 10, offset: 0)

        XCTAssertEqual(results.count, 2)
        guard results.count == 2 else { return }
        // Query orders by BM25 rank; lower is more relevant.
        XCTAssertLessThanOrEqual(results[0].rank, results[1].rank)
        XCTAssertEqual(results[0].frameID, frame2.id)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ INDEX MAINTENANCE TESTS                                                 │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testRebuildIndex() async throws {
        _ = try await createTestData()

        // Rebuild the index
        try await ftsManager.rebuildIndex()

        // Search should still work after rebuild
        let results = try await ftsManager.search(query: "Swift", limit: 10, offset: 0)
        XCTAssertEqual(results.count, 1)
    }

    func testOptimizeIndex() async throws {
        _ = try await createTestData()

        // Optimize the index
        try await ftsManager.optimizeIndex()

        // Search should still work after optimization
        let results = try await ftsManager.search(query: "Swift", limit: 10, offset: 0)
        XCTAssertEqual(results.count, 1)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ BOOLEAN SEARCH TESTS                                                    │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testBooleanAND() async throws {
        _ = try await createTestData()

        // Search for documents containing both words
        let results = try await ftsManager.search(query: "Swift programming", limit: 10, offset: 0)

        // Should find the document containing both "Swift" and "programming"
        XCTAssertGreaterThanOrEqual(results.count, 1)
    }

    func testBooleanOR() async throws {
        _ = try await createTestData()

        // Search for documents containing either word
        let results = try await ftsManager.search(query: "Swift OR Terminal", limit: 10, offset: 0)

        // Should find at least 2 documents
        XCTAssertGreaterThanOrEqual(results.count, 2)
    }

    func testBooleanNOT() async throws {
        _ = try await createTestData()

        // Search for documents with one word but not another
        let results = try await ftsManager.search(query: "application NOT Terminal", limit: 10, offset: 0)

        // Should find documents with "application" but not "Terminal"
        for result in results {
            XCTAssertFalse(result.appName == "Terminal")
        }
    }
}
