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
/// Uses AVAssetImageGenerator for fast single-frame extraction
public final class HEVCStorageExtractor: ImageExtractor {
    private let storageRoot: String
    private nonisolated(unsafe) let imageCache = NSCache<NSString, NSData>()

    public init(storageManager: StorageManager) {
        // Get storage root from StorageConfig default
        self.storageRoot = StorageConfig.default.expandedStorageRootPath
        // Configure cache to store ~100 extracted frames
        imageCache.countLimit = 100
        // Approximate 50KB per JPEG = 5MB total cache
        imageCache.totalCostLimit = 5 * 1024 * 1024
    }

    public init(storageRoot: String) {
        self.storageRoot = storageRoot
        imageCache.countLimit = 100
        imageCache.totalCostLimit = 5 * 1024 * 1024
    }

    public func extractFrame(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> Data {
        // Check cache first
        let cacheKey = "\(videoPath)_\(frameIndex)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached as Data
        }

        // Construct full path
        var fullVideoPath: String
        if videoPath.hasPrefix("/") {
            fullVideoPath = videoPath
        } else {
            fullVideoPath = "\(storageRoot)/\(videoPath)"
        }

        // Check if file exists
        if !FileManager.default.fileExists(atPath: fullVideoPath) {
            throw ImageExtractionError.invalidPath(fullVideoPath)
        }

        // Check if file is empty (still being written)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fullVideoPath)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            Log.warning("[HEVCStorageExtractor] Video file is empty (0 bytes), still being written: \(fullVideoPath)", category: .storage)
            throw ImageExtractionError.extractionFailed(
                path: fullVideoPath,
                frameIndex: frameIndex,
                error: NSError(domain: "HEVCStorageExtractor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video file is empty (still being written)"])
            )
        }

        // Handle extensionless files by creating symlink
        let originalURL = URL(fileURLWithPath: fullVideoPath)
        let assetURL: URL
        var tempURL: URL? = nil

        if originalURL.pathExtension.lowercased() == "mp4" {
            assetURL = originalURL
        } else {
            // Create temporary symlink with .mp4 extension
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            tempURL = tempPath

            do {
                try FileManager.default.createSymbolicLink(
                    at: tempPath,
                    withDestinationURL: originalURL
                )
            } catch {
                throw ImageExtractionError.symlinkFailed(path: fullVideoPath, error: error)
            }
            assetURL = tempPath
        }

        defer {
            if let tempURL = tempURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        // Use AVAssetImageGenerator for fast single-frame extraction
        let asset = AVAsset(url: assetURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        // Use zero tolerance to get EXACT frames - handles B-frame encoded videos correctly
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.requestedTimeToleranceBefore = .zero

        // Calculate CMTime from frame index
        let effectiveFrameRate = frameRate ?? 30.0
        let time: CMTime
        if effectiveFrameRate == 30.0 {
            // Fast path for 30fps - use exact integer arithmetic
            time = CMTime(value: Int64(frameIndex) * 20, timescale: 600)
        } else {
            let timeInSeconds = Double(frameIndex) / effectiveFrameRate
            time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)
        }

        // Extract frame
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

        // Convert to JPEG
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

// MARK: - AVAsset Extractor (Rewind)

/// Image extractor for Rewind's MP4 videos using AVFoundation
/// Handles the symlink hack needed for extensionless MP4 files
public final class AVAssetExtractor: ImageExtractor {
    private nonisolated(unsafe) let imageCache = NSCache<NSString, NSData>()
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
        var fullVideoPath: String
        if videoPath.hasPrefix("/") {
            fullVideoPath = videoPath
        } else {
            fullVideoPath = "\(storageRoot)/\(videoPath)"
        }

        // Check if file exists - if not, try with .mp4 extension
        // This handles the case where database stores path without extension but file has .mp4
        if !FileManager.default.fileExists(atPath: fullVideoPath) {
            let pathWithExtension = fullVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                fullVideoPath = pathWithExtension
            }
        }

        // Check if file is empty (incomplete/damaged video)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fullVideoPath)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            // File is empty - likely still being written to. Do NOT delete.
            Log.warning("[AVAssetExtractor] Video file is empty (0 bytes), still being written: \(fullVideoPath)", category: .storage)
            throw ImageExtractionError.extractionFailed(
                path: fullVideoPath,
                frameIndex: frameIndex,
                error: NSError(domain: "AVAssetExtractor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video file is empty (still being written)"])
            )
        }

        // Determine the URL to use for AVFoundation
        // If file already has .mp4 extension, use it directly
        // Otherwise, create a temporary symlink with .mp4 extension so AVFoundation can identify the format
        let originalURL = URL(fileURLWithPath: fullVideoPath)
        let assetURL: URL
        var tempURL: URL? = nil

        if originalURL.pathExtension.lowercased() == "mp4" {
            // File already has .mp4 extension, use directly
            assetURL = originalURL
        } else {
            // Create temporary symlink with .mp4 extension (for extensionless files)
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            tempURL = tempPath

            do {
                try FileManager.default.createSymbolicLink(
                    at: tempPath,
                    withDestinationURL: originalURL
                )
            } catch {
                throw ImageExtractionError.symlinkFailed(path: fullVideoPath, error: error)
            }
            assetURL = tempPath
        }

        defer {
            if let tempURL = tempURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        // Use AVAssetImageGenerator for frame extraction
        let asset = AVAsset(url: assetURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        // Use zero tolerance to get EXACT frames - required for B-frame encoded videos
        // Without zero tolerance, AVAssetImageGenerator may return the nearest keyframe
        // which causes duplicate/mismatched frames
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.requestedTimeToleranceBefore = .zero

        // Calculate CMTime from frame index using integer arithmetic to avoid floating point precision issues
        // For 30fps with timescale 600: each frame = 20 time units (600/30 = 20)
        let effectiveFrameRate = frameRate ?? 30.0
        let time: CMTime
        if effectiveFrameRate == 30.0 {
            // Fast path for 30fps - use exact integer arithmetic
            time = CMTime(value: Int64(frameIndex) * 20, timescale: 600)
        } else {
            // For other frame rates, use floating point
            let timeInSeconds = Double(frameIndex) / effectiveFrameRate
            time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)
        }

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
