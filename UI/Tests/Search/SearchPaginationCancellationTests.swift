import XCTest
import Shared
import App
@testable import Retrace

@MainActor
final class SearchPaginationCancellationTests: XCTestCase {
    func testFreshSearchCancelsInFlightLoadMoreAndIgnoresStaleCompletion() async throws {
        let queryText = "lishy"
        let nextCursor = SearchPageCursor(
            native: SearchSourceCursor(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                frameID: 44
            )
        )

        let initialNewestResults = makeResults(
            queryText: queryText,
            sortOrder: .newestFirst,
            frameIDs: [41, 42, 43, 44],
            nextCursor: nextCursor
        )
        let staleLoadMoreResults = makeResults(
            queryText: queryText,
            sortOrder: .newestFirst,
            frameIDs: [45],
            nextCursor: nil
        )
        let refreshedOldestResults = makeResults(
            queryText: queryText,
            sortOrder: .oldestFirst,
            frameIDs: [11, 12, 13],
            nextCursor: nil
        )

        let executor = SearchExecutorStub(
            initialResults: initialNewestResults,
            staleLoadMoreResults: staleLoadMoreResults,
            refreshedResults: refreshedOldestResults
        )
        let viewModel = SearchViewModel(
            coordinator: AppCoordinator(),
            executeSearch: { query in
                try await executor.execute(query)
            }
        )

        viewModel.searchMode = .all
        viewModel.sortOrder = .newestFirst
        viewModel.searchQuery = queryText

        await viewModel.performSearch(query: queryText, trigger: "initial-search")
        XCTAssertEqual(viewModel.results?.results.map(\.id.value), [41, 42, 43, 44])
        XCTAssertEqual(viewModel.results?.nextCursor, nextCursor)

        viewModel.loadMore()
        try await waitUntil {
            viewModel.isLoadingMore
        }

        viewModel.sortOrder = .oldestFirst
        await viewModel.performSearch(query: queryText, trigger: "sort-order-change")

        XCTAssertEqual(viewModel.results?.results.map(\.id.value), [11, 12, 13])
        XCTAssertFalse(viewModel.isLoadingMore)

        try await Task.sleep(for: .milliseconds(250), clock: .continuous)

        XCTAssertEqual(viewModel.results?.results.map(\.id.value), [11, 12, 13])
        XCTAssertFalse(viewModel.isLoadingMore)

        let recordedQueries = await executor.recordedQueries
        XCTAssertEqual(recordedQueries.count, 3)
        XCTAssertNil(recordedQueries[0].cursor)
        XCTAssertEqual(recordedQueries[0].sortOrder, .newestFirst)
        XCTAssertEqual(recordedQueries[1].cursor, nextCursor)
        XCTAssertEqual(recordedQueries[1].sortOrder, .newestFirst)
        XCTAssertNil(recordedQueries[2].cursor)
        XCTAssertEqual(recordedQueries[2].sortOrder, .oldestFirst)
    }

    func testLoadMoreCoalescesDuplicateTriggers() async throws {
        let queryText = "lishy"
        let nextCursor = SearchPageCursor(
            native: SearchSourceCursor(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                frameID: 44
            )
        )

        let initialResults = makeResults(
            queryText: queryText,
            sortOrder: .oldestFirst,
            frameIDs: [41, 42, 43, 44],
            nextCursor: nextCursor
        )
        let loadMoreResults = makeResults(
            queryText: queryText,
            sortOrder: .oldestFirst,
            frameIDs: [45],
            nextCursor: nil
        )

        let executor = SearchExecutorStub(
            initialResults: initialResults,
            staleLoadMoreResults: loadMoreResults,
            refreshedResults: loadMoreResults
        )
        let viewModel = SearchViewModel(
            coordinator: AppCoordinator(),
            executeSearch: { query in
                try await executor.execute(query)
            }
        )

        viewModel.searchMode = .all
        viewModel.sortOrder = .oldestFirst
        viewModel.searchQuery = queryText

        await viewModel.performSearch(query: queryText, trigger: "initial-search")
        XCTAssertEqual(viewModel.results?.results.map(\.id.value), [41, 42, 43, 44])

        viewModel.loadMore()
        viewModel.loadMore()
        viewModel.loadMore()

        try await waitUntil {
            viewModel.isLoadingMore
        }
        try await waitUntil {
            viewModel.isLoadingMore == false
        }

        let recordedQueries = await executor.recordedQueries
        XCTAssertEqual(recordedQueries.count, 2)
        XCTAssertNil(recordedQueries[0].cursor)
        XCTAssertEqual(recordedQueries[1].cursor, nextCursor)
        XCTAssertEqual(viewModel.results?.results.map(\.id.value), [41, 42, 43, 44, 45])
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }

        XCTFail("Timed out waiting for condition")
    }

    private func makeResults(
        queryText: String,
        sortOrder: SearchSortOrder,
        frameIDs: [Int64],
        nextCursor: SearchPageCursor?
    ) -> SearchResults {
        let query = SearchQuery(
            text: queryText,
            limit: 50,
            offset: 0,
            cursor: nil,
            mode: .all,
            sortOrder: sortOrder
        )

        let results = frameIDs.enumerated().map { index, frameID in
            SearchResult(
                id: FrameID(value: frameID),
                timestamp: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                snippet: "snippet-\(frameID)",
                matchedText: queryText,
                relevanceScore: Double(index),
                metadata: .empty,
                segmentID: AppSegmentID(value: frameID),
                frameIndex: index,
                source: .native
            )
        }

        return SearchResults(
            query: query,
            results: results,
            searchTimeMs: 1,
            nextCursor: nextCursor
        )
    }
}

private actor SearchExecutorStub {
    private let initialResults: SearchResults
    private let staleLoadMoreResults: SearchResults
    private let refreshedResults: SearchResults
    private(set) var recordedQueries: [SearchQuery] = []

    init(
        initialResults: SearchResults,
        staleLoadMoreResults: SearchResults,
        refreshedResults: SearchResults
    ) {
        self.initialResults = initialResults
        self.staleLoadMoreResults = staleLoadMoreResults
        self.refreshedResults = refreshedResults
    }

    func execute(_ query: SearchQuery) async throws -> SearchResults {
        recordedQueries.append(query)

        switch recordedQueries.count {
        case 1:
            return initialResults
        case 2:
            try await Task.sleep(for: .milliseconds(150), clock: .continuous)
            return staleLoadMoreResults
        case 3:
            return refreshedResults
        default:
            return refreshedResults
        }
    }
}
