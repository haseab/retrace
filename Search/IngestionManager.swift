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
    /// - Parameters:
    ///   - text: The extracted text from OCR
    ///   - segmentId: The segment ID (app focus session) for doc_segment junction
    ///   - frameId: The frame ID for doc_segment junction
    public func ingest(_ text: ExtractedText, segmentId: Int64, frameId: Int64) async throws {
        guard isInitialized else {
            throw SearchError.indexNotReady
        }

        let startTime = Date()

        // Index in FTS (Rewind-compatible)
        _ = try await searchManager.index(text: text, segmentId: segmentId, frameId: frameId)
        documentsIndexed += 1

        // Update segment's browserURL if OCR extracted one and segment doesn't have it yet
        // This handles browsers that don't expose URL via Accessibility API
        // TODO: Implement updateSegmentBrowserURL in DatabaseProtocol
        /*
        if let browserURL = text.metadata.browserURL, !browserURL.isEmpty {
            do {
                try await database.updateSegmentBrowserURL(id: segmentId, browserURL: browserURL)
            } catch {
                // Log but don't fail ingestion if URL update fails
                Log.warning("Failed to update segment browserURL from OCR: \(error)", category: .search)
            }
        }
        */

        let indexTime = Date().timeIntervalSince(startTime) * 1000
        totalIndexTimeMs += indexTime
    }

    /// Queue text for background ingestion
    /// Note: This is legacy API - prefer using ingest() with segmentId/frameId directly
    @available(*, deprecated, message: "Use ingest(_:segmentId:frameId:) instead")
    public func queueForIngestion(_ text: ExtractedText) async {
        // Cannot queue without segmentId/frameId - log warning
        Log.warning("queueForIngestion called without segmentId/frameId - text will not be indexed", category: .search)
    }

    /// Batch ingest multiple texts
    /// - Parameters:
    ///   - items: Array of (text, segmentId, frameId) tuples
    public func ingestBatch(_ items: [(text: ExtractedText, segmentId: Int64, frameId: Int64)]) async throws {
        for item in items {
            try await ingest(item.text, segmentId: item.segmentId, frameId: item.frameId)
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
            queuedItems: 0,  // Queue no longer used
            errorCount: errorCount
        )
    }

    /// Wait for ingestion queue to drain
    /// Note: Deprecated - queue-based ingestion is no longer supported
    @available(*, deprecated, message: "Queue-based ingestion no longer supported")
    public func waitForQueueDrain() async {
        // No-op - queue is no longer used
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
