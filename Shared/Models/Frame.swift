import Foundation
import CoreMedia

// MARK: - Frame Identifiers

/// Unique identifier for a captured frame
/// Uses Int64 to match Rewind's INTEGER PRIMARY KEY AUTOINCREMENT schema
public struct FrameID: Hashable, Codable, Sendable, Identifiable {
    public let value: Int64

    /// Identifiable conformance
    public var id: Int64 { value }

    public init(value: Int64) {
        self.value = value
    }

    public init?(string: String) {
        guard let int64 = Int64(string) else { return nil }
        self.value = int64
    }

    public var stringValue: String { String(value) }
}

// MARK: - Frame Metadata

/// Metadata associated with a captured frame
public struct FrameMetadata: Codable, Sendable, Equatable {
    /// Bundle identifier of the active application
    public let appBundleID: String?

    /// Display name of the active application
    public let appName: String?

    /// Title of the active window
    public let windowName: String?

    /// URL if the active app is a browser
    public let browserURL: String?

    /// Display ID that was captured
    public let displayID: UInt32

    /// Whether this frame was captured from the focused (active) display
    /// true = user was looking at this display, false = secondary display
    public let isFocused: Bool

    public init(
        appBundleID: String? = nil,
        appName: String? = nil,
        windowName: String? = nil,
        browserURL: String? = nil,
        displayID: UInt32 = 0,
        isFocused: Bool = true
    ) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowName = windowName
        self.browserURL = browserURL
        self.displayID = displayID
        self.isFocused = isFocused
    }

    public static let empty = FrameMetadata()
}

// MARK: - Captured Frame

/// A captured frame with raw image data - used during capture pipeline
/// Note: ID is assigned by database on insert (AUTOINCREMENT)
public struct CapturedFrame: Sendable {
    public let timestamp: Date
    public let imageData: Data  // Raw pixel data or compressed image
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let metadata: FrameMetadata

    public init(
        timestamp: Date = Date(),
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        metadata: FrameMetadata = .empty
    ) {
        self.timestamp = timestamp
        self.imageData = imageData
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.metadata = metadata
    }
}

// MARK: - App Segment (Session)

/// Identifier for an app segment (session) - references segment.id in database
/// Represents a continuous recording session within a single app
public struct AppSegmentID: Hashable, Codable, Sendable {
    public let value: Int64

    public init(value: Int64) {
        self.value = value
    }

    public init?(string: String) {
        guard let int64 = Int64(string) else { return nil }
        self.value = int64
    }

    public var stringValue: String { String(value) }
}

// MARK: - Frame Reference

/// Lightweight reference to a stored frame - used for queries and listings
/// Rewind-compatible: links to both app segment (session) and video chunk
public struct FrameReference: Codable, Sendable, Equatable, Identifiable {
    public let id: FrameID
    public let timestamp: Date

    /// App segment (session) this frame belongs to - references segment.id
    /// Contains app bundleID, windowName, browserUrl
    public let segmentID: AppSegmentID

    /// Video chunk this frame is encoded in - references video.id
    /// May be nil/0 if frame hasn't been encoded to video yet
    public let videoID: VideoSegmentID

    /// Position of this frame within the video (0-149 for 150-frame chunks)
    public let frameIndexInSegment: Int

    public let encodingStatus: EncodingStatus
    public let metadata: FrameMetadata
    public let source: FrameSource

    public init(
        id: FrameID,
        timestamp: Date,
        segmentID: AppSegmentID,
        videoID: VideoSegmentID = VideoSegmentID(value: 0),
        frameIndexInSegment: Int,
        encodingStatus: EncodingStatus = .success,
        metadata: FrameMetadata,
        source: FrameSource = .native
    ) {
        self.id = id
        self.timestamp = timestamp
        self.segmentID = segmentID
        self.videoID = videoID
        self.frameIndexInSegment = frameIndexInSegment
        self.encodingStatus = encodingStatus
        self.metadata = metadata
        self.source = source
    }

    /// Whether this frame has been encoded to a video chunk
    public var isEncodedToVideo: Bool {
        videoID.value > 0
    }
}

// MARK: - Video Segment

/// Identifier for a video segment file (video chunks)
/// Uses Int64 to match Rewind's INTEGER PRIMARY KEY AUTOINCREMENT schema for video.id
public struct VideoSegmentID: Hashable, Codable, Sendable {
    public let value: Int64

    public init(value: Int64) {
        self.value = value
    }

    public init?(string: String) {
        guard let int64 = Int64(string) else { return nil }
        self.value = int64
    }

    public var stringValue: String { String(value) }
}

/// Metadata about a video segment file (150-frame video chunks)
public struct VideoSegment: Codable, Sendable, Equatable {
    public let id: VideoSegmentID
    public let startTime: Date
    public let endTime: Date
    public let frameCount: Int
    public let fileSizeBytes: Int64
    public let relativePath: String  // Relative to storage root
    public let width: Int
    public let height: Int
    public let source: FrameSource

    public init(
        id: VideoSegmentID,
        startTime: Date,
        endTime: Date,
        frameCount: Int,
        fileSizeBytes: Int64,
        relativePath: String,
        width: Int,
        height: Int,
        source: FrameSource = .native
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.frameCount = frameCount
        self.fileSizeBytes = fileSizeBytes
        self.relativePath = relativePath
        self.width = width
        self.height = height
        self.source = source
    }

    public var durationSeconds: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

// MARK: - URL Bounding Box

/// Bounding box for a URL detected in OCR text
/// Used to highlight the browser URL bar in screenshots
public struct URLBoundingBox: Sendable, Equatable {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat
    public let url: String

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, url: String) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.url = url
    }
}

// MARK: - Frame Video Info

/// Video playback information for displaying a frame from a video source
public struct FrameVideoInfo: Sendable, Equatable, Codable {
    /// Full path to the video file
    public let videoPath: String

    /// Frame index within the video (0-based)
    public let frameIndex: Int

    /// Video frame rate (frames per second)
    public let frameRate: Double

    /// Video width in pixels (optional - for aspect ratio calculation)
    public let width: Int?

    /// Video height in pixels (optional - for aspect ratio calculation)
    public let height: Int?

    /// Whether the video file has been finalized (processingState = 0)
    /// If true, the video is complete and can be read regardless of file size
    public let isVideoFinalized: Bool

    /// Calculated time in seconds for this frame
    /// WARNING: This uses floating point which can cause precision issues at certain frame indices
    /// For precise seeking, use frameTimeCMTime instead
    public var timeInSeconds: Double {
        Double(frameIndex) / (frameRate > 0 ? frameRate : 30.0)
    }

    /// Returns CMTime with integer arithmetic to avoid floating point precision issues
    /// At 30fps with timescale 600: each frame = 20 time units (600/30 = 20)
    /// This ensures exact timestamps: frame 0 = 0, frame 11 = 220, frame 22 = 440, etc.
    public var frameTimeCMTime: CMTime {
        // For 30fps with timescale 600: frameIndex * 20 = exact time units
        // For other frame rates, calculate the appropriate multiplier
        let effectiveFrameRate = frameRate > 0 ? frameRate : 30.0
        if effectiveFrameRate == 30.0 {
            // Fast path for 30fps - use exact integer arithmetic
            return CMTime(value: Int64(frameIndex) * 20, timescale: 600)
        } else {
            // For other frame rates, use floating point (less common case)
            return CMTime(seconds: Double(frameIndex) / effectiveFrameRate, preferredTimescale: 600)
        }
    }

    public init(videoPath: String, frameIndex: Int, frameRate: Double, width: Int? = nil, height: Int? = nil, isVideoFinalized: Bool = true) {
        self.videoPath = videoPath
        self.frameIndex = frameIndex
        self.frameRate = frameRate
        self.width = width
        self.height = height
        self.isVideoFinalized = isVideoFinalized
    }
}

// MARK: - Frame With Video Info

/// A frame reference combined with its video info (if applicable)
/// Used to return all frame data in a single query with JOINs instead of N+1 queries
public struct FrameWithVideoInfo: Sendable, Equatable, Codable {
    /// The frame reference with metadata
    public let frame: FrameReference

    /// Video playback info (nil for image-based sources like native Retrace)
    public let videoInfo: FrameVideoInfo?

    /// Processing status: 0=pending, 1=processing, 2=completed, 3=failed, 4=not yet readable
    public let processingStatus: Int

    public init(frame: FrameReference, videoInfo: FrameVideoInfo?, processingStatus: Int = 0) {
        self.frame = frame
        self.videoInfo = videoInfo
        self.processingStatus = processingStatus
    }
}

// MARK: - Unfinalised Video

/// Represents a video that is still being written to (< 150 frames)
/// Used for the Rewind-style multi-resolution video writing pattern
/// where different resolutions go to different video files
public struct UnfinalisedVideo: Sendable, Equatable {
    /// Database ID of the video record
    public let id: Int64

    /// Relative path to the video file
    public let relativePath: String

    /// Number of frames already written to this video
    public let frameCount: Int

    /// Video width in pixels
    public let width: Int

    /// Video height in pixels
    public let height: Int

    /// Display ID that produced this video (for multi-display support)
    public let displayID: UInt32

    /// Writer key combining displayID and resolution for unique video writer lookup
    public var writerKey: String {
        "\(displayID)_\(width)x\(height)"
    }

    /// Legacy resolution-only key (for backward compatibility)
    public var resolutionKey: String {
        "\(width)x\(height)"
    }

    public init(id: Int64, relativePath: String, frameCount: Int, width: Int, height: Int, displayID: UInt32 = 0) {
        self.id = id
        self.relativePath = relativePath
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.displayID = displayID
    }
}

