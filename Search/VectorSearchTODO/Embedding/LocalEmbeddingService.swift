import Foundation
import llama
import Shared

/// Local embedding service using Nomic Embed v1.5 via llama.cpp
/// Optimized for Apple Silicon with Metal acceleration
/// Owner: SEARCH agent
public actor LocalEmbeddingService: EmbeddingProtocol {

    // MARK: - Properties

    private var context: OpaquePointer?
    private var model: OpaquePointer?
    private var config: EmbeddingConfig
    private var _isModelLoaded = false

    // MARK: - Initialization

    public init(config: EmbeddingConfig = .nomicEmbed) {
        self.config = config
    }

    deinit {
        // Synchronous cleanup of C resources
        // Note: Cannot use async/await in deinit
        if let ctx = context {
            llama_free(ctx)
        }
        if let mdl = model {
            llama_free_model(mdl)
        }
    }

    // MARK: - EmbeddingProtocol

    public var isModelLoaded: Bool {
        _isModelLoaded
    }

    public var modelInfo: EmbeddingModelInfo {
        EmbeddingModelInfo(
            name: "nomic-embed-text-v1.5",
            version: "1.5",
            dimensions: 768,  // Nomic Embed v1.5 output dimensions
            maxTokens: 8192
        )
    }

    public func loadModel() async throws {
        guard !_isModelLoaded else {
            Log.debug("Embedding model already loaded", category: .search)
            return
        }

        let expandedPath = NSString(string: config.modelPath).expandingTildeInPath

        // Check if model file exists
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw EmbeddingError.modelNotFound(path: expandedPath)
        }

        // Initialize model parameters
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Int32(config.gpuLayers)
        modelParams.use_mmap = true
        modelParams.use_mlock = false

        // Enable Metal acceleration for Apple Silicon
        if config.useMetalAcceleration {
            modelParams.n_gpu_layers = -1  // Offload all layers to GPU
        }

        // Load model
        guard let loadedModel = llama_load_model_from_file(expandedPath, modelParams) else {
            throw EmbeddingError.modelLoadFailed(underlying: "Failed to load model from file")
        }
        self.model = loadedModel

        // Initialize context parameters
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(config.contextSize)
        contextParams.n_batch = UInt32(config.batchSize)
        contextParams.n_threads = Int32(ProcessInfo.processInfo.processorCount)
        contextParams.embeddings = true  // CRITICAL: Enable embedding mode
        contextParams.offload_kqv = true  // Offload KV cache to GPU

        // Create context
        guard let loadedContext = llama_new_context_with_model(loadedModel, contextParams) else {
            llama_free_model(loadedModel)
            self.model = nil
            throw EmbeddingError.modelLoadFailed(underlying: "Failed to create context")
        }
        self.context = loadedContext

        _isModelLoaded = true
        Log.info("Embedding model loaded successfully with Metal acceleration", category: .search)
    }

    public func unloadModel() async {
        if let ctx = context {
            llama_free(ctx)
            context = nil
        }
        if let mdl = model {
            llama_free_model(mdl)
            model = nil
        }
        _isModelLoaded = false
        Log.info("Embedding model unloaded", category: .search)
    }

    public func embed(text: String) async throws -> [Float] {
        return try await embed(text: text, type: .document)
    }

    /// Generate embedding with text type specification (document vs query)
    public func embed(text: String, type: EmbeddingTextType) async throws -> [Float] {
        guard _isModelLoaded, let ctx = context, let mdl = model else {
            throw EmbeddingError.modelNotLoaded
        }

        // Prepend required prefix for Nomic Embed v1.5
        let prefixedText = addNomicPrefix(to: text, type: type)

        // Tokenize input
        let tokens = try tokenize(text: prefixedText, model: mdl)

        // Check context length
        if tokens.count > config.contextSize {
            // Truncate to fit context window
            let truncatedTokens = Array(tokens.prefix(config.contextSize))
            Log.warning(
                "Text truncated from \(tokens.count) to \(config.contextSize) tokens",
                category: .search
            )
            return try await generateEmbedding(tokens: truncatedTokens, context: ctx, model: mdl)
        }

        return try await generateEmbedding(tokens: tokens, context: ctx, model: mdl)
    }

    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        return try await embedBatch(texts: texts, type: .document)
    }

    /// Generate embeddings for multiple texts in batch
    public func embedBatch(texts: [String], type: EmbeddingTextType) async throws -> [[Float]] {
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(texts.count)

        for text in texts {
            let embedding = try await embed(text: text, type: type)
            embeddings.append(embedding)
        }

        return embeddings
    }

    // MARK: - Private Helpers

    /// Add Nomic-specific prefix based on text type
    private func addNomicPrefix(to text: String, type: EmbeddingTextType) -> String {
        switch type {
        case .document:
            return "search_document: \(text)"
        case .query:
            return "search_query: \(text)"
        }
    }

    /// Tokenize text using llama.cpp tokenizer
    private func tokenize(text: String, model: OpaquePointer) throws -> [llama_token] {
        let maxTokens = config.contextSize + 100  // Add buffer for special tokens

        var tokens = [llama_token](repeating: 0, count: maxTokens)
        let tokenCount = llama_tokenize(
            model,
            text,
            Int32(text.utf8.count),
            &tokens,
            Int32(maxTokens),
            true,  // add_bos
            false  // special
        )

        guard tokenCount >= 0 else {
            throw EmbeddingError.embeddingFailed(underlying: "Tokenization failed")
        }

        return Array(tokens.prefix(Int(tokenCount)))
    }

    /// Generate embedding from tokens
    private func generateEmbedding(
        tokens: [llama_token],
        context: OpaquePointer,
        model: OpaquePointer
    ) async throws -> [Float] {
        // Clear previous state using new API
        let memory = llama_get_memory(context)
        llama_memory_clear(memory, true)

        // Create batch
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        // Manually add tokens to batch (new API doesn't have llama_batch_add helper)
        batch.n_tokens = Int32(tokens.count)
        for (i, token) in tokens.enumerated() {
            batch.token[i] = token
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0  // sequence ID 0
            batch.logits[i] = 1  // We want embeddings for all tokens
        }

        // Decode batch
        let decodeResult = llama_decode(context, batch)
        guard decodeResult == 0 else {
            throw EmbeddingError.embeddingFailed(
                underlying: "Decode failed with error code: \(decodeResult)"
            )
        }

        // Get embeddings using new API
        let embeddingDim = Int(llama_model_n_embd(model))
        guard let embeddingsPtr = llama_get_embeddings_ith(context, Int32(tokens.count - 1)) else {
            throw EmbeddingError.invalidVector
        }

        // Copy embeddings to array
        var rawEmbeddings = [Float](repeating: 0, count: embeddingDim)
        for i in 0..<embeddingDim {
            rawEmbeddings[i] = embeddingsPtr[i]
        }

        // L2 Normalize
        let normalized = try l2Normalize(vector: rawEmbeddings)

        return normalized
    }

    /// L2 normalize a vector
    private func l2Normalize(vector: [Float]) throws -> [Float] {
        // Calculate L2 norm
        let squaredSum = vector.reduce(0) { $0 + $1 * $1 }
        let norm = sqrt(squaredSum)

        guard norm > 0 else {
            throw EmbeddingError.normalizationFailed
        }

        // Normalize
        return vector.map { $0 / norm }
    }
}

// MARK: - Model Download Helper

extension LocalEmbeddingService {

    /// Download the Nomic Embed model from HuggingFace if not present
    public static func downloadModelIfNeeded(to modelPath: String) async throws {
        let expandedPath = NSString(string: modelPath).expandingTildeInPath

        // Check if already exists
        if FileManager.default.fileExists(atPath: expandedPath) {
            Log.info("Embedding model already exists at \(expandedPath)", category: .search)
            return
        }

        // Create directory if needed
        let directory = (expandedPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        Log.info("Downloading Nomic Embed model from HuggingFace...", category: .search)

        // HuggingFace download URL
        let modelURL = "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf"

        guard let url = URL(string: modelURL) else {
            throw EmbeddingError.modelLoadFailed(underlying: "Invalid model URL")
        }

        // Download file
        let (downloadedURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw EmbeddingError.modelLoadFailed(
                underlying: "Failed to download model: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }

        // Move to final location
        try FileManager.default.moveItem(
            at: downloadedURL,
            to: URL(fileURLWithPath: expandedPath)
        )

        Log.info("Embedding model downloaded successfully to \(expandedPath)", category: .search)
    }
}
