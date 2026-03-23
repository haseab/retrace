import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox
import Shared

enum StorageVideoEncodingMemoryLedger {
    private struct SessionSummary: Sendable {
        let sessionBytes: Int64
        let videoToolboxHeapBytes: Int64
        let pixelBufferPoolBytes: Int64
    }

    private static let tracker = Tracker()
    private static let summaryIntervalSeconds: TimeInterval = 30
    private static let sessionTag = "storage.videoEncoding.encoderSessions"
    private static let videoToolboxHeapTag = "storage.videoEncoding.videoToolboxHeap"
    private static let pixelBufferPoolTag = "storage.videoEncoding.pixelBufferPool"
    private static let pixelBufferTag = "storage.videoEncoding.inFlightPixelBuffers"

    static func registerSession(
        identifier: String,
        width: Int,
        height: Int,
        usesHardwareAcceleration: Bool
    ) async {
        guard !identifier.isEmpty else { return }
        await tracker.setSession(
            identifier: identifier,
            summary: SessionSummary(
                sessionBytes: estimatedSessionBytes(
                    width: width,
                    height: height,
                    usesHardwareAcceleration: usesHardwareAcceleration
                ),
                videoToolboxHeapBytes: estimatedVideoToolboxHeapBytes(
                    width: width,
                    height: height,
                    usesHardwareAcceleration: usesHardwareAcceleration
                ),
                pixelBufferPoolBytes: estimatedPixelBufferPoolBytes(
                    width: width,
                    height: height
                )
            )
        )
    }

    static func removeSession(identifier: String) async {
        guard !identifier.isEmpty else { return }
        await tracker.removeSession(identifier: identifier)
    }

    static func beginPixelBuffer(width: Int, height: Int) async -> UUID? {
        let estimatedBytes = estimatedPixelBytes(width: width, height: height)
        guard estimatedBytes > 0 else { return nil }

        let token = UUID()
        await tracker.addPixelBuffer(token: token, bytes: estimatedBytes)
        return token
    }

    static func endPixelBuffer(_ token: UUID?) async {
        guard let token else { return }
        await tracker.removePixelBuffer(token: token)
    }

    private static func estimatedSessionBytes(
        width: Int,
        height: Int,
        usesHardwareAcceleration: Bool
    ) -> Int64 {
        let frameBytes = estimatedPixelBytes(width: width, height: height)
        guard frameBytes > 0 else { return 0 }

        let multiplier: Int64 = usesHardwareAcceleration ? 3 : 4
        let baselineOverhead: Int64 = usesHardwareAcceleration ? 8 * 1_024 * 1_024 : 12 * 1_024 * 1_024
        let minimumBytes: Int64 = usesHardwareAcceleration ? 12 * 1_024 * 1_024 : 16 * 1_024 * 1_024
        let estimatedBytes = frameBytes * multiplier + baselineOverhead
        return max(estimatedBytes, minimumBytes)
    }

    private static func estimatedPixelBytes(width: Int, height: Int) -> Int64 {
        guard width > 0, height > 0 else { return 0 }
        let rowBytes = Int64(width) * 4
        let totalBytes = rowBytes * Int64(height)
        return max(0, totalBytes)
    }

    private static func estimatedVideoToolboxHeapBytes(
        width: Int,
        height: Int,
        usesHardwareAcceleration: Bool
    ) -> Int64 {
        let frameBytes = estimatedPixelBytes(width: width, height: height)
        guard frameBytes > 0 else { return 0 }

        let multiplier: Int64 = usesHardwareAcceleration ? 3 : 2
        let baselineBytes: Int64 = usesHardwareAcceleration ? 24 * 1_024 * 1_024 : 16 * 1_024 * 1_024
        let minimumBytes: Int64 = usesHardwareAcceleration ? 64 * 1_024 * 1_024 : 48 * 1_024 * 1_024
        return max(frameBytes * multiplier + baselineBytes, minimumBytes)
    }

    private static func estimatedPixelBufferPoolBytes(width: Int, height: Int) -> Int64 {
        let frameBytes = estimatedPixelBytes(width: width, height: height)
        guard frameBytes > 0 else { return 0 }
        return max(frameBytes * 2, 24 * 1_024 * 1_024)
    }

    private actor Tracker {
        private var sessionBytesByIdentifier: [String: SessionSummary] = [:]
        private var pixelBufferBytesByToken: [UUID: Int64] = [:]

        func setSession(identifier: String, summary: SessionSummary) {
            sessionBytesByIdentifier[identifier] = SessionSummary(
                sessionBytes: max(0, summary.sessionBytes),
                videoToolboxHeapBytes: max(0, summary.videoToolboxHeapBytes),
                pixelBufferPoolBytes: max(0, summary.pixelBufferPoolBytes)
            )
            updateSessionLedger(reason: "storage.video_encoding.session")
        }

        func removeSession(identifier: String) {
            sessionBytesByIdentifier.removeValue(forKey: identifier)
            updateSessionLedger(reason: "storage.video_encoding.session")
        }

        func addPixelBuffer(token: UUID, bytes: Int64) {
            pixelBufferBytesByToken[token] = max(0, bytes)
            updatePixelBufferLedger()
        }

        func removePixelBuffer(token: UUID) {
            pixelBufferBytesByToken.removeValue(forKey: token)
            updatePixelBufferLedger()
        }

        private func updateSessionLedger(reason: String) {
            let sessionCount = sessionBytesByIdentifier.count
            let totalSessionBytes = sessionBytesByIdentifier.values.reduce(into: Int64(0)) { partialResult, summary in
                partialResult += summary.sessionBytes
            }
            let totalVideoToolboxHeapBytes = sessionBytesByIdentifier.values.reduce(into: Int64(0)) { partialResult, summary in
                partialResult += summary.videoToolboxHeapBytes
            }
            let totalPixelBufferPoolBytes = sessionBytesByIdentifier.values.reduce(into: Int64(0)) { partialResult, summary in
                partialResult += summary.pixelBufferPoolBytes
            }

            MemoryLedger.set(
                tag: StorageVideoEncodingMemoryLedger.sessionTag,
                bytes: totalSessionBytes,
                count: sessionCount,
                unit: "sessions",
                function: "storage.video_encoding",
                kind: "encoder-session",
                note: "estimated-native"
            )
            MemoryLedger.set(
                tag: StorageVideoEncodingMemoryLedger.videoToolboxHeapTag,
                bytes: totalVideoToolboxHeapBytes,
                count: sessionCount,
                unit: "sessions",
                function: "storage.video_encoding",
                kind: "videotoolbox-private-heap",
                note: "proxy-native"
            )
            MemoryLedger.set(
                tag: StorageVideoEncodingMemoryLedger.pixelBufferPoolTag,
                bytes: totalPixelBufferPoolBytes,
                count: sessionCount,
                unit: "sessions",
                function: "storage.video_encoding",
                kind: "pixel-buffer-pool",
                note: "proxy-native"
            )
            MemoryLedger.emitSummary(
                reason: reason,
                category: .storage,
                minIntervalSeconds: StorageVideoEncodingMemoryLedger.summaryIntervalSeconds
            )
        }

        private func updatePixelBufferLedger() {
            let totalBytes = pixelBufferBytesByToken.values.reduce(into: Int64(0)) { partialResult, bytes in
                partialResult += bytes
            }

            MemoryLedger.set(
                tag: StorageVideoEncodingMemoryLedger.pixelBufferTag,
                bytes: totalBytes,
                count: pixelBufferBytesByToken.count,
                unit: "buffers",
                function: "storage.video_encoding",
                kind: "pixel-buffer",
                note: "estimated"
            )
        }
    }
}

/// Hardware-accelerated HEVC encoder using AVAssetWriter for proper MP4/MOV container format.
/// This ensures frames can be seeked and read reliably with AVAssetImageGenerator.
///
/// Hardware acceleration is verified at initialization and logged for monitoring.
public actor HEVCEncoder {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isFinalized = false
    private var outputURL: URL?
    private var segmentStartTime: Date?
    private var isUsingHardwareAcceleration = false

    // Store initialization parameters for potential re-initialization if file is deleted
    private var initWidth: Int = 0
    private var initHeight: Int = 0
    private var initConfig: VideoEncoderConfig?

    // Fragment tracking for logging
    private var lastLoggedFileSize: Int64 = 0
    private var frameCount: Int = 0
    private var fragmentCount: Int = 0

    // Track how many frames have been confirmed flushed to disk
    // This is updated when a fragment write is detected (file size increase > 1KB)
    private var flushedFrameCount: Int = 0
    private var lastDurableFileSizeBytes: Int64 = 0

    public init() {}

    /// Check if hardware encoding is available for the given codec
    private static func isHardwareEncodingAvailable(for codecType: CMVideoCodecType) -> Bool {
        // Query VideoToolbox for hardware encoder support
        var encoderListOut: CFArray?
        let status = VTCopyVideoEncoderList(nil, &encoderListOut)

        guard status == noErr, let encoderList = encoderListOut as? [[String: Any]] else {
            return false
        }

        // Look for hardware encoder matching our codec
        for encoder in encoderList {
            if let encoderID = encoder[kVTVideoEncoderList_CodecType as String] as? UInt32,
               let isHardwareAccelerated = encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool,
               encoderID == codecType,
               isHardwareAccelerated {
                return true
            }
        }

        return false
    }

    public func initialize(width: Int, height: Int, config: VideoEncoderConfig, outputURL: URL, segmentStartTime: Date) async throws {
        guard assetWriter == nil else { return }

        self.outputURL = outputURL
        self.segmentStartTime = segmentStartTime
        self.initWidth = width
        self.initHeight = height
        self.initConfig = config

        // Remove any existing file (should only happen if re-using a path, which shouldn't occur)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            Log.warning("🗑️ [HEVCEncoder.initialize] Removing existing file at: \(outputURL.path)", category: .storage)
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {
                Log.warning("[HEVCEncoder] Could not remove existing file: \(outputURL.lastPathComponent) | Error: \(error.localizedDescription)", category: .storage)
                // Continue - we'll try to overwrite
            }
        }

        // Configure video codec
        let codecType: AVVideoCodecType = (config.codec == .h264) ? .h264 : .hevc
        let cmCodecType: CMVideoCodecType = (config.codec == .h264) ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC

        // Verify hardware encoding is available
        let hardwareAvailable = Self.isHardwareEncodingAvailable(for: cmCodecType)
        if !hardwareAvailable {
            Log.warning("Hardware encoding not available for \(config.codec.rawValue), will use software fallback", category: .storage)
        } else {
            Log.info("Hardware encoding available for \(config.codec.rawValue)", category: .storage)
        }
        self.isUsingHardwareAcceleration = hardwareAvailable

        // Create AVAssetWriter with MP4 format
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)

        // Video output settings
        // Note: AVAssetWriter will automatically use hardware encoding if available
        // We verify availability above but cannot force it through compressionProperties

        // Use quality-based encoding (CRF-style) for consistent quality regardless of content complexity
        // AVVideoQualityKey: 0.0 = max compression (lowest quality), 1.0 = min compression (highest quality)
        let quality = config.quality
        Log.info("Video encoder using quality-based encoding: \(quality) for \(width)x\(height)", category: .storage)

        var compressionProperties: [String: Any] = [
            AVVideoQualityKey: quality,
            AVVideoMaxKeyFrameIntervalKey: 30,  // Keyframe every 30 frames (like Rewind) for better compression
            // Enable frame reordering (B-frames) for better compression efficiency.
            AVVideoAllowFrameReorderingKey: true,
            AVVideoExpectedSourceFrameRateKey: 30
        ]

        // Add profile level - must use String for HEVC
        if codecType == .hevc {
            compressionProperties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        } else {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // Live capture source: enable real-time mode to reduce deep internal buffering.
        input.expectsMediaDataInRealTime = true

        // Create pixel buffer adaptor
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw StorageModuleError.encodingFailed(underlying: "Cannot add video input to writer")
        }

        writer.add(input)

        // Enable movie fragment interval for incremental readability
        // This writes moof/mdat pairs every 0.1 seconds of video time, allowing AVAssetImageGenerator
        // to read frames before finalization. With 2-second capture intervals and 30fps encoding,
        // each frame is 1/30s of video time, so first fragment writes after ~3 frames (~6 real seconds)
        writer.movieFragmentInterval = CMTime(seconds: 0.1, preferredTimescale: 600)

        // Add metadata including segment start time
        let metadataItem = AVMutableMetadataItem()
        metadataItem.identifier = .quickTimeMetadataCreationDate
        metadataItem.dataType = kCMMetadataBaseDataType_RawData as String

        // Use ISO 8601 date format for creation date
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateString = dateFormatter.string(from: segmentStartTime)
        metadataItem.value = dateString as NSString

        writer.metadata = [metadataItem]

        // Start writing session
        guard writer.startWriting() else {
            throw StorageModuleError.encodingFailed(underlying: "Failed to start writing: \(writer.error?.localizedDescription ?? "unknown")")
        }

        writer.startSession(atSourceTime: .zero)

        self.assetWriter = writer
        self.videoInput = input
        self.adaptor = adaptor
        self.isFinalized = false
        self.frameCount = 0
        self.fragmentCount = 0
        self.lastLoggedFileSize = 0
        self.flushedFrameCount = 0
        self.lastDurableFileSizeBytes = 0

        await StorageVideoEncodingMemoryLedger.registerSession(
            identifier: outputURL.path,
            width: width,
            height: height,
            usesHardwareAcceleration: hardwareAvailable
        )

        Log.info("Video encoder initialized with movieFragmentInterval=0.1s (frames readable after ~3 captures)", category: .storage)
    }

    public func encode(pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws {
        guard var input = videoInput, var adaptor = adaptor, !isFinalized else {
            Log.error("[HEVCEncoder] encode() called but encoder is in bad state: videoInput=\(videoInput != nil), adaptor=\(self.adaptor != nil), isFinalized=\(isFinalized), frameCount=\(frameCount), outputURL=\(outputURL?.lastPathComponent ?? "nil")", category: .storage)
            throw StorageModuleError.encodingFailed(underlying: "Encoder not initialized or finalized")
        }

        // Check if the output file still exists - it may have been deleted by another process
        // If deleted, recreate the encoder to continue writing
        if let url = outputURL, !FileManager.default.fileExists(atPath: url.path) {
            Log.warning("⚠️ Video file was deleted externally, recreating encoder: \(url.path)", category: .storage)
            try await recreateEncoder()

            // Re-fetch input and adaptor after recreation
            guard let newInput = videoInput, let newAdaptor = self.adaptor else {
                throw StorageModuleError.encodingFailed(underlying: "Failed to recreate encoder after file deletion")
            }
            input = newInput
            adaptor = newAdaptor
        }

        // Wait for input to be ready with timeout (5 seconds max)
        let maxWaitIterations = 5000 // 5000 * 1ms = 5 seconds
        var waitIterations = 0
        while !input.isReadyForMoreMediaData {
            waitIterations += 1
            if waitIterations >= maxWaitIterations {
                Log.error("[HEVCEncoder] Encoder timeout: isReadyForMoreMediaData never became true after 5s, auto-finalizing. frameCount=\(frameCount), outputURL=\(outputURL?.lastPathComponent ?? "nil")", category: .storage)
                try await finalize()
                throw StorageModuleError.encodingFailed(underlying: "Encoder timeout waiting for input ready - auto-finalized")
            }
            try await Task.sleep(for: .nanoseconds(Int64(1_000_000)), clock: .continuous) // 1ms
        }

        guard adaptor.append(pixelBuffer, withPresentationTime: timestamp) else {
            Log.error("[HEVCEncoder] adaptor.append() failed at frameCount=\(frameCount), timestamp=\(timestamp.seconds)s, writerStatus=\(assetWriter?.status.rawValue ?? -1), outputURL=\(outputURL?.lastPathComponent ?? "nil")", category: .storage)
            throw StorageModuleError.encodingFailed(underlying: "Failed to append pixel buffer")
        }

        frameCount += 1

        // Check if a new fragment was written by monitoring file size changes
        // Fragments are written every ~4 seconds of video time
        if let url = outputURL {
            // Also check if file was deleted after append - if so, recreate immediately
            // This minimizes frame loss to at most 1 frame
            if !FileManager.default.fileExists(atPath: url.path) {
                Log.warning("⚠️ Video file deleted after append, recreating encoder: \(url.path)", category: .storage)
                try await recreateEncoder()
                return
            }

            let currentSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let sizeIncrease = currentSize - lastLoggedFileSize

            // A fragment write typically causes a significant size jump (>1KB)
            // Log when we detect a new fragment has been flushed to disk
            if sizeIncrease > 1024 && lastLoggedFileSize > 0 {
                fragmentCount += 1
                // The fragment we just detected was written BEFORE this frame's append
                // With B-frame reordering, we can't be certain the previous frame is in the fragment either
                // frameCount is already incremented (includes current frame), so:
                // - frameCount-1 = index of current frame (not yet flushed)
                // - frameCount-2 = index of previous frame (may not be flushed due to B-frames)
                // To be safe, only mark frames up to frameCount-2 as flushed
                // This means indices 0 to frameCount-3 are readable (< frameCount-2)
                flushedFrameCount = max(0, frameCount - 2)
                lastDurableFileSizeBytes = max(lastDurableFileSizeBytes, currentSize)
                Log.info("📦 Fragment \(fragmentCount) written: +\(sizeIncrease / 1024)KB (total: \(currentSize / 1024)KB, \(flushedFrameCount) frames flushed, video time: \(String(format: "%.1f", timestamp.seconds))s) - frames now readable!", category: .storage)
                lastLoggedFileSize = currentSize
            } else if lastLoggedFileSize == 0 && currentSize > 0 {
                // First write - initialization
                lastLoggedFileSize = currentSize
            }
        }
    }

    public func finalize() async throws {
        guard let writer = assetWriter, let input = videoInput, !isFinalized else { return }
        let outputPath = outputURL?.path

        let preSize = (try? FileManager.default.attributesOfItem(atPath: outputURL?.path ?? "")[.size] as? Int64) ?? 0

        Log.info("[HEVCEncoder] Finalizing: outputURL=\(outputURL?.lastPathComponent ?? "nil"), frameCount=\(frameCount), fragmentCount=\(fragmentCount), preFinalizeSize=\(preSize / 1024)KB, writerStatus=\(writer.status.rawValue)", category: .storage)

        isFinalized = true
        input.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw StorageModuleError.encodingFailed(underlying: "Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        let postSize = (try? FileManager.default.attributesOfItem(atPath: outputURL?.path ?? "")[.size] as? Int64) ?? 0
        Log.info("✅ Video finalized: \(frameCount) frames, \(fragmentCount) fragments written during recording, final size: \(postSize / 1024)KB (defragmented: +\((postSize - preSize) / 1024)KB)", category: .storage)

        assetWriter = nil
        videoInput = nil
        adaptor = nil
        if let outputPath {
            await StorageVideoEncodingMemoryLedger.removeSession(identifier: outputPath)
        }
    }

    /// Recreate the encoder if the output file was deleted externally
    /// This preserves the frame count so timestamps continue correctly
    private func recreateEncoder() async throws {
        guard let url = outputURL,
              let startTime = segmentStartTime,
              let config = initConfig else {
            throw StorageModuleError.encodingFailed(underlying: "Cannot recreate encoder: missing initialization parameters")
        }

        // Clean up old writer without deleting file (it's already gone)
        if let writer = assetWriter {
            videoInput?.markAsFinished()
            await writer.finishWriting()
        }

        // Clear state but preserve frame count for correct timestamps
        let savedFrameCount = frameCount
        assetWriter = nil
        videoInput = nil
        adaptor = nil
        isFinalized = false
        fragmentCount = 0
        lastLoggedFileSize = 0
        flushedFrameCount = 0
        lastDurableFileSizeBytes = 0

        // Reinitialize with same parameters
        try await initialize(width: initWidth, height: initHeight, config: config, outputURL: url, segmentStartTime: startTime)

        // Restore frame count so timestamps continue from where we left off
        frameCount = savedFrameCount

        Log.info("✅ Encoder recreated successfully, continuing from frame \(frameCount)", category: .storage)
    }

    public func reset() async {
        let outputPath = outputURL?.path
        if let writer = assetWriter {
            videoInput?.markAsFinished()
            await writer.finishWriting()
        }
        assetWriter = nil
        videoInput = nil
        adaptor = nil
        isFinalized = false
        isUsingHardwareAcceleration = false
        frameCount = 0
        fragmentCount = 0
        lastLoggedFileSize = 0
        flushedFrameCount = 0
        lastDurableFileSizeBytes = 0
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
        segmentStartTime = nil
        if let outputPath {
            await StorageVideoEncodingMemoryLedger.removeSession(identifier: outputPath)
        }
    }

    /// Returns true if hardware acceleration is being used for encoding
    public func isHardwareAccelerated() -> Bool {
        return isUsingHardwareAcceleration
    }

    /// Returns true if at least one fragment has been written to disk
    /// The fragmented MP4 is only readable after the first fragment is flushed
    public func hasFragmentWritten() -> Bool {
        return fragmentCount > 0
    }

    /// Returns the number of frames that have been confirmed flushed to disk
    /// Frames with index < this value are guaranteed to be readable from the video file
    public func framesFlushedToDisk() -> Int {
        return flushedFrameCount
    }

    /// Returns the on-disk file size at the last known durable fragment boundary.
    public func durableFileSizeBytes() -> Int64 {
        return lastDurableFileSizeBytes
    }
}
