import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class SearchRecentEntriesRemovalTests: XCTestCase {
    private let recentEntriesDefaultsKey = "search.recentEntries.v1"
    private var originalRecentEntriesData: Data?

    override func setUp() {
        super.setUp()
        originalRecentEntriesData = UserDefaults.standard.data(forKey: recentEntriesDefaultsKey)
        UserDefaults.standard.removeObject(forKey: recentEntriesDefaultsKey)
    }

    override func tearDown() {
        if let originalRecentEntriesData {
            UserDefaults.standard.set(originalRecentEntriesData, forKey: recentEntriesDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: recentEntriesDefaultsKey)
        }
        super.tearDown()
    }

    func testRemoveRecentSearchEntryRemovesMatchingEntryAndPersists() {
        let viewModel = SearchViewModel(coordinator: AppCoordinator())
        viewModel.recordRecentSearchEntry("alpha query")
        viewModel.recordRecentSearchEntry("beta query")

        guard let removableEntry = viewModel.recentSearchEntries.first(where: { $0.query == "alpha query" }) else {
            XCTFail("Expected alpha query to exist in recent entries")
            return
        }

        viewModel.removeRecentSearchEntry(removableEntry)

        XCTAssertFalse(viewModel.recentSearchEntries.contains(where: { $0.key == removableEntry.key }))

        let reloadedViewModel = SearchViewModel(coordinator: AppCoordinator())
        XCTAssertFalse(reloadedViewModel.recentSearchEntries.contains(where: { $0.key == removableEntry.key }))
    }

    func testRemoveRecentSearchEntryWithUnknownKeyIsNoOp() {
        let viewModel = SearchViewModel(coordinator: AppCoordinator())
        viewModel.recordRecentSearchEntry("single query")
        let beforeRemoval = viewModel.recentSearchEntries

        viewModel.removeRecentSearchEntry(key: "missing-entry-key")

        XCTAssertEqual(viewModel.recentSearchEntries, beforeRemoval)
    }
}
