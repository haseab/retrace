import Foundation
import Shared

/// Manages runtime downloads of AI models (whisper.cpp + embeddings)
/// Downloads models on first app launch with user consent
/// Owner: APP integration
public actor ModelManager {

    // MARK: - Model Configuration

    public struct ModelInfo: Sendable {
        let name: String
        let filename: String
        let url: String
        let sizeBytes: Int64
        let purpose: String

        var sizeMB: Int {
            Int(sizeBytes / 1_048_576)
        }
    }

    public static let whisperModel = ModelInfo(
        name: "Whisper Small",
        filename: "ggml-small.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
        sizeBytes: 465_000_000, // ~465 MB
        purpose: "Speech-to-text transcription"
    )

    public static let embeddingModel = ModelInfo(
        name: "Nomic Embed v1.5",
        filename: "nomic-embed-text-v1.5.Q4_K_M.gguf",
        url: "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf",
        sizeBytes: 80_000_000, // ~80 MB
        purpose: "Semantic search embeddings"
    )

    public static let allModels = [whisperModel, embeddingModel]

    // MARK: - Paths

    private let modelsDirectory: URL

    public init(modelsDirectory: URL? = nil) {
        if let modelsDirectory = modelsDirectory {
            self.modelsDirectory = modelsDirectory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.modelsDirectory = appSupport
                .appendingPathComponent("Retrace")
                .appendingPathComponent("models")
        }
    }

    // MARK: - Model Status

    public struct ModelStatus: Sendable {
        public let model: ModelInfo
        public let isDownloaded: Bool
        public let localPath: URL?
        public let fileSizeBytes: Int64?

        public var isValid: Bool {
            guard let path = localPath,
                  let fileSize = fileSizeBytes,
                  isDownloaded else {
                return false
            }

            // Check if file exists and size is reasonable (within 10% of expected)
            guard FileManager.default.fileExists(atPath: path.path) else {
                return false
            }

            let expectedSize = model.sizeBytes
            let tolerance = expectedSize / 10
            return abs(fileSize - expectedSize) < tolerance
        }
    }

    public func getModelStatus(_ model: ModelInfo) async -> ModelStatus {
        let localPath = modelsDirectory.appendingPathComponent(model.filename)

        guard FileManager.default.fileExists(atPath: localPath.path) else {
            return ModelStatus(
                model: model,
                isDownloaded: false,
                localPath: nil,
                fileSizeBytes: nil
            )
        }

        let fileSize = try? FileManager.default.attributesOfItem(atPath: localPath.path)[.size] as? Int64

        return ModelStatus(
            model: model,
            isDownloaded: true,
            localPath: localPath,
            fileSizeBytes: fileSize
        )
    }

    public func getAllModelStatuses() async -> [ModelStatus] {
        var statuses: [ModelStatus] = []
        for model in Self.allModels {
            let status = await getModelStatus(model)
            statuses.append(status)
        }
        return statuses
    }

    public func areAllModelsDownloaded() async -> Bool {
        let statuses = await getAllModelStatuses()
        return statuses.allSatisfy { $0.isValid }
    }

    // MARK: - Download

    public enum DownloadError: Error, LocalizedError {
        case downloadFailed(String)
        case invalidFileSize(expected: Int64, actual: Int64)
        case fileSystemError(String)

        public var errorDescription: String? {
            switch self {
            case .downloadFailed(let message):
                return "Download failed: \(message)"
            case .invalidFileSize(let expected, let actual):
                return "Invalid file size: expected \(expected) bytes, got \(actual) bytes"
            case .fileSystemError(let message):
                return "File system error: \(message)"
            }
        }
    }

    public struct DownloadProgress: Sendable {
        public let model: ModelInfo
        public let bytesDownloaded: Int64
        public let totalBytes: Int64
        public let percentage: Double

        public var percentageString: String {
            String(format: "%.1f%%", percentage * 100)
        }

        public var downloadedMB: Int {
            Int(bytesDownloaded / 1_048_576)
        }

        public var totalMB: Int {
            Int(totalBytes / 1_048_576)
        }
    }

    public func downloadModel(
        _ model: ModelInfo,
        progressHandler: ((DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        // Create models directory if needed
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = modelsDirectory.appendingPathComponent(model.filename)

        // Check if already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let status = await getModelStatus(model)
            if status.isValid {
                Log.info("Model \(model.name) already downloaded", category: .app)
                return destinationURL
            } else {
                // Invalid file, delete and re-download
                try? FileManager.default.removeItem(at: destinationURL)
                Log.warning("Existing model \(model.name) is invalid, re-downloading", category: .app)
            }
        }

        Log.info("Downloading \(model.name) from \(model.url)", category: .app)

        guard let url = URL(string: model.url) else {
            throw DownloadError.downloadFailed("Invalid URL: \(model.url)")
        }

        // Download to temporary file first (URLSession handles temp file automatically)
        // let tempURL = FileManager.default.temporaryDirectory
        //     .appendingPathComponent(UUID().uuidString)
        //     .appendingPathExtension("tmp")

        // Use URLSession for download with progress
        let session = URLSession.shared

        // Create download task
        let (downloadedURL, response) = try await session.download(from: url)

        // Verify response
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DownloadError.downloadFailed("HTTP error: \(response)")
        }

        // Move to destination
        try FileManager.default.moveItem(at: downloadedURL, to: destinationURL)

        // Verify file size
        let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        guard let fileSize = attributes[.size] as? Int64 else {
            throw DownloadError.fileSystemError("Could not determine file size")
        }

        // Check if size is within 10% of expected (models may have slight variations)
        let expectedSize = model.sizeBytes
        let tolerance = expectedSize / 10
        guard abs(fileSize - expectedSize) < tolerance else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw DownloadError.invalidFileSize(expected: expectedSize, actual: fileSize)
        }

        Log.info("Successfully downloaded \(model.name) (\(fileSize / 1_048_576) MB)", category: .app)

        // Report final progress
        if let progressHandler = progressHandler {
            let progress = DownloadProgress(
                model: model,
                bytesDownloaded: fileSize,
                totalBytes: fileSize,
                percentage: 1.0
            )
            progressHandler(progress)
        }

        return destinationURL
    }

    public func downloadAllModels(
        progressHandler: ((ModelInfo, DownloadProgress) -> Void)? = nil
    ) async throws -> [URL] {
        var downloadedURLs: [URL] = []

        for model in Self.allModels {
            let url = try await downloadModel(model) { progress in
                progressHandler?(model, progress)
            }
            downloadedURLs.append(url)
        }

        return downloadedURLs
    }

    // MARK: - Model Paths

    public func getWhisperModelPath() async -> URL? {
        let status = await getModelStatus(Self.whisperModel)
        return status.isValid ? status.localPath : nil
    }

    public func getEmbeddingModelPath() async -> URL? {
        let status = await getModelStatus(Self.embeddingModel)
        return status.isValid ? status.localPath : nil
    }

    // MARK: - Cleanup

    public func deleteModel(_ model: ModelInfo) async throws {
        let modelPath = modelsDirectory.appendingPathComponent(model.filename)

        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            return
        }

        try FileManager.default.removeItem(at: modelPath)
        Log.info("Deleted model: \(model.name)", category: .app)
    }

    public func deleteAllModels() async throws {
        for model in Self.allModels {
            try await deleteModel(model)
        }
    }
}
