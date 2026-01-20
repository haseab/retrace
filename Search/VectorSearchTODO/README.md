# Vector Search - Disabled for Production

This folder contains the vector search/semantic search implementation that has been **disabled from production builds**.

## What's Here

All vector search related code has been moved to this folder:

### Core Components
- **LocalEmbeddingService.swift** - Nomic Embed v1.5 inference via llama.cpp
- **SQLiteVectorStore.swift** - Vector storage and cosine similarity search
- **HybridSearchManager.swift** - FTS + Vector fusion using Reciprocal Rank Fusion
- **Embedding.swift** - Shared model types (EmbeddingConfig, EmbeddingTextType, etc.)

### Tests
- **LocalEmbeddingServiceTests.swift.disabled** - Unit tests for embedding service

### Documentation
- **Embedding/README.md** - Detailed embedding service documentation

## Why Disabled

The current implementation uses **in-memory linear scan** for vector search:
- Loads ALL vectors into memory
- O(N) complexity for each search query
- Not suitable for production at scale

## Future Implementation

When re-enabling, consider:

1. **Proper Vector Database**
   - Use sqlite-vss extension (Faiss-based ANN)
   - Or dedicated vector DB (Qdrant, Milvus, Pinecone)
   - Implement approximate nearest neighbor (ANN) search

2. **Incremental Indexing**
   - Build indexes incrementally as frames are captured
   - Don't load everything into memory

3. **Model Considerations**
   - Current: Nomic Embed v1.5 (768-dim, 8K context)
   - Evaluate smaller models if latency is critical

## What Was Removed from Production

### Database
- `embeddings` table removed from schema
- V2_AddEmbeddings migration removed

### Protocols (SearchProtocol.swift)
- `EmbeddingProtocol` removed
- `VectorStoreProtocol` removed
- `semanticSearch()` method removed
- `isSemanticSearchAvailable` property removed

### ServiceContainer
- `embeddingService` property removed
- `vectorStore` property removed
- `search` changed from HybridSearchManager to SearchManager (FTS-only)

### Package.swift
- All llama.cpp dependencies removed
- VectorSearchTODO excluded from build

## Build Exclusion

This folder is excluded from compilation in Package.swift:
```swift
.target(
    name: "Search",
    exclude: [
        "VectorSearchTODO",  // Excluded from build
        ...
    ]
)
```

## Re-enabling Vector Search

To re-enable (after implementing proper vector DB):

1. Move files back to appropriate locations
2. Restore database schema (embeddings table)
3. Re-add protocols to SearchProtocol.swift
4. Update ServiceContainer to instantiate services
5. Update Package.swift dependencies
6. Restore V2 migration or create new migration
7. Update IngestionManager to generate embeddings
