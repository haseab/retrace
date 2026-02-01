import Foundation
import Shared

/// Main search manager implementing SearchProtocol
/// Coordinates query parsing, FTS search, and result ranking
public actor SearchManager: SearchProtocol {

    // MARK: - Dependencies

    private let database: any DatabaseProtocol
    private let ftsEngine: any FTSProtocol
    private let queryParser: QueryParser
    private let resultRanker: ResultRanker
    // ⚠️ RELEASE 2 ONLY - Search highlighting removed for Release 1
    // private let snippetGenerator: SnippetGenerator

    // MARK: - State

    private var config: SearchConfig
    private var isInitialized = false

    // Statistics
    private var totalSearches = 0
    private var searchTimes: [Double] = []

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        ftsEngine: any FTSProtocol
    ) {
        self.database = database
        self.ftsEngine = ftsEngine
        self.queryParser = QueryParser()
        self.resultRanker = ResultRanker()
        // ⚠️ RELEASE 2 ONLY - Search highlighting removed for Release 1
        // self.snippetGenerator = SnippetGenerator()
        self.config = .default
    }

    // MARK: - SearchProtocol: Lifecycle

    public func initialize(config: SearchConfig) async throws {
        self.config = config
        isInitialized = true
        Log.info("Search manager initialized", category: .search)
    }

    // MARK: - SearchProtocol: Full-Text Search

    public func search(query: SearchQuery) async throws -> SearchResults {
        guard isInitialized else {
            throw SearchError.indexNotReady
        }

        let startTime = Date()

        // Validate query
        let validationErrors = queryParser.validate(query: query)
        if !validationErrors.isEmpty {
            throw SearchError.invalidQuery(reason: validationErrors.first?.message ?? "Invalid query")
        }

        // Parse query
        let parsed = try queryParser.parse(rawQuery: query.text)

        // Build FTS query
        let ftsQuery = parsed.toFTSQuery()
        Log.debug("[SearchManager] Raw query: '\(query.text)' → FTS query: '\(ftsQuery)' | terms: \(parsed.searchTerms) | phrases: \(parsed.phrases)", category: .search)

        // Build filters
        var filters = query.filters
        if let appFilter = parsed.appFilter {
            filters = SearchFilters(
                startDate: filters.startDate ?? parsed.dateRange.start,
                endDate: filters.endDate ?? parsed.dateRange.end,
                appBundleIDs: [appFilter],
                excludedAppBundleIDs: filters.excludedAppBundleIDs
            )
        } else if parsed.dateRange.start != nil || parsed.dateRange.end != nil {
            filters = SearchFilters(
                startDate: filters.startDate ?? parsed.dateRange.start,
                endDate: filters.endDate ?? parsed.dateRange.end,
                appBundleIDs: filters.appBundleIDs,
                excludedAppBundleIDs: filters.excludedAppBundleIDs
            )
        }

        // Execute FTS search
        let ftsMatches = try await ftsEngine.search(
            query: ftsQuery,
            filters: filters,
            limit: query.limit,
            offset: query.offset
        )

        // Get total count for pagination
        let totalCount = try await ftsEngine.getMatchCount(query: ftsQuery, filters: filters)

        // Convert FTS matches to SearchResults
        var results: [SearchResult] = []
        for match in ftsMatches {
            // Get frame reference to get segment info
            if let frame = try await database.getFrame(id: match.frameID) {
                // ⚠️ RELEASE 2 ONLY - Use simple matched text extraction for Release 1
                let matchedText = match.snippet.components(separatedBy: " ").prefix(5).joined(separator: " ")

                Log.debug("[SearchManager] Creating SearchResult: frameID=\(match.frameID.value), videoID=\(match.videoID.value), frameIndex=\(match.frameIndex), snippet='\(match.snippet.prefix(50))...'", category: .search)

                let result = SearchResult(
                    id: match.frameID,
                    timestamp: match.timestamp,
                    snippet: match.snippet,
                    matchedText: matchedText,
                    relevanceScore: normalizeRank(match.rank),
                    metadata: FrameMetadata(
                        appBundleID: nil,
                        appName: match.appName,
                        windowName: match.windowName,
                        browserURL: nil
                    ),
                    segmentID: frame.segmentID,
                    videoID: match.videoID,
                    frameIndex: match.frameIndex
                )
                results.append(result)
            }
        }

        // Rank results
        let rankedResults = resultRanker.rank(results, forQuery: query.text)

        // Filter by minimum relevance score
        let filteredResults = rankedResults.filter { $0.relevanceScore >= config.minimumRelevanceScore }

        let searchTimeMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // Update statistics
        totalSearches += 1
        searchTimes.append(Double(searchTimeMs))

        Log.searchQuery(query: query.text, resultCount: filteredResults.count, timeMs: searchTimeMs)

        return SearchResults(
            query: query,
            results: filteredResults,
            totalCount: totalCount,
            searchTimeMs: searchTimeMs
        )
    }

    public func search(text: String, limit: Int) async throws -> SearchResults {
        return try await search(query: SearchQuery(text: text, limit: limit))
    }

    public func getSuggestions(prefix: String, limit: Int) async throws -> [String] {
        guard isInitialized else {
            throw SearchError.indexNotReady
        }

        // Use prefix search to find matching terms
        // Search for "prefix*" to get documents containing words starting with prefix
        let prefixQuery = "\(prefix)*"

        do {
            let results = try await ftsEngine.search(
                query: prefixQuery,
                filters: SearchFilters(),
                limit: min(limit * 3, 100),  // Get more results to extract unique words
                offset: 0
            )

            // Extract unique words from snippets that start with prefix
            var suggestions = Set<String>()
            let lowercasePrefix = prefix.lowercased()

            for match in results {
                // Parse words from snippet
                let words = match.snippet
                    .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                    .map { word in
                        // Remove punctuation
                        word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
                            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                            .lowercased()
                    }
                    .filter { word in
                        // Only keep words that start with prefix
                        !word.isEmpty && word.hasPrefix(lowercasePrefix)
                    }

                suggestions.formUnion(words)

                if suggestions.count >= limit {
                    break
                }
            }

            // Return sorted suggestions
            return Array(suggestions)
                .sorted()
                .prefix(limit)
                .map { $0 }
        } catch {
            // If prefix search fails (e.g., empty prefix), return empty
            return []
        }
    }


    // MARK: - SearchProtocol: Indexing

    public func index(text: ExtractedText, segmentId: Int64, frameId: Int64) async throws -> Int64 {
        guard isInitialized else {
            throw SearchError.indexNotReady
        }

        // Skip empty text
        guard !text.isEmpty else {
            // Return 0 for empty text (no docid assigned)
            return 0
        }

        // Use Rewind-compatible FTS insertion:
        // 1. INSERT INTO searchRanking_content (c0, c1, c2) → get docid
        // 2. INSERT INTO doc_segment (docid, segmentId, frameId)
        // chromeText is now populated from UI chrome separation (menu bar, dock, status bar)
        let docid = try await database.indexFrameText(
            mainText: text.fullText,                       // c0: Main OCR text (excluding chrome)
            chromeText: text.chromeText.isEmpty ? nil : text.chromeText, // c1: UI chrome text
            windowTitle: text.metadata.windowName,         // c2: Window title
            segmentId: segmentId,
            frameId: frameId
        )

        Log.debug("Indexed FTS content \(docid) for frame \(frameId)", category: .search)

        return docid
    }

    public func removeFromIndex(frameID: FrameID) async throws {
        // Delete FTS content and doc_segment for this frame
        try await database.deleteFTSContent(frameId: frameID.value)
        Log.debug("Removed FTS content for frame \(frameID.value)", category: .search)
    }

    public func rebuildIndex() async throws {
        Log.info("Rebuilding FTS index", category: .search)
        try await ftsEngine.rebuildIndex()
        Log.info("FTS index rebuild complete", category: .search)
    }

    // MARK: - SearchProtocol: Statistics

    public func getStatistics() async -> SearchStatistics {
        let dbStats = (try? await database.getStatistics()) ?? DatabaseStatistics(
            frameCount: 0,
            segmentCount: 0,
            documentCount: 0,
            databaseSizeBytes: 0,
            oldestFrameDate: nil,
            newestFrameDate: nil
        )

        let avgSearchTime = searchTimes.isEmpty ? 0.0 : searchTimes.reduce(0, +) / Double(searchTimes.count)

        return SearchStatistics(
            totalDocuments: dbStats.documentCount,
            totalSearches: totalSearches,
            averageSearchTimeMs: avgSearchTime
        )
    }

    // MARK: - Private Helpers

    /// Normalize BM25 rank to 0-1 relevance score
    private func normalizeRank(_ bm25Rank: Double) -> Double {
        // BM25 returns negative values (more negative = better match)
        // Normalize to 0-1 range: higher score for more negative BM25
        return -bm25Rank / (1.0 + abs(bm25Rank))
    }
}
