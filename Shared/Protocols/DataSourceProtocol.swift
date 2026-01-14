import Foundation

// MARK: - Frame Video Info

/// Video playback information for displaying a frame from a video source
public struct FrameVideoInfo: Sendable, Equatable {
    /// Full path to the video file
    public let videoPath: String

    /// Frame index within the video (0-based)
    public let frameIndex: Int

    /// Video frame rate (frames per second)
    public let frameRate: Double

    /// Calculated time in seconds for this frame
    public var timeInSeconds: Double {
        Double(frameIndex) / (frameRate > 0 ? frameRate : 30.0)
    }

    public init(videoPath: String, frameIndex: Int, frameRate: Double) {
        self.videoPath = videoPath
        self.frameIndex = frameIndex
        self.frameRate = frameRate
    }
}

// MARK: - Data Source Protocol

/// Protocol for fetching historical frame data from any source
/// Implementations handle source-specific storage formats and encryption
/// Used by DataAdapter to route queries to the appropriate source
public protocol DataSourceProtocol: Actor {
    /// The source type this adapter handles
    var source: FrameSource { get }

    /// Whether this source is currently connected and available
    var isConnected: Bool { get }

    /// Connect to the data source
    func connect() async throws

    /// Disconnect from the data source
    func disconnect() async

    /// Get frames within a time range
    /// - Parameters:
    ///   - startDate: Start of the time range
    ///   - endDate: End of the time range
    ///   - limit: Maximum number of frames to return
    /// - Returns: Array of frame references sorted by timestamp descending
    func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference]

    /// Get the most recent frames from this source
    /// - Parameter limit: Maximum number of frames to return
    /// - Returns: Array of frame references sorted by timestamp descending (newest first)
    func getMostRecentFrames(limit: Int) async throws -> [FrameReference]

    /// Get frames before a timestamp (for infinite scroll - loading older frames)
    /// - Parameters:
    ///   - timestamp: Get frames before this timestamp
    ///   - limit: Maximum number of frames to return
    /// - Returns: Array of frame references sorted by timestamp descending (newest first of the older batch)
    func getFramesBefore(timestamp: Date, limit: Int) async throws -> [FrameReference]

    /// Get frames after a timestamp (for infinite scroll - loading newer frames)
    /// - Parameters:
    ///   - timestamp: Get frames after this timestamp
    ///   - limit: Maximum number of frames to return
    /// - Returns: Array of frame references sorted by timestamp ascending (oldest first of the newer batch)
    func getFramesAfter(timestamp: Date, limit: Int) async throws -> [FrameReference]

    /// Get image data for a specific frame
    /// - Parameters:
    ///   - segmentID: The segment containing the frame
    ///   - timestamp: The frame's timestamp
    /// - Returns: JPEG image data
    func getFrameImage(segmentID: SegmentID, timestamp: Date) async throws -> Data

    /// Get video source info for a specific frame (for video-based sources like Rewind)
    /// - Parameters:
    ///   - segmentID: The segment containing the frame
    ///   - timestamp: The frame's timestamp
    /// - Returns: Video playback info, or nil if this source doesn't use video
    func getFrameVideoInfo(segmentID: SegmentID, timestamp: Date) async throws -> FrameVideoInfo?

    /// The cutoff date for this source (data is only available before this date)
    /// Returns nil if the source has no cutoff (e.g., native Retrace data)
    var cutoffDate: Date? { get }
}

// MARK: - Data Source Error

public enum DataSourceError: Error, LocalizedError {
    case notConnected
    case connectionFailed(underlying: String)
    case queryFailed(underlying: String)
    case frameNotFound
    case imageNotFound
    case unsupportedOperation

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Data source not connected"
        case .connectionFailed(let error):
            return "Failed to connect to data source: \(error)"
        case .queryFailed(let error):
            return "Query failed: \(error)"
        case .frameNotFound:
            return "Frame not found"
        case .imageNotFound:
            return "Frame image not found"
        case .unsupportedOperation:
            return "Operation not supported by this data source"
        }
    }
}
