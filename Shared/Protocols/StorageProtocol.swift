import CoreGraphics
import Foundation

public struct SegmentRedactionTarget: Sendable, Equatable {
    public let frameID: Int64
    public let nodeID: Int
    public let normalizedRect: CGRect

    public init(frameID: Int64, nodeID: Int, normalizedRect: CGRect) {
        self.frameID = frameID
        self.nodeID = nodeID
        self.normalizedRect = normalizedRect
    }
}

public struct SegmentFrameRedaction: Sendable, Equatable {
    public let frameID: Int64
    public let frameIndex: Int
    public let targets: [SegmentRedactionTarget]

    public init(frameID: Int64, frameIndex: Int, targets: [SegmentRedactionTarget]) {
        self.frameID = frameID
        self.frameIndex = frameIndex
        self.targets = targets
    }
}

public enum SegmentRewriteOperation: String, Sendable, Codable, Equatable {
    case partialRewrite
    case wholeVideoDelete
}

public struct SegmentRewritePlan: Sendable, Equatable {
    public let operation: SegmentRewriteOperation
    public let blackFrameIndexes: Set<Int>
    public let redactions: [SegmentFrameRedaction]

    public init(
        operation: SegmentRewriteOperation = .partialRewrite,
        blackFrameIndexes: Set<Int> = [],
        redactions: [SegmentFrameRedaction] = []
    ) {
        self.operation = operation
        self.blackFrameIndexes = blackFrameIndexes
        self.redactions = redactions
    }

    public var hasBlackFrameRewrites: Bool {
        !blackFrameIndexes.isEmpty
    }

    public var hasRedactionTargets: Bool {
        !redactions.isEmpty
    }

    public var redactionFrameIDs: [Int64] {
        redactions.map(\.frameID)
    }

    public func redactionTargets(forFrameIndex frameIndex: Int) -> [SegmentRedactionTarget] {
        Array(
            redactions
                .lazy
                .filter { $0.frameIndex == frameIndex }
                .flatMap(\.targets)
        )
    }

    public var deletesWholeVideo: Bool {
        operation == .wholeVideoDelete
    }

    public var hasAnyRewrite: Bool {
        deletesWholeVideo || hasBlackFrameRewrites || hasRedactionTargets
    }
}

public struct SegmentRewriteRecoveryAction: Sendable, Equatable {
    public enum Mode: String, Sendable {
        case rollbackToPending
        case finalizeCommitted
    }

    public let mode: Mode
    public let operation: SegmentRewriteOperation
    public let segmentID: VideoSegmentID

    public init(
        mode: Mode,
        operation: SegmentRewriteOperation,
        segmentID: VideoSegmentID
    ) {
        self.mode = mode
        self.operation = operation
        self.segmentID = segmentID
    }
}

// MARK: - Storage Protocol

/// File storage and encryption operations
/// Owner: STORAGE agent
public protocol StorageProtocol: Actor {

    // MARK: - Lifecycle

    /// Initialize storage directories
    func initialize(config: StorageConfig) async throws

    // MARK: - Video Segment Operations

    /// Create a new video segment writer
    func createSegmentWriter() async throws -> SegmentWriter

    /// Read a frame from a video segment using frame index
    /// Frame index is the position in the video (0-based), encoded at fixed 30 FPS
    func readFrame(segmentID: VideoSegmentID, frameIndex: Int) async throws -> Data

    /// Get the file path for a segment
    func getSegmentPath(id: VideoSegmentID) async throws -> URL

    /// Delete a video segment file
    func deleteSegment(id: VideoSegmentID) async throws

    /// Check if a segment file exists
    func segmentExists(id: VideoSegmentID) async throws -> Bool

    /// Count the number of readable frames in an existing video file
    /// Returns 0 if the file doesn't exist or is unreadable
    func countFramesInSegment(id: VideoSegmentID) async throws -> Int

    /// Read a frame directly from the WAL when the segment is still being written.
    /// Returns `nil` when the frame is not durable enough to read yet.
    func readFrameFromWAL(
        segmentID: VideoSegmentID,
        frameID: Int64,
        fallbackFrameIndex: Int
    ) async throws -> CapturedFrame?

    /// Apply a generic post-capture rewrite/delete mutation to a finalized segment.
    func applySegmentRewrite(
        segmentID: VideoSegmentID,
        plan: SegmentRewritePlan,
        secret: String?
    ) async throws

    /// Recover interrupted segment mutations discovered on disk.
    func recoverInterruptedSegmentRewrites() async throws -> [SegmentRewriteRecoveryAction]

    /// Remove on-disk recovery artifacts once DB reconciliation succeeds.
    func finishInterruptedSegmentRewriteRecovery(segmentID: VideoSegmentID) async throws

    /// Check if a video file has valid timestamps (first frame dts=0)
    /// Returns false if the video was not properly finalized (crash recovery case)
    func isVideoValid(id: VideoSegmentID) async throws -> Bool

    // MARK: - Storage Management

    /// Get total storage used in bytes
    func getTotalStorageUsed(includeRewind: Bool) async throws -> Int64

    /// Get storage used for a specific date range
    func getStorageUsedForDateRange(from startDate: Date, to endDate: Date) async throws -> Int64

    /// Get available disk space
    func getAvailableDiskSpace() async throws -> Int64

    /// Clean up old segments based on retention policy
    func cleanupOldSegments(olderThan date: Date) async throws -> [VideoSegmentID]

    /// Get storage directory URL
    func getStorageDirectory() -> URL
}

// MARK: - Segment Writer Protocol

/// Writes frames to a video segment file
/// Owner: STORAGE agent
public protocol SegmentWriter: Actor {

    /// The segment ID being written
    var segmentID: VideoSegmentID { get }

    /// Number of frames written so far
    var frameCount: Int { get }

    /// Start time of this segment
    var startTime: Date { get }

    /// Relative path to the video file (from storage root)
    var relativePath: String { get }

    /// Frame width (0 until first frame is appended)
    var frameWidth: Int { get }

    /// Frame height (0 until first frame is appended)
    var frameHeight: Int { get }

    /// Current file size in bytes
    var currentFileSize: Int64 { get }

    /// Returns true if at least one fragment has been written to disk
    /// The fragmented MP4 is only readable after the first fragment is flushed
    var hasFragmentWritten: Bool { get }

    /// Number of frames that have been confirmed flushed to disk
    /// Frames with frameIndex < this value are guaranteed to be readable from the video file
    var framesFlushedToDisk: Int { get }

    /// Append a frame to the segment
    func appendFrame(_ frame: CapturedFrame) async throws

    /// Finalize and close the segment
    /// Returns the completed VideoSegment metadata
    func finalize() async throws -> VideoSegment

    /// Cancel writing and delete partial file
    func cancel() async throws
}

// MARK: - Video Codec Configuration

/// Configuration for video encoding
/// Owner: STORAGE agent
public struct VideoEncoderConfig: Sendable {
    /// Video codec to use
    public let codec: VideoCodec

    /// Target bitrate in bits per second (nil = auto)
    public let targetBitrate: Int?

    /// Keyframe interval in frames
    public let keyframeInterval: Int

    /// Whether to use hardware encoding
    public let useHardwareEncoder: Bool

    /// Quality level (0.0 = max compression/lowest quality, 1.0 = min compression/highest quality)
    public let quality: Float

    public init(
        codec: VideoCodec = .hevc,
        targetBitrate: Int? = nil,
        keyframeInterval: Int = 30,  // Keyframe every 30 frames, enables P/B-frame compression
        useHardwareEncoder: Bool = true,
        quality: Float = 0.5
    ) {
        self.codec = codec
        self.targetBitrate = targetBitrate
        self.keyframeInterval = keyframeInterval
        self.useHardwareEncoder = useHardwareEncoder
        self.quality = quality
    }

    public static var `default`: VideoEncoderConfig {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let quality = defaults.object(forKey: "videoQuality") as? Double ?? 0.5
        return VideoEncoderConfig(quality: Float(quality))
    }
}

public enum VideoCodec: String, Sendable {
    case hevc  // H.265 - better compression
    case h264  // H.264 - wider compatibility
}
