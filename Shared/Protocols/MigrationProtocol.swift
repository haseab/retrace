import Foundation

// MARK: - Migration Protocol

/// Protocol for importing data from third-party screen recording applications
/// Implementations handle discovering, parsing, and importing frames from external sources
public protocol MigrationProtocol: Actor {

    /// The source type this importer handles
    var source: FrameSource { get }

    /// Check if data from this source is available for import
    /// - Returns: True if importable data was found
    func isDataAvailable() async -> Bool

    /// Scan the source directory and return import statistics
    /// - Returns: Statistics about what can be imported
    func scan() async throws -> MigrationScanResult

    /// Start or resume the import process
    /// - Parameter delegate: Delegate to receive progress updates
    func startImport(delegate: MigrationDelegate?) async throws

    /// Pause the import process (can be resumed later)
    func pauseImport() async

    /// Cancel the import process entirely
    func cancelImport() async

    /// Get the current import state (for resumability)
    func getState() async -> MigrationState

    /// Check if an import is currently in progress
    var isImporting: Bool { get async }

    /// Get current progress information
    var progress: MigrationProgress { get async }
}

// MARK: - Migration Delegate

/// Delegate protocol for receiving migration progress updates
public protocol MigrationDelegate: AnyObject, Sendable {
    /// Called when progress is updated
    func migrationDidUpdateProgress(_ progress: MigrationProgress)

    /// Called when a video file processing begins
    func migrationDidStartProcessingVideo(at path: String, index: Int, total: Int)

    /// Called when a video file processing completes
    func migrationDidFinishProcessingVideo(at path: String, framesImported: Int)

    /// Called when a video file processing fails
    func migrationDidFailProcessingVideo(at path: String, error: Error)

    /// Called when the entire migration completes
    func migrationDidComplete(result: MigrationResult)

    /// Called when migration encounters a fatal error
    func migrationDidFail(error: Error)
}

// MARK: - Migration Scan Result

/// Result of scanning a third-party data source
public struct MigrationScanResult: Codable, Sendable {
    /// Source being scanned
    public let source: FrameSource

    /// Total number of video files found
    public let totalVideoFiles: Int

    /// Total size of all video files in bytes
    public let totalSizeBytes: Int64

    /// Estimated number of frames to import
    public let estimatedFrameCount: Int

    /// Date range of the data
    public let dateRange: ClosedRange<Date>?

    /// Number of files already imported (for resumability)
    public let alreadyImportedCount: Int

    /// Number of files remaining to import
    public var remainingCount: Int {
        totalVideoFiles - alreadyImportedCount
    }

    public init(
        source: FrameSource,
        totalVideoFiles: Int,
        totalSizeBytes: Int64,
        estimatedFrameCount: Int,
        dateRange: ClosedRange<Date>?,
        alreadyImportedCount: Int
    ) {
        self.source = source
        self.totalVideoFiles = totalVideoFiles
        self.totalSizeBytes = totalSizeBytes
        self.estimatedFrameCount = estimatedFrameCount
        self.dateRange = dateRange
        self.alreadyImportedCount = alreadyImportedCount
    }
}

// MARK: - Migration Progress

/// Progress information for an ongoing migration
public struct MigrationProgress: Codable, Sendable {
    /// Current state of the migration
    public let state: MigrationProgressState

    /// Source being imported
    public let source: FrameSource

    /// Total number of video files to process
    public let totalVideos: Int

    /// Number of videos processed so far
    public let videosProcessed: Int

    /// Total estimated frames to import
    public let totalFrames: Int

    /// Number of frames imported so far
    public let framesImported: Int

    /// Number of frames deduplicated (skipped)
    public let framesDeduplicated: Int

    /// Current video file being processed
    public let currentVideoPath: String?

    /// Bytes processed so far
    public let bytesProcessed: Int64

    /// Total bytes to process
    public let totalBytes: Int64

    /// Start time of the import
    public let startTime: Date?

    /// Estimated time remaining in seconds
    public let estimatedSecondsRemaining: TimeInterval?

    /// Percentage complete (0.0 - 1.0)
    public var percentComplete: Double {
        guard totalVideos > 0 else { return 0 }
        return Double(videosProcessed) / Double(totalVideos)
    }

    /// Frames per second processing rate
    public var framesPerSecond: Double? {
        guard let start = startTime else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        return Double(framesImported) / elapsed
    }

    public init(
        state: MigrationProgressState,
        source: FrameSource,
        totalVideos: Int,
        videosProcessed: Int,
        totalFrames: Int,
        framesImported: Int,
        framesDeduplicated: Int,
        currentVideoPath: String?,
        bytesProcessed: Int64,
        totalBytes: Int64,
        startTime: Date?,
        estimatedSecondsRemaining: TimeInterval?
    ) {
        self.state = state
        self.source = source
        self.totalVideos = totalVideos
        self.videosProcessed = videosProcessed
        self.totalFrames = totalFrames
        self.framesImported = framesImported
        self.framesDeduplicated = framesDeduplicated
        self.currentVideoPath = currentVideoPath
        self.bytesProcessed = bytesProcessed
        self.totalBytes = totalBytes
        self.startTime = startTime
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
    }

    /// Create an initial/empty progress
    public static func initial(source: FrameSource) -> MigrationProgress {
        MigrationProgress(
            state: .idle,
            source: source,
            totalVideos: 0,
            videosProcessed: 0,
            totalFrames: 0,
            framesImported: 0,
            framesDeduplicated: 0,
            currentVideoPath: nil,
            bytesProcessed: 0,
            totalBytes: 0,
            startTime: nil,
            estimatedSecondsRemaining: nil
        )
    }
}

// MARK: - Migration Progress State

/// Current state of a migration operation
public enum MigrationProgressState: String, Codable, Sendable {
    /// Not started or idle
    case idle

    /// Scanning source directory
    case scanning

    /// Import in progress
    case importing

    /// Import paused (can be resumed)
    case paused

    /// Import completed successfully
    case completed

    /// Import failed
    case failed

    /// Import was cancelled
    case cancelled
}

// MARK: - Migration State (Persistence)

/// Persistent state for resumable migrations
public struct MigrationState: Codable, Sendable {
    /// Unique ID for this migration session
    public let sessionID: UUID

    /// Source being imported
    public let source: FrameSource

    /// When the migration started
    public let startedAt: Date

    /// When the migration was last updated
    public var lastUpdatedAt: Date

    /// Current progress state
    public var progressState: MigrationProgressState

    /// Set of video file paths that have been fully processed
    public var processedVideoPaths: Set<String>

    /// The last video path that was being processed (for resume)
    public var lastVideoPath: String?

    /// The last frame index within that video (for resume)
    public var lastFrameIndex: Int?

    /// Total frames imported in this session
    public var totalFramesImported: Int

    /// Total frames deduplicated in this session
    public var totalFramesDeduplicated: Int

    /// Any error message if failed
    public var errorMessage: String?

    public init(
        sessionID: UUID = UUID(),
        source: FrameSource,
        startedAt: Date = Date(),
        lastUpdatedAt: Date = Date(),
        progressState: MigrationProgressState = .idle,
        processedVideoPaths: Set<String> = [],
        lastVideoPath: String? = nil,
        lastFrameIndex: Int? = nil,
        totalFramesImported: Int = 0,
        totalFramesDeduplicated: Int = 0,
        errorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.source = source
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.progressState = progressState
        self.processedVideoPaths = processedVideoPaths
        self.lastVideoPath = lastVideoPath
        self.lastFrameIndex = lastFrameIndex
        self.totalFramesImported = totalFramesImported
        self.totalFramesDeduplicated = totalFramesDeduplicated
        self.errorMessage = errorMessage
    }

    /// Mark a video as fully processed
    public mutating func markVideoProcessed(_ path: String) {
        processedVideoPaths.insert(path)
        lastVideoPath = nil
        lastFrameIndex = nil
        lastUpdatedAt = Date()
    }

    /// Update checkpoint within a video
    public mutating func updateCheckpoint(videoPath: String, frameIndex: Int) {
        lastVideoPath = videoPath
        lastFrameIndex = frameIndex
        lastUpdatedAt = Date()
    }
}

// MARK: - Migration Result

/// Final result of a migration operation
public struct MigrationResult: Codable, Sendable {
    /// Source that was imported
    public let source: FrameSource

    /// Whether the migration completed successfully
    public let success: Bool

    /// Total videos processed
    public let videosProcessed: Int

    /// Total frames imported
    public let framesImported: Int

    /// Total frames deduplicated (skipped)
    public let framesDeduplicated: Int

    /// Total time taken
    public let durationSeconds: TimeInterval

    /// Any error message if failed
    public let errorMessage: String?

    /// Date range of imported data
    public let dateRange: ClosedRange<Date>?

    public init(
        source: FrameSource,
        success: Bool,
        videosProcessed: Int,
        framesImported: Int,
        framesDeduplicated: Int,
        durationSeconds: TimeInterval,
        errorMessage: String?,
        dateRange: ClosedRange<Date>?
    ) {
        self.source = source
        self.success = success
        self.videosProcessed = videosProcessed
        self.framesImported = framesImported
        self.framesDeduplicated = framesDeduplicated
        self.durationSeconds = durationSeconds
        self.errorMessage = errorMessage
        self.dateRange = dateRange
    }
}

// MARK: - Migration Error

/// Errors that can occur during migration
public enum MigrationError: Error, Sendable {
    /// Source data directory not found
    case sourceNotFound(path: String)

    /// No videos found to import
    case noVideosFound

    /// Failed to read video file
    case videoReadError(path: String, underlying: String)

    /// Failed to extract frames from video
    case frameExtractionError(path: String, underlying: String)

    /// Failed to run OCR on frame
    case ocrError(frameIndex: Int, underlying: String)

    /// Database error during import
    case databaseError(underlying: String)

    /// Migration was cancelled
    case cancelled

    /// Migration state file corrupted
    case stateCorrupted

    /// Unknown error
    case unknown(String)
}

extension MigrationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let path):
            return "Source data not found at: \(path)"
        case .noVideosFound:
            return "No video files found to import"
        case .videoReadError(let path, let underlying):
            return "Failed to read video at \(path): \(underlying)"
        case .frameExtractionError(let path, let underlying):
            return "Failed to extract frames from \(path): \(underlying)"
        case .ocrError(let frameIndex, let underlying):
            return "OCR failed for frame \(frameIndex): \(underlying)"
        case .databaseError(let underlying):
            return "Database error: \(underlying)"
        case .cancelled:
            return "Migration was cancelled"
        case .stateCorrupted:
            return "Migration state file is corrupted"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}
