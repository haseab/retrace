import Foundation

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

    // MARK: - Storage Management

    /// Get total storage used in bytes
    func getTotalStorageUsed() async throws -> Int64

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

    public init(
        codec: VideoCodec = .hevc,
        targetBitrate: Int? = nil,
        keyframeInterval: Int = 1,  // Every frame is keyframe at 0.5fps
        useHardwareEncoder: Bool = true
    ) {
        self.codec = codec
        self.targetBitrate = targetBitrate
        self.keyframeInterval = keyframeInterval
        self.useHardwareEncoder = useHardwareEncoder
    }

    public static let `default` = VideoEncoderConfig()
}

public enum VideoCodec: String, Sendable {
    case hevc  // H.265 - better compression
    case h264  // H.264 - wider compatibility
}
