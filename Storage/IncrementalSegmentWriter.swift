import CoreMedia
import Foundation
import Shared

/// Segment writer with write-ahead logging
///
/// Features:
/// - Writes raw frames to WAL before encoding (crash-safe)
/// - Encoder writes frames incrementally to video file
/// - WAL enables crash recovery - frames can be re-encoded from WAL on restart
/// - Video file becomes readable only after finalize(), but WAL ensures no data loss
public actor IncrementalSegmentWriter: SegmentWriter {
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
    public private(set) var framesFlushedToDisk: Int = 0

    private let encoder: HEVCEncoder
    private let encoderConfig: VideoEncoderConfig
    private let fileURL: URL
    private let walManager: WALManager

    private var walSession: WALSession?
    private var encoderInitialized = false
    private var cancelled = false
    private var lastFrameTime: Date?

    init(
        segmentID: VideoSegmentID,
        fileURL: URL,
        relativePath: String,
        walManager: WALManager,
        encoderConfig: VideoEncoderConfig = .default
    ) throws {
        self.segmentID = segmentID
        self.startTime = Date()
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.walManager = walManager
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

        Log.verbose("[IncrementalWriter] appendFrame called: segmentID=\(segmentID.value), frameCount=\(frameCount), size=\(frame.width)x\(frame.height)", category: .storage)

        // Track I/O latency for storage health monitoring
        let writeStart = CFAbsoluteTimeGetCurrent()

        // STEP 1: Write to WAL first (crash-safe persistence)
        // This is the critical durability guarantee - frames are safe even if app crashes
        if walSession == nil {
            let session = try await walManager.createSession(videoID: segmentID)
            walSession = session
        }

        var session = walSession!
        try await walManager.appendFrame(frame, to: &session)
        walSession = session

        // Record write latency for health monitoring
        let walLatencyMs = (CFAbsoluteTimeGetCurrent() - writeStart) * 1000
        StorageHealthMonitor.shared.recordWriteLatency(walLatencyMs)

        // STEP 2: Initialize encoder on first frame
        if !encoderInitialized {
            frameWidth = frame.width
            frameHeight = frame.height

            try await encoder.initialize(
                width: frame.width,
                height: frame.height,
                config: encoderConfig,
                outputURL: fileURL,
                segmentStartTime: startTime
            )
            encoderInitialized = true
        }

        // STEP 3: Encode frame to video
        // AVAssetWriter writes data incrementally, but file won't be playable until finalize()
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

        // Update the count of frames confirmed flushed to disk
        framesFlushedToDisk = await encoder.framesFlushedToDisk()
    }

    public func finalize() async throws -> VideoSegment {
        // Final finalization - writes MP4 moov atom to make file seekable/playable
        if encoderInitialized {
            try await encoder.finalize()
        }

        // Clean up WAL - video is now complete and playable
        if let session = walSession {
            try await walManager.finalizeSession(session)
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

        // Clean up WAL
        if let session = walSession {
            try? await walManager.finalizeSession(session)
        }
    }
}
