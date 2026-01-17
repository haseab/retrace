import CoreMedia
import Foundation
import Shared

/// Concrete SegmentWriter that encodes frames to MP4 container using AVAssetWriter.
/// This ensures frames can be read reliably with AVAsset/AVAssetImageGenerator.
public actor SegmentWriterImpl: SegmentWriter {
    public let segmentID: VideoSegmentID
    public private(set) var frameCount: Int = 0
    public let startTime: Date

    private let encoder: HEVCEncoder
    private let encoderConfig: VideoEncoderConfig
    private let fileURL: URL
    private let relativePath: String
    private var encoderInitialized = false
    private var cancelled = false
    private var lastFrameTime: Date?
    private var frameWidth: Int = 0
    private var frameHeight: Int = 0

    init(
        segmentID: VideoSegmentID,
        fileURL: URL,
        relativePath: String,
        encoderConfig: VideoEncoderConfig = .default
    ) throws {
        self.segmentID = segmentID
        self.startTime = Date()
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.encoderConfig = encoderConfig
        self.encoder = HEVCEncoder()

        let parent = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }

    public func appendFrame(_ frame: CapturedFrame) async throws {
        guard !cancelled else {
            throw StorageError.fileWriteFailed(path: fileURL.path, underlying: "Writer cancelled")
        }

        if !encoderInitialized {
            frameWidth = frame.width
            frameHeight = frame.height

            // Write directly to output file (no encryption at file level)
            try await encoder.initialize(
                width: frame.width,
                height: frame.height,
                config: encoderConfig,
                outputURL: fileURL,
                segmentStartTime: startTime
            )
            encoderInitialized = true
        }

        let pixelBuffer = try FrameConverter.createPixelBuffer(from: frame)
        // Encode at fixed 30 FPS regardless of actual capture intervals
        // Frame N is at time N/30.0 seconds (so frame 0 = 0s, frame 1 = 0.033s, etc.)
        // This creates a smooth video that can be seeked frame-by-frame
        let frameTime = Double(frameCount) / 30.0
        let timestamp = CMTime(seconds: frameTime, preferredTimescale: 600)

        try await encoder.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)

        frameCount += 1
        lastFrameTime = frame.timestamp
    }

    public func finalize() async throws -> VideoSegment {
        if encoderInitialized {
            try await encoder.finalize()
            // No encryption - file is written directly without .mp4 extension
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let end = lastFrameTime ?? Date()
        return VideoSegment(
            id: segmentID,
            startTime: startTime,
            endTime: end,
            frameCount: frameCount,
            fileSizeBytes: size,
            relativePath: relativePath,
            width: frameWidth,
            height: frameHeight
        )
    }

    public func cancel() async throws {
        cancelled = true
        await encoder.reset()
        try? FileManager.default.removeItem(at: fileURL)
    }
}

