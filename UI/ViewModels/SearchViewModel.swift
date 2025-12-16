import SwiftUI
import Combine
import Shared
import App

/// ViewModel for the Search view
/// Handles search queries, filtering, and result management with debouncing
@MainActor
public class SearchViewModel: ObservableObject {

    // MARK: - Published State

    @Published public var searchQuery: String = ""
    @Published public var results: SearchResults?
    @Published public var isSearching = false
    @Published public var error: String?

    // Filters
    @Published public var selectedAppFilter: String?
    @Published public var startDate: Date?
    @Published public var endDate: Date?
    @Published public var contentType: ContentType = .all

    // Selected result
    @Published public var selectedResult: SearchResult?
    @Published public var showingFrameViewer = false

    // MARK: - Dependencies

    public let coordinator: AppCoordinator
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Constants

    private let debounceDelay: TimeInterval = 0.3
    private let defaultResultLimit = 50

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // Debounce search query
        $searchQuery
            .debounce(for: .seconds(debounceDelay), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                Task {
                    await self?.performSearch(query: query)
                }
            }
            .store(in: &cancellables)

        // Re-search when filters change
        Publishers.CombineLatest4(
            $selectedAppFilter,
            $startDate,
            $endDate,
            $contentType
        )
        .debounce(for: .seconds(debounceDelay), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self = self, !self.searchQuery.isEmpty else { return }
            Task {
                await self.performSearch(query: self.searchQuery)
            }
        }
        .store(in: &cancellables)
    }

    // MARK: - Search

    public func performSearch(query: String) async {
        guard !query.isEmpty else {
            results = nil
            return
        }

        isSearching = true
        error = nil

        do {
            let searchQuery = buildSearchQuery(query)
            let searchResults = try await coordinator.search(query: searchQuery)

            results = searchResults
            isSearching = false
        } catch {
            self.error = "Search failed: \(error.localizedDescription)"
            isSearching = false
        }
    }

    private func buildSearchQuery(_ text: String) -> SearchQuery {
        let filters = SearchFilters(
            startDate: startDate,
            endDate: endDate,
            appBundleIDs: selectedAppFilter != nil ? [selectedAppFilter!] : nil,
            excludedAppBundleIDs: nil
        )

        return SearchQuery(
            text: text,
            filters: filters,
            limit: defaultResultLimit,
            offset: 0
        )
    }

    // MARK: - Result Selection

    public func selectResult(_ result: SearchResult) {
        selectedResult = result
        showingFrameViewer = true
    }

    public func closeFrameViewer() {
        showingFrameViewer = false
        selectedResult = nil
    }

    // MARK: - Filters

    public func setAppFilter(_ appBundleID: String?) {
        selectedAppFilter = appBundleID
    }

    public func setDateRange(start: Date?, end: Date?) {
        startDate = start
        endDate = end
    }

    public func setContentType(_ type: ContentType) {
        contentType = type
    }

    public func clearAllFilters() {
        selectedAppFilter = nil
        startDate = nil
        endDate = nil
        contentType = .all
    }

    // MARK: - Navigation

    public func nextResult() {
        guard let results = results,
              let current = selectedResult,
              let index = results.results.firstIndex(where: { $0.frameID == current.frameID }),
              index + 1 < results.results.count else {
            return
        }

        selectResult(results.results[index + 1])
    }

    public func previousResult() {
        guard let results = results,
              let current = selectedResult,
              let index = results.results.firstIndex(where: { $0.frameID == current.frameID }),
              index > 0 else {
            return
        }

        selectResult(results.results[index - 1])
    }

    // MARK: - Sharing

    public func generateShareLink(for result: SearchResult) -> URL? {
        DeeplinkHandler.generateSearchLink(
            query: searchQuery,
            timestamp: result.timestamp,
            appBundleID: selectedAppFilter
        )
    }

    public func copyShareLink(for result: SearchResult) {
        guard let url = generateShareLink(for: result) else { return }

        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        #endif
    }

    // MARK: - Statistics

    public var resultCount: Int {
        results?.results.count ?? 0
    }

    public var hasResults: Bool {
        resultCount > 0
    }

    public var isEmpty: Bool {
        !hasResults && !isSearching
    }

    // MARK: - Cleanup

    deinit {
        cancellables.removeAll()
    }
}

// MARK: - Content Type

public enum ContentType: String, CaseIterable, Identifiable {
    case all = "All"
    case ocr = "OCR Text"
    case audio = "Audio Transcription"

    public var id: String { rawValue }

    func toSearchContentTypes() -> [String] {
        switch self {
        case .all:
            return []
        case .ocr:
            return ["ocr"]
        case .audio:
            return ["audio"]
        }
    }
}
