import Foundation

// MARK: - Capture Protocol

/// Screen capture operations
/// Owner: CAPTURE agent
public protocol CaptureProtocol: Actor {

    // MARK: - Lifecycle

    /// Check if screen recording permission is granted
    func hasPermission() async -> Bool

    /// Request screen recording permission
    func requestPermission() async -> Bool

    /// Start capturing frames
    func startCapture(config: CaptureConfig) async throws

    /// Stop capturing frames
    func stopCapture() async throws

    /// Whether capture is currently active
    var isCapturing: Bool { get }

    // MARK: - Frame Stream

    /// Stream of captured frames
    /// Frames are emitted after deduplication (duplicates are filtered)
    var frameStream: AsyncStream<CapturedFrame> { get }

    // MARK: - Configuration

    /// Update capture configuration (can be called while capturing)
    func updateConfig(_ config: CaptureConfig) async throws

    /// Get current configuration
    func getConfig() async -> CaptureConfig

    // MARK: - Display Info

    /// Get available displays
    func getAvailableDisplays() async throws -> [DisplayInfo]

    /// Get the currently focused display
    func getFocusedDisplay() async throws -> DisplayInfo?
}

// MARK: - Deduplication Protocol

/// Frame deduplication logic
/// Owner: CAPTURE agent
public protocol DeduplicationProtocol: Sendable {

    /// Check if a frame is significantly different from the reference
    /// Returns true if frame should be kept, false if it's a duplicate
    func shouldKeepFrame(
        _ frame: CapturedFrame,
        comparedTo reference: CapturedFrame?,
        threshold: Double
    ) -> Bool

    /// Compute a hash for quick comparison
    func computeHash(for frame: CapturedFrame) -> UInt64

    /// Compute similarity score between two frames (0-1)
    func computeSimilarity(
        _ frame1: CapturedFrame,
        _ frame2: CapturedFrame
    ) -> Double
}

// MARK: - Video Encoder Protocol

/// HEVC/H.264 video encoding
/// Owner: CAPTURE agent (encoding logic, uses Storage for writing)
public protocol VideoEncoderProtocol: Actor {

    /// Initialize encoder with configuration
    func initialize(
        width: Int,
        height: Int,
        config: VideoEncoderConfig
    ) async throws

    /// Encode a frame and return compressed data
    func encodeFrame(_ frame: CapturedFrame) async throws -> Data

    /// Flush any remaining frames and finalize
    func finalize() async throws -> Data?

    /// Reset encoder state
    func reset() async throws
}

// MARK: - Supporting Types

/// Information about a display
public struct DisplayInfo: Sendable, Identifiable, Equatable {
    public let id: UInt32  // CGDirectDisplayID
    public let width: Int
    public let height: Int
    public let scaleFactor: Double  // Retina scale
    public let isMain: Bool
    public let name: String?

    public init(
        id: UInt32,
        width: Int,
        height: Int,
        scaleFactor: Double,
        isMain: Bool,
        name: String? = nil
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.isMain = isMain
        self.name = name
    }

    public var nativeWidth: Int { Int(Double(width) * scaleFactor) }
    public var nativeHeight: Int { Int(Double(height) * scaleFactor) }
}

/// Capture statistics
public struct CaptureStatistics: Sendable {
    public let totalFramesCaptured: Int
    public let framesDeduped: Int
    public let averageFrameSizeBytes: Int
    public let captureStartTime: Date?
    public let lastFrameTime: Date?

    public init(
        totalFramesCaptured: Int,
        framesDeduped: Int,
        averageFrameSizeBytes: Int,
        captureStartTime: Date?,
        lastFrameTime: Date?
    ) {
        self.totalFramesCaptured = totalFramesCaptured
        self.framesDeduped = framesDeduped
        self.averageFrameSizeBytes = averageFrameSizeBytes
        self.captureStartTime = captureStartTime
        self.lastFrameTime = lastFrameTime
    }

    public var deduplicationRate: Double {
        guard totalFramesCaptured > 0 else { return 0 }
        return Double(framesDeduped) / Double(totalFramesCaptured + framesDeduped)
    }
}
