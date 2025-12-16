import Foundation
import Shared

/// Manages the ingestion pipeline for OCR text → FTS
/// Coordinates between ProcessingManager and SearchManager
/// Owner: SEARCH agent
public actor IngestionManager {

    // MARK: - Dependencies

    private let searchManager: any SearchProtocol
    private let database: any DatabaseProtocol

    // MARK: - Configuration

    private var config: IngestionConfig
    private var isInitialized = false

    // MARK: - Ingestion Queue

    private var ingestionQueue: [ExtractedText] = []
    private var isProcessingQueue = false

    // MARK: - Statistics

    private var documentsIndexed = 0
    private var totalIndexTimeMs: Double = 0
    private var errorCount = 0

    // MARK: - Initialization

    public init(
        searchManager: any SearchProtocol,
        database: any DatabaseProtocol,
        config: IngestionConfig = .default
    ) {
        self.searchManager = searchManager
        self.database = database
        self.config = config
    }

    // MARK: - Public API

    /// Initialize the ingestion manager
    public func initialize() async throws {
        guard !isInitialized else {
            Log.debug("Ingestion manager already initialized", category: .search)
            return
        }

        isInitialized = true
        Log.info("Ingestion manager initialized", category: .search)
    }

    /// Ingest extracted text (FTS only)
    public func ingest(_ text: ExtractedText) async throws {
        guard isInitialized else {
            throw SearchError.indexNotReady
        }

        let startTime = Date()

        // Index in FTS
        try await searchManager.index(text: text)
        documentsIndexed += 1

        let indexTime = Date().timeIntervalSince(startTime) * 1000
        totalIndexTimeMs += indexTime
    }

    /// Queue text for background ingestion
    public func queueForIngestion(_ text: ExtractedText) async {
        ingestionQueue.append(text)

        // Start processing queue if not already running
        if !isProcessingQueue {
            await processQueue()
        }
    }

    /// Batch ingest multiple texts
    public func ingestBatch(_ texts: [ExtractedText]) async throws {
        for text in texts {
            try await ingest(text)
        }
    }

    /// Remove from index
    public func remove(frameID: FrameID) async throws {
        try await searchManager.removeFromIndex(frameID: frameID)
    }

    /// Update configuration
    public func updateConfig(_ config: IngestionConfig) {
        self.config = config
    }

    /// Get ingestion statistics
    public func getStatistics() async -> IngestionStatistics {
        let avgIndexTime = documentsIndexed > 0
            ? totalIndexTimeMs / Double(documentsIndexed)
            : 0

        return IngestionStatistics(
            documentsIndexed: documentsIndexed,
            averageIndexTimeMs: avgIndexTime,
            queuedItems: ingestionQueue.count,
            errorCount: errorCount
        )
    }

    /// Wait for ingestion queue to drain
    public func waitForQueueDrain() async {
        while !ingestionQueue.isEmpty || isProcessingQueue {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }
    }

    // MARK: - Background Processing

    private func processQueue() async {
        isProcessingQueue = true

        while !ingestionQueue.isEmpty {
            let text = ingestionQueue.removeFirst()

            do {
                try await ingest(text)
            } catch {
                Log.error(
                    "Failed to ingest frame \(text.frameID.stringValue.prefix(8)): \(error.localizedDescription)",
                    category: .search
                )
                errorCount += 1
            }
        }

        isProcessingQueue = false
    }
}

// MARK: - Configuration

public struct IngestionConfig: Sendable {
    /// Skip embedding generation if frame is a duplicate
    public let skipDuplicates: Bool

    public init(
        skipDuplicates: Bool = true
    ) {
        self.skipDuplicates = skipDuplicates
    }

    public static let `default` = IngestionConfig()
}

// MARK: - Statistics

public struct IngestionStatistics: Sendable {
    public let documentsIndexed: Int
    public let averageIndexTimeMs: Double
    public let queuedItems: Int
    public let errorCount: Int

    public init(
        documentsIndexed: Int,
        averageIndexTimeMs: Double,
        queuedItems: Int,
        errorCount: Int
    ) {
        self.documentsIndexed = documentsIndexed
        self.averageIndexTimeMs = averageIndexTimeMs
        self.queuedItems = queuedItems
        self.errorCount = errorCount
    }
}
