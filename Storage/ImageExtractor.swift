import Foundation
import AppKit
import AVFoundation
import Shared

/// Protocol for extracting frame images from video storage
/// Abstracts the difference between Retrace (HEVC via StorageManager) and Rewind (MP4 via AVAsset)
public protocol ImageExtractor: Sendable {
    /// Extract a single frame from video storage
    /// - Parameters:
    ///   - videoPath: Path to the video file (may be relative or absolute)
    ///   - frameIndex: Frame index within the video
    ///   - frameRate: Frame rate of the video (optional, used for time calculation)
    /// - Returns: JPEG image data
    func extractFrame(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> Data
}

// MARK: - HEVC Storage Extractor (Retrace)

/// Image extractor for Retrace's custom HEVC storage
/// Uses StorageManager's optimized frame extraction
public final class HEVCStorageExtractor: ImageExtractor {
    private let storageManager: StorageManager

    public init(storageManager: StorageManager) {
        self.storageManager = storageManager
    }

    public func extractFrame(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> Data {
        // Extract segment ID from path (Retrace uses integer IDs as filenames)
        // Path format: chunks/YYYYMM/DD/123456789
        let components = videoPath.split(separator: "/")
        guard let filename = components.last,
              let segmentIDValue = Int64(filename) else {
            throw ImageExtractionError.invalidPath(videoPath)
        }

        let segmentID = VideoSegmentID(value: segmentIDValue)

        // StorageManager handles all the complexity:
        // - Direct HEVC decoding
        // - JPEG compression
        // - Batch frame reading optimization
        return try await storageManager.readFrame(segmentID: segmentID, frameIndex: frameIndex)
    }
}

// MARK: - AVAsset Extractor (Rewind)

/// Image extractor for Rewind's MP4 videos using AVFoundation
/// Handles the symlink hack needed for extensionless MP4 files
public final class AVAssetExtractor: ImageExtractor {
    private let imageCache = NSCache<NSString, NSData>()
    private let storageRoot: String

    public init(storageRoot: String) {
        self.storageRoot = storageRoot
        // Configure cache to store ~100 extracted frames
        imageCache.countLimit = 100
        // Approximate 50KB per JPEG = 5MB total cache
        imageCache.totalCostLimit = 5 * 1024 * 1024
    }

    public func extractFrame(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> Data {
        // Check cache first
        let cacheKey = "\(videoPath)_\(frameIndex)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached as Data
        }

        // Construct full path from storage root
        let fullVideoPath: String
        if videoPath.hasPrefix("/") {
            fullVideoPath = videoPath
        } else {
            fullVideoPath = "\(storageRoot)/\(videoPath)"
        }

        // CRITICAL: Rewind videos lack file extensions
        // AVAssetImageGenerator requires .mp4 extension to identify format
        // Solution: Create temporary symlink with .mp4 extension
        let originalURL = URL(fileURLWithPath: fullVideoPath)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            try FileManager.default.createSymbolicLink(
                at: tempURL,
                withDestinationURL: originalURL
            )
        } catch {
            throw ImageExtractionError.symlinkFailed(path: fullVideoPath, error: error)
        }

        // Use AVAssetImageGenerator for frame extraction
        let asset = AVAsset(url: tempURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.01, preferredTimescale: 600)

        // Calculate CMTime from frame index
        // Use provided frame rate or assume 30fps
        let effectiveFrameRate = frameRate ?? 30.0
        let timeInSeconds = Double(frameIndex) / effectiveFrameRate
        let time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)

        // Extract CGImage → NSImage → TIFF → Bitmap → JPEG (macOS conversion pipeline)
        let cgImage: CGImage
        do {
            cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
        } catch {
            throw ImageExtractionError.extractionFailed(
                path: fullVideoPath,
                frameIndex: frameIndex,
                error: error
            )
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapImage.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.8]
              ) else {
            throw ImageExtractionError.conversionFailed(path: fullVideoPath)
        }

        // Cache the result
        imageCache.setObject(jpegData as NSData, forKey: cacheKey, cost: jpegData.count)
        return jpegData
    }
}

// MARK: - Errors

public enum ImageExtractionError: Error, CustomStringConvertible {
    case invalidPath(String)
    case symlinkFailed(path: String, error: Error)
    case extractionFailed(path: String, frameIndex: Int, error: Error)
    case conversionFailed(path: String)

    public var description: String {
        switch self {
        case .invalidPath(let path):
            return "Invalid video path: \(path)"
        case .symlinkFailed(let path, let error):
            return "Failed to create symlink for \(path): \(error.localizedDescription)"
        case .extractionFailed(let path, let frameIndex, let error):
            return "Failed to extract frame \(frameIndex) from \(path): \(error.localizedDescription)"
        case .conversionFailed(let path):
            return "Failed to convert extracted image to JPEG for \(path)"
        }
    }
}
