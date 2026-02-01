import Foundation
import Shared

// MARK: - Embedding Types

/// Type of text being embedded (affects Nomic model prefix)
public enum EmbeddingTextType: Sendable {
    case document  // For indexing documents (prepends "search_document: ")
    case query     // For search queries (prepends "search_query: ")
}

/// Configuration for embedding model
public struct EmbeddingConfig: Sendable {
    /// Path to the GGUF model file
    public let modelPath: String

    /// Context window size (tokens)
    public let contextSize: Int

    /// Number of GPU layers to offload (-1 = all, 0 = CPU only)
    public let gpuLayers: Int

    /// Batch size for processing
    public let batchSize: Int

    /// Enable Metal acceleration (Apple Silicon)
    public let useMetalAcceleration: Bool

    public init(
        modelPath: String,
        contextSize: Int = 8192,
        gpuLayers: Int = -1,  // Default: offload all to GPU
        batchSize: Int = 512,
        useMetalAcceleration: Bool = true
    ) {
        self.modelPath = modelPath
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
        self.batchSize = batchSize
        self.useMetalAcceleration = useMetalAcceleration
    }

    /// Default configuration for Nomic Embed v1.5
    public static let nomicEmbed = EmbeddingConfig(
        modelPath: AppPaths.modelsPath + "/nomic-embed-text-v1.5.Q4_K_M.gguf",
        contextSize: 8192,
        gpuLayers: -1,
        batchSize: 512,
        useMetalAcceleration: true
    )
}

/// Errors specific to embedding operations
public enum EmbeddingError: Error, Sendable {
    case modelNotFound(path: String)
    case modelLoadFailed(underlying: String)
    case contextLengthExceeded(tokens: Int, maxTokens: Int)
    case embeddingFailed(underlying: String)
    case normalizationFailed
    case invalidVector
    case modelNotLoaded

    public var localizedDescription: String {
        switch self {
        case .modelNotFound(let path):
            return "Embedding model not found at path: \(path)"
        case .modelLoadFailed(let error):
            return "Failed to load embedding model: \(error)"
        case .contextLengthExceeded(let tokens, let maxTokens):
            return "Text exceeds context length: \(tokens) > \(maxTokens) tokens"
        case .embeddingFailed(let error):
            return "Failed to generate embedding: \(error)"
        case .normalizationFailed:
            return "Failed to normalize embedding vector"
        case .invalidVector:
            return "Invalid embedding vector returned"
        case .modelNotLoaded:
            return "Embedding model is not loaded"
        }
    }
}
