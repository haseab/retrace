import Foundation

// MARK: - Search Protocol

/// Search operations over indexed content
/// Owner: SEARCH agent
public protocol SearchProtocol: Actor {

    // MARK: - Lifecycle

    /// Initialize search with configuration
    func initialize(config: SearchConfig) async throws

    // MARK: - Full-Text Search

    /// Search for frames matching a query
    func search(query: SearchQuery) async throws -> SearchResults

    /// Search with a simple text string (convenience)
    func search(text: String, limit: Int) async throws -> SearchResults

    /// Get autocomplete suggestions for a partial query
    func getSuggestions(prefix: String, limit: Int) async throws -> [String]


    // MARK: - Indexing

    /// Index extracted text from a frame
    func index(text: ExtractedText) async throws

    /// Remove a frame from the index
    func removeFromIndex(frameID: FrameID) async throws

    /// Rebuild the entire search index
    func rebuildIndex() async throws

    // MARK: - Statistics

    /// Get search statistics
    func getStatistics() async -> SearchStatistics
}


// MARK: - Supporting Types

/// Search statistics
public struct SearchStatistics: Sendable {
    public let totalDocuments: Int
    public let totalSearches: Int
    public let averageSearchTimeMs: Double

    public init(
        totalDocuments: Int,
        totalSearches: Int,
        averageSearchTimeMs: Double
    ) {
        self.totalDocuments = totalDocuments
        self.totalSearches = totalSearches
        self.averageSearchTimeMs = averageSearchTimeMs
    }
}

// MARK: - Query Parser Protocol

/// Parse and validate search queries
/// Owner: SEARCH agent
public protocol QueryParserProtocol: Sendable {

    /// Parse a raw query string into a structured query
    func parse(rawQuery: String) throws -> ParsedQuery

    /// Validate a query
    func validate(query: SearchQuery) -> [QueryValidationError]
}

/// A parsed search query with extracted filters
public struct ParsedQuery: Sendable {
    public let searchTerms: [String]
    public let phrases: [String]          // Exact phrase matches
    public let excludedTerms: [String]    // Terms prefixed with -
    public let appFilter: String?         // app:AppName
    public let dateRange: (start: Date?, end: Date?)

    public init(
        searchTerms: [String],
        phrases: [String] = [],
        excludedTerms: [String] = [],
        appFilter: String? = nil,
        dateRange: (start: Date?, end: Date?) = (nil, nil)
    ) {
        self.searchTerms = searchTerms
        self.phrases = phrases
        self.excludedTerms = excludedTerms
        self.appFilter = appFilter
        self.dateRange = dateRange
    }
}

/// Query validation errors
public struct QueryValidationError: Sendable {
    public let message: String
    public let position: Int?  // Character position in query, if applicable

    public init(message: String, position: Int? = nil) {
        self.message = message
        self.position = position
    }
}
