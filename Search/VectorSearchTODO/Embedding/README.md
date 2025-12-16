# Local Embedding Service

**Model**: Nomic Embed Text v1.5 (Q4_K_M quantized)
**Engine**: llama.cpp with Metal acceleration
**Platform**: Apple Silicon (M-series) optimized
**Owner**: SEARCH agent

## Overview

The LocalEmbeddingService provides on-device vector embeddings for semantic search in Retrace. It uses the Nomic Embed v1.5 model, which is specifically designed for retrieval tasks and includes asymmetric query/document prefixing.

## Features

- **Metal Acceleration**: Fully offloads to Apple Neural Engine/GPU
- **768-dimensional vectors**: High-quality semantic representations
- **L2 Normalized outputs**: Ready for cosine similarity search
- **8192 token context**: Handles long documents
- **Asymmetric embeddings**: Different prefixes for queries vs documents
- **On-device processing**: No API calls, complete privacy

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Hybrid Search Flow                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  User Query                                                 │
│      │                                                      │
│      ├──────────────┬─────────────────────────────────┐    │
│      ▼              ▼                                 ▼    │
│  FTS Search    LocalEmbeddingService          VectorStore  │
│  (SQLite)      (Nomic v1.5 + Metal)           (SQLite)     │
│      │              │                                 │    │
│      │              └─────────────────────────────────┘    │
│      │                          │                          │
│      └──────────────────────────┼──────────────────────┐   │
│                                 ▼                      │   │
│                        HybridSearchManager             │   │
│                     (Reciprocal Rank Fusion)           │   │
│                                 │                      │   │
│                                 ▼                      │   │
│                          Merged Results                │   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Model Details

### Nomic Embed Text v1.5

- **Source**: [HuggingFace](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF)
- **File**: `nomic-embed-text-v1.5.Q4_K_M.gguf` (~80 MB)
- **Quantization**: 4-bit K-quant (balanced quality/size)
- **Dimensions**: 768
- **Context Length**: 8192 tokens
- **Architecture**: Requires asymmetric prefixes

### Prefix Requirements

Nomic Embed v1.5 **requires** specific prefixes:

```swift
// For indexing documents
"search_document: {your text here}"

// For search queries
"search_query: {your query here}"
```

This is automatically handled by the service via the `EmbeddingTextType` enum.

## Usage

### 1. Initialize Service

```swift
import Search
import Shared

let config = EmbeddingConfig.nomicEmbed  // Default config
let service = LocalEmbeddingService(config: config)

// Load model (one-time setup)
try await service.loadModel()
```

### 2. Generate Embeddings

```swift
// For indexing a document
let docEmbedding = try await service.embed(
    text: "Machine learning is a subset of artificial intelligence",
    type: .document
)

// For search queries
let queryEmbedding = try await service.embed(
    text: "what is ML",
    type: .query
)
```

### 3. Batch Processing

```swift
let texts = [
    "First document to embed",
    "Second document to embed",
    "Third document to embed"
]

let embeddings = try await service.embedBatch(
    texts: texts,
    type: .document
)
```

### 4. Hybrid Search

```swift
let hybridSearch = HybridSearchManager(
    ftsManager: searchManager,
    embeddingService: embeddingService,
    vectorStore: vectorStore,
    database: databaseManager,
    config: .default
)

// Performs both FTS and semantic search, merges with RRF
let results = try await hybridSearch.search(
    query: "compiler error messages",
    limit: 50
)
```

## Configuration

### EmbeddingConfig Options

```swift
EmbeddingConfig(
    modelPath: "~/Library/Application Support/Retrace/models/nomic-embed-text-v1.5.Q4_K_M.gguf",
    contextSize: 8192,      // Max tokens (don't change for Nomic)
    gpuLayers: -1,          // -1 = offload all to GPU
    batchSize: 512,         // Batch size for processing
    useMetalAcceleration: true  // Enable Metal (required for Apple Silicon)
)
```

### HybridSearchConfig Options

```swift
// Balanced (default)
HybridSearchConfig(
    ftsWeight: 0.6,      // 60% weight to keyword search
    semanticWeight: 0.4, // 40% weight to semantic search
    rrf_k: 60            // RRF parameter
)

// FTS-heavy (better for exact matches)
HybridSearchConfig.ftsHeavy

// Semantic-heavy (better for conceptual matches)
HybridSearchConfig.semanticHeavy
```

## Model Download

The model is automatically downloaded on first use:

```swift
let modelPath = "~/Library/Application Support/Retrace/models/nomic-embed-text-v1.5.Q4_K_M.gguf"

// Downloads from HuggingFace if not present
try await LocalEmbeddingService.downloadModelIfNeeded(to: modelPath)
```

**Manual Download:**

```bash
mkdir -p ~/Library/Application\ Support/Retrace/models
cd ~/Library/Application\ Support/Retrace/models

# Download from HuggingFace
curl -L -O https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf
```

## Performance

### Embedding Generation

- **Single embedding**: ~50-100ms on M1/M2
- **Batch (10 texts)**: ~300-500ms
- **Model load time**: ~1-2 seconds

### Hardware Acceleration

The service automatically uses:
- **Metal**: GPU acceleration for matrix operations
- **Neural Engine**: Offloaded layers for inference
- **Accelerate**: SIMD operations for vector math

### Memory Usage

- **Model loaded**: ~100-150 MB
- **Per embedding**: 3 KB (768 floats × 4 bytes)
- **Context cache**: ~50 MB

## Vector Storage

Vectors are stored in SQLite as BLOBs:

```sql
CREATE TABLE embeddings (
    id            INTEGER PRIMARY KEY,
    frame_id      TEXT NOT NULL UNIQUE,
    vector        BLOB NOT NULL,           -- 768 × 4 bytes = 3 KB
    model_version TEXT NOT NULL,
    created_at    INTEGER
);
```

### Storage Estimates

- **Per frame**: 3 KB
- **1 million frames**: ~3 GB
- **1 year (15M frames)**: ~45 GB

## Similarity Search

The SQLiteVectorStore performs cosine similarity search:

```swift
let vectorStore = SQLiteVectorStore(
    databasePath: "~/retrace.db",
    modelVersion: "nomic-embed-v1.5"
)

try await vectorStore.initialize()

// Find 50 nearest neighbors
let neighbors = try await vectorStore.findNearest(
    to: queryEmbedding,
    limit: 50
)

for (frameID, similarity) in neighbors {
    print("Frame: \(frameID), Similarity: \(similarity)")
}
```

### Cosine Similarity

Using Accelerate framework for SIMD performance:

```swift
similarity = dot(a, b) / (||a|| × ||b||)
```

Range: -1 (opposite) to 1 (identical)
Typical threshold: >0.7 for strong match

## Hybrid Search with RRF

Reciprocal Rank Fusion merges FTS and semantic results:

```
RRF Score = 1 / (k + rank)

Hybrid Score = (w_fts × FTS_score) + (w_semantic × Semantic_score)
```

Where:
- `k = 60` (smoothing parameter)
- `w_fts = 0.6` (FTS weight)
- `w_semantic = 0.4` (semantic weight)

## Error Handling

```swift
do {
    try await service.loadModel()
} catch EmbeddingError.modelNotFound(let path) {
    // Model file missing - trigger download
    try await LocalEmbeddingService.downloadModelIfNeeded(to: path)
    try await service.loadModel()
} catch EmbeddingError.modelLoadFailed(let error) {
    // Model corrupted or incompatible
    print("Failed to load model: \(error)")
} catch EmbeddingError.contextLengthExceeded(let tokens, let max) {
    // Text too long (automatically truncated)
    print("Text truncated: \(tokens) -> \(max) tokens")
}
```

## Testing

```bash
# Run embedding service tests
swift test --filter LocalEmbeddingServiceTests

# Note: Tests require model file to be present
# Download it first or tests will be skipped
```

## Production Considerations

### Scaling

For production with millions of vectors:

1. **Use specialized vector DB**:
   - [sqlite-vss](https://github.com/asg017/sqlite-vss) - SQLite extension with HNSW
   - [Qdrant](https://qdrant.tech/) - Rust-based vector DB
   - [Milvus](https://milvus.io/) - Production-scale vector DB

2. **Approximate Nearest Neighbor**:
   - HNSW (Hierarchical Navigable Small World)
   - FAISS (Facebook AI Similarity Search)
   - Annoy (Spotify's ANN library)

3. **Quantization**:
   - Product Quantization (PQ)
   - Binary embeddings
   - Scalar Quantization (SQ)

### Current Limitations

- **Linear scan**: O(n) similarity search
- **SQLite BLOB storage**: Not optimized for vector ops
- **Single-threaded**: Batch processing could be parallelized
- **No incremental indexing**: Full re-embedding on model change

### Future Improvements

- [ ] Integrate sqlite-vss for HNSW indexing
- [ ] Add embedding caching layer
- [ ] Implement background indexing queue
- [ ] Support model hot-swapping
- [ ] Add embedding compression
- [ ] Implement multi-model support

## References

- [Nomic Embed Paper](https://arxiv.org/abs/2402.01613)
- [llama.cpp Documentation](https://github.com/ggerganov/llama.cpp)
- [Reciprocal Rank Fusion](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf)

## See Also

- [../README.md](../README.md) - Search module overview
- [../HybridSearchManager.swift](../HybridSearchManager.swift) - Hybrid search implementation
- [../../Database/Schema.swift](../../Database/Schema.swift) - Database schema
