import Foundation
import Shared
import Database
import Storage
import Capture
import Processing
import Search
import Migration

/// Main coordinator that wires all modules together
/// Implements the core data pipeline: Capture → Storage → Processing → Database → Search
/// Owner: APP integration
public actor AppCoordinator {

    // MARK: - Properties

    private let services: ServiceContainer
    private var captureTask: Task<Void, Never>?
    // ⚠️ RELEASE 2 ONLY
    // private var audioTask: Task<Void, Never>?
    private var isRunning = false

    // Statistics
    private var pipelineStartTime: Date?
    private var totalFramesProcessed = 0
    private var totalErrors = 0

    // Session tracking
    private var currentSession: AppSession?

    // MARK: - Initialization

    public init(services: ServiceContainer) {
        self.services = services
        Log.info("AppCoordinator created", category: .app)
    }

    /// Convenience initializer with default configuration
    public init() {
        self.services = ServiceContainer()
        Log.info("AppCoordinator created with default services", category: .app)
    }

    // MARK: - Public Accessors

    nonisolated public var onboardingManager: OnboardingManager {
        services.onboardingManager
    }

    nonisolated public var modelManager: ModelManager {
        services.modelManager
    }

    // MARK: - Lifecycle

    /// Initialize all services
    public func initialize() async throws {
        Log.info("Initializing AppCoordinator...", category: .app)
        try await services.initialize()
        Log.info("AppCoordinator initialized successfully", category: .app)
    }

    /// Register Rewind data source if enabled
    /// Should be called after onboarding completes if user opted in
    public func registerRewindSourceIfEnabled() async throws {
        try await services.registerRewindSourceIfEnabled()
    }

    /// Setup callback for accessibility permission warnings
    public func setupAccessibilityWarningCallback(_ callback: @escaping @Sendable () -> Void) async {
        services.capture.onAccessibilityPermissionWarning = callback
    }

    /// Start the capture pipeline
    public func startPipeline() async throws {
        guard !isRunning else {
            Log.warning("Pipeline already running", category: .app)
            return
        }

        Log.info("Starting capture pipeline...", category: .app)

        // Check permissions first
        guard await services.capture.hasPermission() else {
            Log.error("Screen recording permission not granted", category: .app)
            throw AppError.permissionDenied(permission: "screen recording")
        }

        // Set up callback for when capture stops unexpectedly (e.g., user clicks "Stop sharing")
        services.capture.onCaptureStopped = { [weak self] in
            guard let self = self else { return }
            await self.handleCaptureStopped()
        }

        // Start screen capture
        try await services.capture.startCapture(config: await services.capture.getConfig())

        // ⚠️ RELEASE 2 ONLY - Audio capture commented out
        // // Start audio capture
        // let audioConfig = AudioCaptureConfig.default
        // try await services.audioCapture.startCapture(config: audioConfig)
        // Log.info("Audio capture started", category: .app)

        // Start processing pipelines
        isRunning = true
        pipelineStartTime = Date()
        captureTask = Task {
            await runPipeline()
        }
        // ⚠️ RELEASE 2 ONLY
        // audioTask = Task {
        //     await runAudioPipeline()
        // }

        Log.info("Capture pipeline started successfully", category: .app)
    }

    /// Stop the capture pipeline
    public func stopPipeline() async throws {
        guard isRunning else {
            Log.warning("Pipeline not running", category: .app)
            return
        }

        Log.info("Stopping capture pipeline...", category: .app)

        // Stop screen capture
        try await services.capture.stopCapture()

        // ⚠️ RELEASE 2 ONLY
        // // Stop audio capture
        // try await services.audioCapture.stopCapture()

        // Cancel pipeline tasks
        captureTask?.cancel()
        captureTask = nil
        // ⚠️ RELEASE 2 ONLY
        // audioTask?.cancel()
        // audioTask = nil

        // Wait for processing queue to drain
        await services.processing.waitForQueueDrain()
        // Audio processing drains automatically when stream ends

        isRunning = false
        Log.info("Capture pipeline stopped successfully", category: .app)
    }

    /// Shutdown all services
    public func shutdown() async throws {
        if isRunning {
            try await stopPipeline()
        }

        Log.info("Shutting down AppCoordinator...", category: .app)
        try await services.shutdown()
        Log.info("AppCoordinator shutdown complete", category: .app)
    }

    /// Handle capture stopped unexpectedly (e.g., user clicked "Stop sharing" in macOS)
    private func handleCaptureStopped() async {
        guard isRunning else { return }

        Log.info("Capture stopped unexpectedly, cleaning up pipeline...", category: .app)

        // Cancel pipeline tasks
        captureTask?.cancel()
        captureTask = nil

        // Wait for processing queue to drain
        await services.processing.waitForQueueDrain()

        isRunning = false
        Log.info("Pipeline cleanup complete after unexpected stop", category: .app)
    }

    // MARK: - Pipeline Implementation

    /// Main pipeline: Capture → Storage → Processing → Database → Search
    private func runPipeline() async {
        Log.info("Pipeline processing started", category: .app)

        // Get the frame stream from capture
        let frameStream = await services.capture.frameStream

        // Current segment writer
        var currentWriter: SegmentWriter?
        var frameCount = 0
        let maxFramesPerSegment = 150 // 5 minutes at 2s intervals

        for await frame in frameStream {
            // Check if task was cancelled
            if Task.isCancelled {
                Log.info("Pipeline task cancelled", category: .app)
                break
            }

            do {
                // STEP 1: Store frame in video segment
                if currentWriter == nil || frameCount >= maxFramesPerSegment {
                    // Finalize previous segment
                    if let writer = currentWriter {
                        let segment = try await writer.finalize()
                        try await services.database.insertSegment(segment)
                        Log.debug("Segment finalized: \(segment.id.stringValue)", category: .app)
                    }

                    // Create new segment
                    currentWriter = try await services.storage.createSegmentWriter()
                    frameCount = 0
                    Log.debug("New segment created", category: .app)
                }

                try await currentWriter?.appendFrame(frame)
                frameCount += 1

                // STEP 2: Track app session changes
                try await trackSessionChange(frame: frame)

                // STEP 3: Extract text via OCR and Accessibility
                let extractedText = try await services.processing.extractText(from: frame)

                // STEP 4: Store frame reference in database
                let segmentID = await currentWriter!.segmentID
                let frameRef = FrameReference(
                    id: frame.id,
                    timestamp: frame.timestamp,  // Real capture timestamp (source of truth)
                    segmentID: segmentID,
                    sessionID: currentSession?.id,  // Link to current session
                    frameIndexInSegment: frameCount - 1,  // Position in video file (NOT for timestamp calculation!)
                    metadata: extractedText.metadata,  // Use updated metadata from processing
                    source: .native
                )
                try await services.database.insertFrame(frameRef)

                // STEP 5: Store text regions (OCR bounding boxes)
                for region in extractedText.regions {
                    try await services.database.insertTextRegion(region)
                }

                // STEP 6: Index text for search
                try await services.search.index(text: extractedText)

                totalFramesProcessed += 1

                if totalFramesProcessed % 10 == 0 {
                    Log.debug("Pipeline processed \(totalFramesProcessed) frames", category: .app)
                }

            } catch {
                totalErrors += 1
                Log.error("Pipeline error processing frame: \(error)", category: .app)

                // Continue processing despite errors
                continue
            }
        }

        // Finalize last segment
        if let writer = currentWriter {
            do {
                let segment = try await writer.finalize()
                try await services.database.insertSegment(segment)
                Log.info("Final segment finalized: \(segment.id.stringValue)", category: .app)
            } catch {
                Log.error("Failed to finalize last segment: \(error)", category: .app)
            }
        }

        // Close final session
        if let session = currentSession {
            try? await services.database.updateSessionEndTime(id: session.id, endTime: Date())
            currentSession = nil
        }

        Log.info("Pipeline processing completed. Total frames: \(totalFramesProcessed), Errors: \(totalErrors)", category: .app)
    }

    /// Track app/window changes and create/close sessions accordingly
    private func trackSessionChange(frame: CapturedFrame) async throws {
        let metadata = frame.metadata

        // Check if app or window changed
        let appChanged = currentSession?.appBundleID != metadata.appBundleID
        let windowChanged = currentSession?.windowName != metadata.windowName

        if appChanged || windowChanged || currentSession == nil {
            // Close previous session
            if let session = currentSession {
                try await services.database.updateSessionEndTime(id: session.id, endTime: frame.timestamp)
                Log.debug("Closed session: \(session.appBundleID) - \(session.windowName ?? "nil")", category: .app)
            }

            // Create new session
            let newSession = AppSession(
                appBundleID: metadata.appBundleID ?? "unknown",
                appName: metadata.appName,
                windowName: metadata.windowName,
                browserURL: metadata.browserURL,
                displayID: metadata.displayID,
                startTime: frame.timestamp,
                endTime: nil  // Active session
            )

            try await services.database.insertSession(newSession)
            currentSession = newSession
            Log.debug("Started session: \(newSession.appBundleID) - \(newSession.windowName ?? "nil")", category: .app)
        }
    }

    /// Audio pipeline: AudioCapture → AudioProcessing (whisper.cpp) → Database
    // ⚠️ RELEASE 2 ONLY - Audio pipeline commented out
    // private func runAudioPipeline() async {
    //     Log.info("Audio pipeline processing started", category: .app)
    //
    //     // Get the audio stream from capture
    //     let audioStream = await services.audioCapture.audioStream
    //
    //     // Start processing the stream (this will run until the stream ends)
    //     await services.audioProcessing.startProcessing(audioStream: audioStream)
    //
    //     Log.info("Audio pipeline processing completed", category: .app)
    // }

    // MARK: - Search Interface

    /// Search for text across all captured frames
    public func search(query: String, limit: Int = 50) async throws -> SearchResults {
        let searchQuery = SearchQuery(text: query, filters: .none, limit: limit, offset: 0)
        return try await search(query: searchQuery)
    }

    /// Advanced search with filters
    /// Routes to DataAdapter which prioritizes Rewind data source
    public func search(query: SearchQuery) async throws -> SearchResults {
        // Try DataAdapter first (routes to Rewind if available)
        if let adapter = await services.dataAdapter {
            do {
                return try await adapter.search(query: query)
            } catch {
                Log.warning("[AppCoordinator] DataAdapter search failed, falling back to FTS: \(error)", category: .app)
            }
        }

        // Fallback to native FTS search
        return try await services.search.search(query: query)
    }

    // MARK: - Frame Retrieval

    /// Get a specific frame image by timestamp
    /// Uses real timestamps for accurate seeking (works correctly with deduplication)
    /// Automatically routes to appropriate source via DataAdapter
    public func getFrameImage(segmentID: SegmentID, timestamp: Date) async throws -> Data {
        guard let adapter = await services.dataAdapter else {
            // Fallback to storage if adapter not available
            return try await services.storage.readFrame(segmentID: segmentID, timestamp: timestamp)
        }

        return try await adapter.getFrameImage(segmentID: segmentID, timestamp: timestamp)
    }

    /// Get video info for a frame (returns nil if not video-based)
    /// For Rewind frames, returns path/index to display video directly
    public func getFrameVideoInfo(segmentID: SegmentID, timestamp: Date, source: FrameSource) async throws -> FrameVideoInfo? {
        guard let adapter = await services.dataAdapter else {
            return nil
        }

        return try await adapter.getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp, source: source)
    }

    /// Get frames in a time range
    /// Seamlessly blends data from all sources via DataAdapter
    public func getFrames(from startDate: Date, to endDate: Date, limit: Int = 500) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database if adapter not available
            return try await services.database.getFrames(from: startDate, to: endDate, limit: limit)
        }

        return try await adapter.getFrames(from: startDate, to: endDate, limit: limit)
    }

    /// Get frames with video info in a time range (optimized - single query with JOINs)
    /// This is the preferred method for timeline views to avoid N+1 queries
    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int = 500) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getFrames(from: startDate, to: endDate, limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit)
    }

    /// Get the most recent frames across all sources
    /// Returns frames sorted by timestamp descending (newest first)
    public func getMostRecentFrames(limit: Int = 500) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getMostRecentFrames(limit: limit)
        }

        return try await adapter.getMostRecentFrames(limit: limit)
    }

    /// Get the most recent frames with video info (optimized - single query with JOINs)
    public func getMostRecentFramesWithVideoInfo(limit: Int = 500) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getMostRecentFrames(limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getMostRecentFramesWithVideoInfo(limit: limit)
    }

    /// Get frames before a timestamp (for infinite scroll - loading older frames)
    /// Returns frames sorted by timestamp descending (newest first of the older batch)
    public func getFramesBefore(timestamp: Date, limit: Int = 300) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getFramesBefore(timestamp: timestamp, limit: limit)
        }

        return try await adapter.getFramesBefore(timestamp: timestamp, limit: limit)
    }

    /// Get frames with video info before a timestamp (optimized - single query with JOINs)
    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int = 300) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getFramesBefore(timestamp: timestamp, limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit)
    }

    /// Get frames after a timestamp (for infinite scroll - loading newer frames)
    /// Returns frames sorted by timestamp ascending (oldest first of the newer batch)
    public func getFramesAfter(timestamp: Date, limit: Int = 300) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getFramesAfter(timestamp: timestamp, limit: limit)
        }

        return try await adapter.getFramesAfter(timestamp: timestamp, limit: limit)
    }

    /// Get frames with video info after a timestamp (optimized - single query with JOINs)
    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int = 300) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getFramesAfter(timestamp: timestamp, limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
    }

    /// Get frames around a timestamp (before and after, centered on the timestamp)
    /// Useful for navigating to a specific point in time from search results
    public func getFramesAround(timestamp: Date, count: Int = 200) async throws -> [FrameReference] {
        let halfCount = count / 2

        // Get frames before and after the timestamp
        async let framesBefore = getFramesBefore(timestamp: timestamp, limit: halfCount)
        async let framesAfter = getFramesAfter(timestamp: timestamp, limit: halfCount)

        let before = try await framesBefore
        let after = try await framesAfter

        // Combine: older frames first (reversed to chronological), then newer frames
        // before is already in descending order (newest first), so reverse it
        var combined = before.reversed() + after

        // Sort by timestamp to ensure proper order
        combined.sort { $0.timestamp < $1.timestamp }

        return Array(combined)
    }

    /// Get the timestamp of the most recent frame across all sources
    /// Returns nil if no frames exist in any source
    public func getMostRecentFrameTimestamp() async throws -> Date? {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database - get most recent frame
            let frames = try await services.database.getMostRecentFrames(limit: 1)
            return frames.first?.timestamp
        }

        return try await adapter.getMostRecentFrameTimestamp()
    }

    // MARK: - Session Retrieval

    /// Get sessions in a time range
    /// Seamlessly blends data from all sources via DataAdapter
    public func getSessions(from startDate: Date, to endDate: Date) async throws -> [AppSession] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database if adapter not available
            return try await services.database.getSessions(from: startDate, to: endDate)
        }

        return try await adapter.getSessions(from: startDate, to: endDate)
    }

    /// Get the currently active session
    public func getActiveSession() async throws -> AppSession? {
        try await services.database.getActiveSession()
    }

    /// Get sessions for a specific app
    public func getSessions(appBundleID: String, limit: Int = 100) async throws -> [AppSession] {
        try await services.database.getSessions(appBundleID: appBundleID, limit: limit)
    }

    // MARK: - Text Region Retrieval

    /// Get text regions for a frame (OCR bounding boxes)
    public func getTextRegions(frameID: FrameID) async throws -> [TextRegion] {
        try await services.database.getTextRegions(frameID: frameID)
    }

    // MARK: - Frame Deletion

    /// Delete a single frame from the database
    /// Note: For Rewind data, this only removes the database entry. Video files remain on disk.
    public func deleteFrame(frameID: FrameID, timestamp: Date, source: FrameSource) async throws {
        guard let adapter = await services.dataAdapter else {
            // Fallback to direct database deletion for native frames
            if source == .native {
                try await services.database.deleteFrame(id: frameID)
                Log.info("[AppCoordinator] Deleted native frame \(frameID.stringValue)", category: .app)
                return
            }
            throw AppError.notInitialized
        }

        // For Rewind frames, use timestamp-based deletion (more reliable than synthetic UUIDs)
        if source == .rewind {
            try await adapter.deleteFrameByTimestamp(timestamp, source: source)
        } else {
            try await adapter.deleteFrame(frameID: frameID, source: source)
        }

        Log.info("[AppCoordinator] Deleted frame from \(source.displayName)", category: .app)
    }

    /// Delete multiple frames from the database
    /// Groups by source and uses appropriate deletion method for each
    public func deleteFrames(_ frames: [FrameReference]) async throws {
        guard !frames.isEmpty else { return }

        // For Rewind frames, delete by timestamp (more reliable)
        // For native frames, delete by ID
        for frame in frames {
            try await deleteFrame(
                frameID: frame.id,
                timestamp: frame.timestamp,
                source: frame.source
            )
        }

        Log.info("[AppCoordinator] Deleted \(frames.count) frames", category: .app)
    }

    // MARK: - URL Bounding Box Detection

    /// Get the bounding box of a browser URL on screen for a given frame
    /// Returns the bounding box with normalized coordinates (0.0-1.0) if found
    /// Use this to highlight clickable URLs in the timeline view
    public func getURLBoundingBox(timestamp: Date, source: FrameSource) async throws -> RewindDataSource.URLBoundingBox? {
        guard let adapter = await services.dataAdapter else {
            return nil
        }

        return try await adapter.getURLBoundingBox(timestamp: timestamp, source: source)
    }

    // MARK: - OCR Node Detection (for text selection)

    /// Get all OCR nodes for a given frame
    /// Returns array of nodes with normalized bounding boxes (0.0-1.0) and text content
    /// Use this to enable text selection highlighting in the timeline view
    public func getAllOCRNodes(timestamp: Date, source: FrameSource) async throws -> [RewindDataSource.OCRNode] {
        guard let adapter = await services.dataAdapter else {
            return []
        }

        return try await adapter.getAllOCRNodes(timestamp: timestamp, source: source)
    }

    // MARK: - Migration

    /// Import data from Rewind AI
    public func importFromRewind(
        chunkDirectory: String,
        progressHandler: @escaping @Sendable (MigrationProgress) -> Void
    ) async throws {
        Log.info("Starting Rewind import from: \(chunkDirectory)", category: .app)

        // Setup migration manager with default importers (includes RewindImporter)
        await services.migration.setupDefaultImporters()

        // Create delegate to forward progress
        let delegate = MigrationProgressDelegate(progressHandler: progressHandler)

        // Start import
        try await services.migration.startImport(
            source: .rewind,
            delegate: delegate
        )

        Log.info("Rewind import completed", category: .app)
    }

    // MARK: - Statistics & Monitoring

    /// Check if screen capture is currently active
    public func isCapturing() async -> Bool {
        await services.capture.isCapturing
    }

    /// Get comprehensive app statistics
    public func getStatistics() async throws -> AppStatistics {
        let dbStats = try await services.getDatabaseStats()
        let searchStats = await services.getSearchStats()
        let captureStats = await services.getCaptureStats()
        let processingStats = await services.getProcessingStats()

        let uptime: TimeInterval?
        if let startTime = pipelineStartTime {
            uptime = Date().timeIntervalSince(startTime)
        } else {
            uptime = nil
        }

        return AppStatistics(
            isRunning: isRunning,
            uptime: uptime,
            totalFramesProcessed: totalFramesProcessed,
            totalErrors: totalErrors,
            database: dbStats,
            search: searchStats,
            capture: captureStats,
            processing: processingStats
        )
    }

    /// Get current pipeline status
    public func getStatus() -> PipelineStatus {
        PipelineStatus(
            isRunning: isRunning,
            framesProcessed: totalFramesProcessed,
            errors: totalErrors,
            startTime: pipelineStartTime
        )
    }

    // MARK: - Maintenance

    /// Cleanup old data (older than specified date)
    public func cleanupOldData(olderThan date: Date) async throws -> CleanupResult {
        Log.info("Starting cleanup for data older than \(date)", category: .app)

        // Delete old frames from database
        let deletedFrameCount = try await services.database.deleteFrames(olderThan: date)

        // Delete old segments from storage
        let deletedSegmentIDs = try await services.storage.cleanupOldSegments(olderThan: date)

        // Delete corresponding segments from database
        for segmentID in deletedSegmentIDs {
            try await services.database.deleteSegment(id: segmentID)
        }

        // Vacuum database to reclaim space
        try await services.database.vacuum()

        Log.info("Cleanup complete. Deleted \(deletedFrameCount) frames, \(deletedSegmentIDs.count) segments", category: .app)

        return CleanupResult(
            deletedFrames: deletedFrameCount,
            deletedSegments: deletedSegmentIDs.count,
            reclaimedBytes: 0 // TODO: Calculate actual reclaimed space
        )
    }

    /// Rebuild the search index
    public func rebuildSearchIndex() async throws {
        Log.info("Rebuilding search index...", category: .app)
        try await services.search.rebuildIndex()
        Log.info("Search index rebuild complete", category: .app)
    }

    /// Run database maintenance (checkpoint WAL, analyze)
    public func runDatabaseMaintenance() async throws {
        Log.info("Running database maintenance...", category: .app)

        try await services.database.checkpoint()
        try await services.database.analyze()

        Log.info("Database maintenance complete", category: .app)
    }
}

// MARK: - Supporting Types

public struct AppStatistics: Sendable {
    public let isRunning: Bool
    public let uptime: TimeInterval?
    public let totalFramesProcessed: Int
    public let totalErrors: Int
    public let database: DatabaseStatistics
    public let search: SearchStatistics
    public let capture: CaptureStatistics
    public let processing: ProcessingStatistics
}

public struct PipelineStatus: Sendable {
    public let isRunning: Bool
    public let framesProcessed: Int
    public let errors: Int
    public let startTime: Date?
}

public struct CleanupResult: Sendable {
    public let deletedFrames: Int
    public let deletedSegments: Int
    public let reclaimedBytes: Int64
}

public enum AppError: Error {
    case permissionDenied(permission: String)
    case notInitialized
    case alreadyRunning
    case notRunning
}

// MARK: - Migration Delegate

/// Simple delegate wrapper to forward progress updates to a closure
private final class MigrationProgressDelegate: MigrationDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (MigrationProgress) -> Void

    init(progressHandler: @escaping @Sendable (MigrationProgress) -> Void) {
        self.progressHandler = progressHandler
    }

    func migrationDidUpdateProgress(_ progress: MigrationProgress) {
        progressHandler(progress)
    }

    func migrationDidStartProcessingVideo(at path: String, index: Int, total: Int) {
        Log.debug("Started processing video \(index)/\(total): \(path)", category: .app)
    }

    func migrationDidFinishProcessingVideo(at path: String, framesImported: Int) {
        Log.debug("Finished processing video: \(path) (\(framesImported) frames)", category: .app)
    }

    func migrationDidFailProcessingVideo(at path: String, error: Error) {
        Log.error("Failed processing video: \(path) - \(error)", category: .app)
    }

    func migrationDidComplete(result: MigrationResult) {
        Log.info("Migration completed: \(result.framesImported) frames imported", category: .app)
    }

    func migrationDidFail(error: Error) {
        Log.error("Migration failed: \(error)", category: .app)
    }
}
