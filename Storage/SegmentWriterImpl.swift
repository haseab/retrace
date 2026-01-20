import CoreMedia
import Foundation
import Shared

/// Concrete SegmentWriter that encodes frames to MP4 container using AVAssetWriter.
/// This ensures frames can be read reliably with AVAsset/AVAssetImageGenerator.
public actor SegmentWriterImpl: SegmentWriter {
    public let segmentID: VideoSegmentID
    public private(set) var frameCount: Int = 0
    public let startTime: Date
    public let relativePath: String
    public private(set) var frameWidth: Int = 0
    public private(set) var frameHeight: Int = 0

    public var currentFileSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
    }

    public private(set) var hasFragmentWritten: Bool = false

    private let encoder: HEVCEncoder
    private let encoderConfig: VideoEncoderConfig
    private let fileURL: URL
    private var encoderInitialized = false
    private var cancelled = false
    private var lastFrameTime: Date?

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
        // Use integer arithmetic to avoid floating point precision issues
        // At 30fps with timescale 600: each frame = 20 time units (600/30 = 20)
        // This ensures exact timestamps: frame 0 = 0, frame 1 = 20, frame 11 = 220, etc.
        let timestamp = CMTime(value: Int64(frameCount) * 20, timescale: 600)

        try await encoder.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)

        frameCount += 1
        lastFrameTime = frame.timestamp

        // Check if first fragment has been written (makes video readable)
        if !hasFragmentWritten {
            hasFragmentWritten = await encoder.hasFragmentWritten()
        }
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

