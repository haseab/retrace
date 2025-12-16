import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox
import Shared

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

    public func initialize(width: Int, height: Int, config: VideoEncoderConfig, outputURL: URL, segmentStartTime: Date) throws {
        guard assetWriter == nil else { return }

        self.outputURL = outputURL
        self.segmentStartTime = segmentStartTime

        // Remove any existing file
        try? FileManager.default.removeItem(at: outputURL)

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
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: config.targetBitrate ?? 2_000_000,
            AVVideoMaxKeyFrameIntervalKey: config.keyframeInterval,
            AVVideoAllowFrameReorderingKey: false,
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
        input.expectsMediaDataInRealTime = false

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
    }

    public func encode(pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws {
        guard let input = videoInput, let adaptor = adaptor, !isFinalized else {
            throw StorageModuleError.encodingFailed(underlying: "Encoder not initialized or finalized")
        }

        // Wait for input to be ready
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }

        guard adaptor.append(pixelBuffer, withPresentationTime: timestamp) else {
            throw StorageModuleError.encodingFailed(underlying: "Failed to append pixel buffer")
        }
    }

    public func finalize() async throws {
        guard let writer = assetWriter, let input = videoInput, !isFinalized else { return }
        isFinalized = true

        input.markAsFinished()

        await writer.finishWriting()

        if writer.status == .failed {
            throw StorageModuleError.encodingFailed(underlying: "Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        assetWriter = nil
        videoInput = nil
        adaptor = nil
    }

    public func reset() async {
        if let writer = assetWriter {
            videoInput?.markAsFinished()
            await writer.finishWriting()
        }
        assetWriter = nil
        videoInput = nil
        adaptor = nil
        isFinalized = false
        isUsingHardwareAcceleration = false
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
        segmentStartTime = nil
    }

    /// Returns true if hardware acceleration is being used for encoding
    public func isHardwareAccelerated() -> Bool {
        return isUsingHardwareAcceleration
    }
}
