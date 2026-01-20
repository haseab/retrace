# SEARCH Agent Instructions

You are responsible for the **Search** module of Retrace. Your job is to implement search functionality including query parsing, full-text search via SQLite FTS5, and result ranking.

**v0.1 Status**: ✅ Full-text search with FTS5 fully implemented. Query parser supports filters (app:, date:, -exclude). **No vector/semantic search in v0.1** (planned for v0.2+ with llama.cpp embeddings).

## Your Directory

```
Search/
├── SearchManager.swift            # Main SearchProtocol implementation
├── QueryParser/
│   ├── QueryParser.swift          # QueryParserProtocol implementation
│   ├── QueryTokenizer.swift       # Tokenize raw query strings
│   └── FilterExtractor.swift      # Extract filters (app:, date:, etc.)
├── Ranking/
│   ├── ResultRanker.swift         # Rank and sort results
│   └── SnippetGenerator.swift     # Generate highlighted snippets
├── VectorSearchTODO/              # NOT IMPLEMENTED IN v0.1 (future)
│   ├── Embedding/
│   └── VectorStore/
└── Tests/
    ├── QueryParserTests.swift
    ├── SearchManagerTests.swift
    └── RankingTests.swift
```

## Protocols You Must Implement

### 1. `SearchProtocol` (from `Shared/Protocols/SearchProtocol.swift`)
- Full-text search via FTS5
- Indexing text content
- Search statistics

### 2. `QueryParserProtocol` (from `Shared/Protocols/SearchProtocol.swift`)
- Parse query syntax
- Extract filters (app:, date:, -exclude)

**Note**: EmbeddingProtocol and VectorStoreProtocol exist but are NOT implemented in v0.1. Semantic/vector search is planned for v0.2+.

## Key Implementation Details

### 1. Query Parser

Support rich query syntax:
- `error message` - Basic keyword search
- `"exact phrase"` - Exact phrase matching
- `-excluded` - Exclude term
- `app:Chrome` - Filter by app
- `after:2024-01-01` - Date filters

```swift
struct QueryParser: QueryParserProtocol {
    func parse(rawQuery: String) throws -> ParsedQuery {
        var searchTerms: [String] = []
        var phrases: [String] = []
        var excludedTerms: [String] = []
        var appFilter: String? = nil
        var startDate: Date? = nil
        var endDate: Date? = nil

        // Tokenize preserving quotes
        let tokens = tokenize(rawQuery)

        for token in tokens {
            if token.hasPrefix("\"") && token.hasSuffix("\"") {
                // Exact phrase
                let phrase = String(token.dropFirst().dropLast())
                phrases.append(phrase)
            } else if token.hasPrefix("-") {
                // Excluded term
                excludedTerms.append(String(token.dropFirst()))
            } else if token.lowercased().hasPrefix("app:") {
                // App filter
                appFilter = String(token.dropFirst(4))
            } else if token.lowercased().hasPrefix("after:") {
                // Start date
                let dateStr = String(token.dropFirst(6))
                startDate = parseDate(dateStr)
            } else if token.lowercased().hasPrefix("before:") {
                // End date
                let dateStr = String(token.dropFirst(7))
                endDate = parseDate(dateStr)
            } else {
                // Regular search term
                searchTerms.append(token)
            }
        }

        return ParsedQuery(
            searchTerms: searchTerms,
            phrases: phrases,
            excludedTerms: excludedTerms,
            appFilter: appFilter,
            dateRange: (startDate, endDate)
        )
    }

    private func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in query {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == " " && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func parseDate(_ str: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: str)
    }
}
```

### 2. FTS Query Builder

Convert parsed query to SQLite FTS5 syntax:

```swift
extension ParsedQuery {
    func toFTSQuery() -> String {
        var parts: [String] = []

        // Regular terms (with prefix matching)
        for term in searchTerms {
            parts.append("\(term)*")  // Prefix match
        }

        // Exact phrases
        for phrase in phrases {
            parts.append("\"\(phrase)\"")
        }

        // Excluded terms
        for term in excludedTerms {
            parts.append("NOT \(term)")
        }

        return parts.joined(separator: " ")
    }
}
```

### 3. Search Manager

```swift
public actor SearchManager: SearchProtocol {
    private let database: any FTSProtocol
    private let embeddingManager: EmbeddingManager?
    private let vectorStore: VectorStore?
    private let queryParser: QueryParser
    private let resultRanker: ResultRanker
    private var config: SearchConfig

    public func search(query: SearchQuery) async throws -> SearchResults {
        let startTime = Date()

        // Parse query
        let parsed = try queryParser.parse(rawQuery: query.text)

        // Build FTS query
        let ftsQuery = parsed.toFTSQuery()

        // Build filters
        var filters = query.filters
        if let appFilter = parsed.appFilter {
            filters = SearchFilters(
                startDate: filters.startDate ?? parsed.dateRange.start,
                endDate: filters.endDate ?? parsed.dateRange.end,
                appBundleIDs: [appFilter],
                excludedAppBundleIDs: filters.excludedAppBundleIDs
            )
        }

        // Execute FTS search
        let ftsMatches = try await database.search(
            query: ftsQuery,
            filters: filters,
            limit: query.limit,
            offset: query.offset
        )

        // Get total count for pagination
        let totalCount = try await database.getMatchCount(query: ftsQuery, filters: filters)

        // Convert to SearchResults
        let results = ftsMatches.map { match in
            SearchResult(
                id: match.frameID,
                timestamp: match.timestamp,
                snippet: match.snippet,
                matchedText: extractMatchedText(from: match.snippet),
                relevanceScore: normalizeRank(match.rank),
                metadata: FrameMetadata(
                    appName: match.appName,
                    windowTitle: match.windowTitle
                ),
                segmentID: SegmentID(), // Would need to join with frames table
                frameIndex: 0
            )
        }

        // Rank results
        let rankedResults = resultRanker.rank(results, forQuery: query.text)

        let searchTimeMs = Int(Date().timeIntervalSince(startTime) * 1000)

        return SearchResults(
            query: query,
            results: rankedResults,
            totalCount: totalCount,
            searchTimeMs: searchTimeMs
        )
    }

    public func search(text: String, limit: Int) async throws -> SearchResults {
        return try await search(query: SearchQuery(text: text, limit: limit))
    }

    private func normalizeRank(_ bm25Rank: Double) -> Double {
        // BM25 returns negative values (more negative = better match)
        // Normalize to 0-1 range
        return 1.0 / (1.0 + abs(bm25Rank))
    }

    private func extractMatchedText(from snippet: String) -> String {
        // Extract text between <mark> tags
        let pattern = "<mark>(.*?)</mark>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: snippet, range: NSRange(snippet.startIndex..., in: snippet)),
              let range = Range(match.range(at: 1), in: snippet) else {
            return snippet
        }
        return String(snippet[range])
    }
}
```

### 4. Result Ranker

Apply additional ranking on top of FTS:

```swift
struct ResultRanker {
    func rank(_ results: [SearchResult], forQuery query: String) -> [SearchResult] {
        let queryTerms = Set(query.lowercased().split(separator: " ").map(String.init))

        return results.sorted { a, b in
            let scoreA = computeScore(a, queryTerms: queryTerms)
            let scoreB = computeScore(b, queryTerms: queryTerms)
            return scoreA > scoreB
        }
    }

    private func computeScore(_ result: SearchResult, queryTerms: Set<String>) -> Double {
        var score = result.relevanceScore

        // Boost for recency
        let ageInDays = Date().timeIntervalSince(result.timestamp) / 86400
        let recencyBoost = max(0, 1.0 - (ageInDays / 30.0)) * 0.2
        score += recencyBoost

        // Boost if query appears in window title
        if let title = result.metadata.windowTitle?.lowercased() {
            let titleMatches = queryTerms.filter { title.contains($0) }.count
            score += Double(titleMatches) * 0.1
        }

        return score
    }
}
```

### 5. Autocomplete Suggestions

```swift
extension SearchManager {
    public func getSuggestions(prefix: String, limit: Int) async throws -> [String] {
        // Query FTS for terms starting with prefix
        let sql = """
            SELECT DISTINCT term FROM documents_fts_vocab
            WHERE term LIKE ? || '%'
            ORDER BY doc_count DESC
            LIMIT ?
        """
        // Note: This requires creating an FTS vocab table:
        // CREATE VIRTUAL TABLE documents_fts_vocab USING fts5vocab(documents_fts, instance);

        // Execute and return suggestions
        return []  // Implement with actual query
    }
}
```

### 6. Semantic Search (Optional)

Use CoreML for text embeddings:

```swift
import CoreML

actor EmbeddingManager: EmbeddingProtocol {
    private var model: MLModel?
    public private(set) var isModelLoaded = false

    public let modelInfo = EmbeddingModelInfo.miniLM

    public func loadModel() async throws {
        // Load CoreML model from bundle
        guard let modelURL = Bundle.main.url(forResource: "MiniLM", withExtension: "mlmodelc") else {
            throw SearchError.modelLoadFailed(modelName: modelInfo.name)
        }

        self.model = try MLModel(contentsOf: modelURL)
        self.isModelLoaded = true
    }

    public func unloadModel() async {
        self.model = nil
        self.isModelLoaded = false
    }

    public func embed(text: String) async throws -> [Float] {
        guard let model = model else {
            throw SearchError.modelLoadFailed(modelName: modelInfo.name)
        }

        // Tokenize and create input
        // This depends on the specific model's input format
        // MiniLM typically expects token IDs

        // For simplicity, showing the concept:
        let input = try createModelInput(text: text)
        let output = try model.prediction(from: input)

        // Extract embedding vector from output
        guard let embedding = output.featureValue(for: "embeddings")?.multiArrayValue else {
            throw SearchError.embeddingFailed(underlying: "No embedding in output")
        }

        return convertToFloatArray(embedding)
    }

    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        return try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask {
                    let embedding = try await self.embed(text: text)
                    return (index, embedding)
                }
            }

            var results = [[Float]](repeating: [], count: texts.count)
            for try await (index, embedding) in group {
                results[index] = embedding
            }
            return results
        }
    }
}
```

### 7. Vector Store (Simple In-Memory)

For small-scale semantic search:

```swift
actor VectorStore: VectorStoreProtocol {
    private var vectors: [FrameID: [Float]] = [:]

    public var vectorCount: Int { vectors.count }

    public func addVector(frameID: FrameID, vector: [Float]) async throws {
        vectors[frameID] = vector
    }

    public func removeVector(frameID: FrameID) async throws {
        vectors.removeValue(forKey: frameID)
    }

    public func findNearest(to queryVector: [Float], limit: Int) async throws -> [(frameID: FrameID, similarity: Float)] {
        var results: [(FrameID, Float)] = []

        for (frameID, vector) in vectors {
            let similarity = cosineSimilarity(queryVector, vector)
            results.append((frameID, similarity))
        }

        // Sort by similarity descending and take top N
        return results
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0
    }

    public func clear() async throws {
        vectors.removeAll()
    }

    public func initialize() async throws {
        // Load from disk if persisted
    }
}
```

### 8. Indexing Pipeline

```swift
extension SearchManager {
    public func index(text: ExtractedText) async throws {
        // Create indexed document
        let document = IndexedDocument(
            id: 0,  // Will be assigned by DB
            frameID: text.frameID,
            timestamp: text.timestamp,
            content: text.fullText,
            appName: text.metadata.appName,
            windowTitle: text.metadata.windowTitle,
            browserURL: text.metadata.browserURL
        )

        // Insert into database (which updates FTS)
        let docID = try await database.insertDocument(document)

        // If semantic search enabled, generate embedding
        if config.semanticSearchEnabled, let embedder = embeddingManager, let store = vectorStore {
            let embedding = try await embedder.embed(text: text.fullText)
            try await store.addVector(frameID: text.frameID, vector: embedding)
        }
    }

    public func removeFromIndex(frameID: FrameID) async throws {
        // Remove from database
        if let doc = try await database.getDocument(frameID: frameID) {
            try await database.deleteDocument(id: doc.id)
        }

        // Remove from vector store
        if let store = vectorStore {
            try await store.removeVector(frameID: frameID)
        }
    }
}
```

## Error Handling

Use errors from `Shared/Models/Errors.swift`:
```swift
throw SearchError.invalidQuery(reason: "Empty query")
throw SearchError.indexNotReady
throw SearchError.modelLoadFailed(modelName: "MiniLM")
```

## Testing Strategy

1. Test query parsing with various syntax
2. Test FTS query generation
3. Test result ranking
4. Test autocomplete suggestions
5. Test semantic search (if implemented)
6. Test indexing and removal
7. Test edge cases (empty queries, special characters)

## Dependencies

- **Input from**: PROCESSING module (ExtractedText to index)
- **Output to**: UI (SearchResults)
- **Uses**: DATABASE module (FTSProtocol for queries)
- **Uses types**: `SearchQuery`, `SearchResults`, `SearchResult`, `ExtractedText`, `ParsedQuery`

## DO NOT

- Modify any files outside `Search/`
- Import from other module directories (only `Shared/`)
- Implement database operations (use DATABASE's FTSProtocol)
- Handle OCR or text extraction (that's PROCESSING's job)

## Performance Targets

- Search: <100ms for typical queries
- Autocomplete: <50ms
- Indexing: <10ms per document
- Semantic search: <500ms (acceptable since it's optional)

## Getting Started

1. Create `Search/QueryParser/QueryParser.swift`
2. Create `Search/Ranking/ResultRanker.swift`
3. Create `Search/SearchManager.swift` conforming to `SearchProtocol`
4. Write tests for query parsing
5. (Optional) Create `Search/Semantic/` for embedding support

Start with the query parser and FTS integration, then add ranking. Semantic search can be added last as it's optional.
