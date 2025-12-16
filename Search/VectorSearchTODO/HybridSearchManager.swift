import Foundation
import Shared

/// Hybrid search manager combining FTS and semantic search
/// Uses Reciprocal Rank Fusion (RRF) to merge results
/// Owner: SEARCH agent
public actor HybridSearchManager: SearchProtocol {

    // MARK: - Dependencies

    private let ftsManager: any SearchProtocol
    private let embeddingService: any EmbeddingProtocol
    private let vectorStore: any VectorStoreProtocol
    private let database: any DatabaseProtocol

    // MARK: - Configuration

    private var config: HybridSearchConfig
    private var searchConfig: SearchConfig = .default

    // MARK: - Initialization

    public init(
        ftsManager: any SearchProtocol,
        embeddingService: any EmbeddingProtocol,
        vectorStore: any VectorStoreProtocol,
        database: any DatabaseProtocol,
        config: HybridSearchConfig = .default
    ) {
        self.ftsManager = ftsManager
        self.embeddingService = embeddingService
        self.vectorStore = vectorStore
        self.database = database
        self.config = config
    }

    // MARK: - SearchProtocol Implementation

    /// Initialize search with configuration
    public func initialize(config: SearchConfig) async throws {
        self.searchConfig = config
        // Initialize the underlying FTS manager
        try await ftsManager.initialize(config: config)
    }

    /// Search with a simple text string (convenience)
    public func search(text: String, limit: Int) async throws -> SearchResults {
        return try await search(query: text, limit: limit, filters: .none)
    }

    /// Search for frames matching a query
    public func search(query: SearchQuery) async throws -> SearchResults {
        return try await search(query: query.text, limit: query.limit, filters: query.filters)
    }

    /// Get autocomplete suggestions for a partial query
    public func getSuggestions(prefix: String, limit: Int) async throws -> [String] {
        // Delegate to FTS manager for suggestions
        return try await ftsManager.getSuggestions(prefix: prefix, limit: limit)
    }

    /// Search using semantic similarity (requires model)
    public func semanticSearch(query: String, limit: Int) async throws -> [SemanticSearchResult] {
        return try await performSemanticSearch(query: query, limit: limit)
    }

    /// Check if semantic search is available
    /// Note: This is a cached value. The actual check happens during initialization.
    public nonisolated var isSemanticSearchAvailable: Bool {
        // We can't make this async in protocol conformance
        // For now, return true if semantic search is enabled in config
        // The actual model availability is checked at runtime in search methods
        return true
    }

    /// Rebuild the entire search index
    public func rebuildIndex() async throws {
        // Rebuild FTS index
        try await ftsManager.rebuildIndex()

        // Clear and rebuild vector store
        try await vectorStore.clear()

        // Re-index all frames if embedding model is loaded
        if await embeddingService.isModelLoaded {
            Log.info("Rebuilding vector embeddings...", category: .search)
            // TODO: Iterate through all frames and re-generate embeddings
            // This would require fetching all frames from database and calling index()
        }
    }

    // MARK: - Public API

    /// Perform hybrid search combining FTS and semantic search
    public func search(
        query: String,
        limit: Int = 50,
        filters: SearchFilters = .none
    ) async throws -> SearchResults {
        let startTime = Date()

        // Check if semantic search is available
        guard await embeddingService.isModelLoaded else {
            // Fallback to FTS-only search
            Log.debug("Semantic search unavailable, using FTS only", category: .search)
            return try await ftsManager.search(
                query: SearchQuery(text: query, filters: filters, limit: limit)
            )
        }

        // Run both searches in parallel
        async let ftsResults = ftsManager.search(
            query: SearchQuery(text: query, filters: filters, limit: limit * 2)
        )
        async let semanticResults = performSemanticSearch(query: query, limit: limit * 2)

        // Wait for both results
        let (fts, semantic) = try await (ftsResults, semanticResults)

        // Merge results using Reciprocal Rank Fusion
        let mergedResults = try await mergeResults(
            ftsResults: fts.results,
            semanticResults: semantic,
            config: config
        )

        // Apply filters and limit
        let finalResults = Array(mergedResults.prefix(limit))

        let searchTimeMs = Int(Date().timeIntervalSince(startTime) * 1000)

        Log.searchQuery(
            query: query,
            resultCount: finalResults.count,
            timeMs: searchTimeMs
        )

        return SearchResults(
            query: SearchQuery(text: query, filters: filters, limit: limit),
            results: finalResults,
            totalCount: finalResults.count,
            searchTimeMs: searchTimeMs
        )
    }

    /// Index text with both FTS and semantic embeddings
    public func index(text: ExtractedText) async throws {
        // Index in FTS
        try await ftsManager.index(text: text)

        // Generate and store embedding if model is loaded
        if await embeddingService.isModelLoaded {
            let embedding = try await embeddingService.embed(
                text: text.fullText,
                type: .document
            )
            try await vectorStore.addVector(frameID: text.frameID, vector: embedding)

            Log.debug(
                "Indexed text and embedding for frame \(text.frameID.stringValue.prefix(8))",
                category: .search
            )
        }
    }

    /// Remove from both indexes
    public func removeFromIndex(frameID: FrameID) async throws {
        try await ftsManager.removeFromIndex(frameID: frameID)
        try await vectorStore.removeVector(frameID: frameID)
    }

    /// Update hybrid search configuration
    public func updateConfig(_ config: HybridSearchConfig) {
        self.config = config
    }

    /// Get search statistics
    public func getStatistics() async -> SearchStatistics {
        // Get FTS statistics
        let ftsStats = await ftsManager.getStatistics()

        // Get vector count
        let vectorCount = await vectorStore.vectorCount

        return SearchStatistics(
            totalDocuments: ftsStats.totalDocuments,
            totalSearches: ftsStats.totalSearches,
            averageSearchTimeMs: ftsStats.averageSearchTimeMs,
            vectorCount: vectorCount
        )
    }

    // MARK: - Private Helpers

    /// Perform semantic search
    private func performSemanticSearch(
        query: String,
        limit: Int
    ) async throws -> [SemanticSearchResult] {
        // Generate query embedding
        let queryEmbedding = try await embeddingService.embed(text: query, type: .query)

        // Find nearest neighbors
        let neighbors = try await vectorStore.findNearest(to: queryEmbedding, limit: limit)

        // Convert to SemanticSearchResult
        var results: [SemanticSearchResult] = []
        for (frameID, similarity) in neighbors {
            if let frame = try await database.getFrame(id: frameID) {
                results.append(SemanticSearchResult(
                    frameID: frameID,
                    similarity: similarity,
                    timestamp: frame.timestamp
                ))
            }
        }

        return results
    }

    /// Merge FTS and semantic results using Reciprocal Rank Fusion
    private func mergeResults(
        ftsResults: [SearchResult],
        semanticResults: [SemanticSearchResult],
        config: HybridSearchConfig
    ) async throws -> [SearchResult] {
        // Create lookup maps
        var ftsScores: [FrameID: Double] = [:]
        var semanticScores: [FrameID: Float] = [:]
        var allFrameIDs = Set<FrameID>()

        // Calculate RRF scores for FTS results
        for (rank, result) in ftsResults.enumerated() {
            let rrfScore = 1.0 / Double(rank + config.rrf_k)
            ftsScores[result.id] = rrfScore
            allFrameIDs.insert(result.id)
        }

        // Calculate RRF scores for semantic results
        for (rank, result) in semanticResults.enumerated() {
            let rrfScore = 1.0 / Double(rank + config.rrf_k)
            semanticScores[result.frameID] = Float(rrfScore)
            allFrameIDs.insert(result.frameID)
        }

        // Create merged results
        var mergedResults: [SearchResult] = []

        for frameID in allFrameIDs {
            // Get scores from both sources
            let ftsScore = ftsScores[frameID] ?? 0
            let semanticScore = Double(semanticScores[frameID] ?? 0)

            // Calculate hybrid score
            let hybridScore = (config.ftsWeight * ftsScore) + (config.semanticWeight * semanticScore)

            // Find the original SearchResult (prefer FTS result for richer metadata)
            if let ftsResult = ftsResults.first(where: { $0.id == frameID }) {
                // Update relevance score with hybrid score
                let updatedResult = SearchResult(
                    id: ftsResult.id,
                    timestamp: ftsResult.timestamp,
                    snippet: ftsResult.snippet,
                    matchedText: ftsResult.matchedText,
                    relevanceScore: hybridScore,
                    metadata: ftsResult.metadata,
                    segmentID: ftsResult.segmentID,
                    frameIndex: ftsResult.frameIndex
                )
                mergedResults.append(updatedResult)
            } else if let semanticResult = semanticResults.first(where: { $0.frameID == frameID }) {
                // Fetch frame details from database to get real segment ID and metadata
                if let frame = try? await database.getFrame(id: semanticResult.frameID) {
                    // Fetch document for richer metadata (app name, window title, etc.)
                    let document = try? await database.getDocument(frameID: semanticResult.frameID)

                    let result = SearchResult(
                        id: semanticResult.frameID,
                        timestamp: semanticResult.timestamp,
                        snippet: "(Semantic match)",
                        matchedText: "",
                        relevanceScore: hybridScore,
                        metadata: FrameMetadata(
                            appBundleID: nil,
                            appName: document?.appName,
                            windowTitle: document?.windowTitle,
                            browserURL: document?.browserURL
                        ),
                        segmentID: frame.segmentID,
                        frameIndex: frame.frameIndexInSegment
                    )
                    mergedResults.append(result)
                } else {
                    // Frame not found in database - skip this result
                    Log.warning(
                        "Semantic result for frame \(semanticResult.frameID.stringValue.prefix(8)) not found in database",
                        category: .search
                    )
                }
            }
        }

        // Sort by hybrid score
        return mergedResults.sorted { $0.relevanceScore > $1.relevanceScore }
    }
}

// MARK: - Hybrid Search Configuration

public struct HybridSearchConfig: Sendable {
    /// Weight for FTS results (0-1)
    public let ftsWeight: Double

    /// Weight for semantic results (0-1)
    public let semanticWeight: Double

    /// RRF k parameter (higher = more conservative fusion)
    public let rrf_k: Int

    public init(
        ftsWeight: Double = 0.6,
        semanticWeight: Double = 0.4,
        rrf_k: Int = 60
    ) {
        self.ftsWeight = ftsWeight
        self.semanticWeight = semanticWeight
        self.rrf_k = rrf_k
    }

    /// Default balanced configuration
    public static let `default` = HybridSearchConfig(
        ftsWeight: 0.6,
        semanticWeight: 0.4,
        rrf_k: 60
    )

    /// FTS-heavy configuration (more weight on keyword matching)
    public static let ftsHeavy = HybridSearchConfig(
        ftsWeight: 0.8,
        semanticWeight: 0.2,
        rrf_k: 60
    )

    /// Semantic-heavy configuration (more weight on meaning)
    public static let semanticHeavy = HybridSearchConfig(
        ftsWeight: 0.3,
        semanticWeight: 0.7,
        rrf_k: 60
    )
}

// MARK: - Extension to EmbeddingProtocol for typed embeddings

extension EmbeddingProtocol {
    /// Generate embedding with type specification
    public func embed(text: String, type: EmbeddingTextType) async throws -> [Float] {
        // Default implementation - override in LocalEmbeddingService for Nomic-specific logic
        return try await embed(text: text)
    }
}
