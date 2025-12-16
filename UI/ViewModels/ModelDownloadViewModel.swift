import Foundation
import SwiftUI
import Shared

/// ViewModel for model download onboarding
/// Manages download state and progress for AI models
/// Owner: UI module
@MainActor
class ModelDownloadViewModel: ObservableObject {

    // MARK: - Published State

    @Published var models: [ModelInfo] = []
    @Published var modelStatuses: [String: ModelStatus] = [:]
    @Published var downloadProgress: [String: DownloadProgress] = [:]
    @Published var isDownloading = false
    @Published var error: String?

    // MARK: - Model Info (mirrors ModelManager types for UI)

    struct ModelInfo: Identifiable {
        let id = UUID()
        let name: String
        let filename: String
        let sizeMB: Int
        let purpose: String
    }

    struct ModelStatus {
        let isDownloaded: Bool
        let isValid: Bool
    }

    struct DownloadProgress {
        let bytesDownloaded: Int64
        let totalBytes: Int64
        let percentage: Double

        var downloadedMB: Int {
            Int(bytesDownloaded / 1_048_576)
        }

        var totalMB: Int {
            Int(totalBytes / 1_048_576)
        }
    }

    // MARK: - Dependencies

    private var modelManager: Any? // Will be ModelManager actor

    // MARK: - Initialization

    init() {
        // Initialize with static model information
        self.models = [
            ModelInfo(
                name: "Whisper Small",
                filename: "ggml-small.bin",
                sizeMB: 465,
                purpose: "Speech-to-text transcription"
            ),
            ModelInfo(
                name: "Nomic Embed v1.5",
                filename: "nomic-embed-text-v1.5.Q4_K_M.gguf",
                sizeMB: 80,
                purpose: "Semantic search embeddings"
            )
        ]

        // TODO: Initialize modelManager once integrated with AppCoordinator
    }

    // MARK: - Computed Properties

    var totalSizeString: String {
        let totalMB = models.reduce(0) { $0 + $1.sizeMB }
        if totalMB > 1024 {
            let gb = Double(totalMB) / 1024.0
            return String(format: "%.1f GB", gb)
        } else {
            return "\(totalMB) MB"
        }
    }

    var allModelsDownloaded: Bool {
        models.allSatisfy { model in
            modelStatuses[model.name]?.isDownloaded == true &&
            modelStatuses[model.name]?.isValid == true
        }
    }

    // MARK: - Actions

    func checkModelStatuses() async {
        // TODO: Integrate with ModelManager
        // For now, assume no models are downloaded
        for model in models {
            modelStatuses[model.name] = ModelStatus(
                isDownloaded: false,
                isValid: false
            )
        }
    }

    func downloadModels() async {
        isDownloading = true
        error = nil

        do {
            // TODO: Integrate with actual ModelManager
            // Simulate download for now
            for model in models {
                await simulateDownload(for: model)
            }

            Log.info("All models downloaded successfully", category: .app)
        } catch {
            self.error = error.localizedDescription
            Log.error("Model download failed: \(error.localizedDescription)", category: .app)
        }

        isDownloading = false
    }

    func skip() {
        Log.info("User skipped model download", category: .app)
        // App will continue without models
        // Features requiring models will show appropriate messages
    }

    // MARK: - Private Helpers

    private func simulateDownload(for model: ModelInfo) async {
        let totalBytes = Int64(model.sizeMB * 1_048_576)
        let chunks = 100

        for i in 0...chunks {
            let bytesDownloaded = Int64(i) * (totalBytes / Int64(chunks))
            let percentage = Double(i) / Double(chunks)

            downloadProgress[model.name] = DownloadProgress(
                bytesDownloaded: bytesDownloaded,
                totalBytes: totalBytes,
                percentage: percentage
            )

            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }

        modelStatuses[model.name] = ModelStatus(
            isDownloaded: true,
            isValid: true
        )
    }
}

// MARK: - Integration Helper

extension ModelDownloadViewModel {
    /// Set the model manager (called by AppCoordinator)
    func setModelManager(_ manager: Any) {
        self.modelManager = manager
        // TODO: Type properly once ModelManager is integrated
    }
}
