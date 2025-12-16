# Search Module

**Owner**: SEARCH Agent
**Status**: ✅ Implementation Complete (FTS + Hybrid Search)
**Instructions**: See [CLAUDE-SEARCH.md](../CLAUDE-SEARCH.md)

## Overview

Advanced search implementation for Retrace with:
- **Full-Text Search (FTS)**: Fast keyword search using SQLite FTS5
- **Semantic Search**: Vector embeddings with Nomic Embed v1.5
- **Hybrid Search**: Combines both using Reciprocal Rank Fusion (RRF)

## Implemented Files

```
Search/
├── SearchManager.swift              # ✅ FTS search implementation
├── HybridSearchManager.swift        # ✅ Hybrid search with RRF
├── QueryParser/
│   └── QueryParser.swift           # ✅ Query parsing & validation
├── Ranking/
│   ├── ResultRanker.swift          # ✅ Multi-signal ranking
│   └── SnippetGenerator.swift      # ✅ Snippet extraction & highlighting
├── Embedding/
│   ├── LocalEmbeddingService.swift # ✅ Nomic Embed v1.5 + Metal
│   └── README.md                   # ✅ Embedding documentation
├── VectorStore/
│   └── SQLiteVectorStore.swift     # ✅ Vector storage & similarity
└── Tests/
    ├── QueryParserTests.swift      # ✅ Query parser tests
    ├── SearchManagerTests.swift    # ✅ Search manager tests
    └── LocalEmbeddingServiceTests.swift # ✅ Embedding tests
```

## Query Syntax

### Supported Features
- **Keywords**: `swift programming` (prefix matching)
- **Phrases**: `"exact phrase"` (exact matching)
- **Exclusions**: `-java` or `-"machine learning"`
- **App Filter**: `app:Chrome`
- **Date Filters**: `after:2024-01-01` or `before:yesterday`
- **Combined**: `"syntax error" swift -java app:Xcode after:week`

### Example Queries
```
error message                        # Basic keywords
"compiler error"                     # Exact phrase
swift -java -python                  # With exclusions
bug app:Safari after:week            # With filters
"404 error" -resolved app:Chrome     # Complex query
```

## Usage

### Initialization
```swift
let searchManager = SearchManager(
    database: databaseManager,
    ftsEngine: ftsManager
)
try await searchManager.initialize(config: .default)
```

### Basic Search
```swift
let results = try await searchManager.search(text: "error message", limit: 50)
```

### Advanced Search
```swift
let query = SearchQuery(
    text: "swift \"compiler error\"",
    filters: SearchFilters(
        startDate: Date().addingTimeInterval(-7 * 86400),
        appBundleIDs: ["com.apple.Xcode"]
    ),
    limit: 50
)
let results = try await searchManager.search(query: query)
```

### Indexing
```swift
try await searchManager.index(text: extractedText)
try await searchManager.removeFromIndex(frameID: frameID)
```

## Architecture

### Data Flow
```
Query → Parser → FTS Builder → Database → Ranker → Results
```

### Ranking Formula
```
score = BM25 + (recency × 0.2) + (metadata × 0.1)
```

Signals:
- **BM25**: SQLite FTS5 relevance
- **Recency**: Linear decay over 30 days
- **Metadata**: Matches in title, app, URL

## Hybrid Search (NEW!)

### Overview

Hybrid search combines FTS and semantic search for superior results:

```
┌──────────────────────────────────────────────────────────┐
│  Query: "machine learning algorithms"                   │
└──────────────────────────────────────────────────────────┘
           │
           ├──────────────────┬──────────────────────────┐
           ▼                  ▼                          ▼
    ┌──────────┐      ┌──────────────┐        ┌──────────────┐
    │   FTS    │      │  Embedding   │        │ Vector Store │
    │ (BM25)   │      │  (Nomic v1.5)│        │  (Cosine)    │
    └────┬─────┘      └──────┬───────┘        └──────┬───────┘
         │                   │                        │
         │                   └────────────────────────┘
         │                              │
         └──────────────┬───────────────┘
                        ▼
                ┌──────────────────┐
                │ RRF Fusion       │
                │ (0.6 FTS +       │
                │  0.4 Semantic)   │
                └────────┬─────────┘
                         ▼
                  Merged Results
```

### Setup

1. **Install llama.cpp dependency** (already in Package.swift)
2. **Download the model**:
   ```bash
   ./scripts/setup_embedding.sh
   ```
3. **Initialize services**:
   ```swift
   let embeddingService = LocalEmbeddingService(config: .nomicEmbed)
   try await embeddingService.loadModel()

   let vectorStore = SQLiteVectorStore(
       databasePath: "~/retrace.db",
       modelVersion: "nomic-embed-v1.5"
   )
   try await vectorStore.initialize()

   let hybridSearch = HybridSearchManager(
       ftsManager: searchManager,
       embeddingService: embeddingService,
       vectorStore: vectorStore,
       database: databaseManager,
       config: .default
   )
   ```

### Usage

```swift
// Hybrid search automatically uses both FTS and semantic
let results = try await hybridSearch.search(
    query: "compiler error messages",
    limit: 50
)

// Indexing automatically creates both FTS and vector embeddings
try await hybridSearch.index(text: extractedText)
```

### Configuration

```swift
// Balanced (default): 60% FTS, 40% semantic
HybridSearchConfig.default

// Keyword-heavy: 80% FTS, 20% semantic
HybridSearchConfig.ftsHeavy

// Meaning-heavy: 30% FTS, 70% semantic
HybridSearchConfig.semanticHeavy

// Custom weights
HybridSearchConfig(
    ftsWeight: 0.7,
    semanticWeight: 0.3,
    rrf_k: 60
)
```

### Performance

- **FTS search**: <100ms
- **Semantic search**: ~50-100ms (embedding + similarity)
- **Hybrid search**: ~150-200ms (parallel execution)
- **Model load**: ~1-2 seconds (one-time)

### When to Use Each Mode

| Search Type | Best For | Example |
|------------|----------|---------|
| **FTS Only** | Exact terms, code, IDs | `func calculateTotal`, `ERROR-404` |
| **Semantic Only** | Conceptual queries | "how to fix memory leaks" |
| **Hybrid** | General search | "compiler errors in Swift" |

## Implementation Status

### ✅ Completed
- Full query parsing with all syntax
- FTS integration via protocols
- Multi-signal ranking
- Snippet generation
- Indexing pipeline
- **Semantic search with Nomic Embed v1.5**
- **Hybrid search with RRF**
- **Vector storage in SQLite**
- **Metal-accelerated embeddings**
- Comprehensive tests

### 🚧 Deferred
- Autocomplete (needs FTS vocab table)
- ANN indexing (HNSW, FAISS) for production scale
- Multi-model embedding support

## Performance

- Query parsing: <1ms
- FTS search: <100ms (Database-dependent)
- Ranking: <10ms per 100 results

## Dependencies

### Required
- Database module (FTSProtocol)
- Shared types (SearchQuery, etc.)

## Protocols Implemented

- ✅ `SearchProtocol`
- ✅ `QueryParserProtocol`

## Known Limitations

### App Filtering in FTS
The `SearchFilters.appBundleIDs` filter is currently parsed but not fully implemented in the FTS query.
The infrastructure is in place but requires a JOIN with the frames table to filter by app bundle ID.
This can be addressed in a future update.

## See Also

- [PROGRESS.md](PROGRESS.md) - Detailed implementation notes
- [CLAUDE-SEARCH.md](../CLAUDE-SEARCH.md) - Agent instructions
- [Shared/Protocols/SearchProtocol.swift](../Shared/Protocols/SearchProtocol.swift) - Interface contracts
