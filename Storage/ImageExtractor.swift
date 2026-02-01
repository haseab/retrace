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

// MARK: - Frame Generator Actor

/// Actor that serializes access to AVAssetImageGenerator for a single video file
/// This prevents concurrent access issues that cause intermittent decode failures
private actor FrameGenerator {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator
    private let symlinkURL: URL?

    init(assetURL: URL, symlinkURL: URL?) {
        self.asset = AVURLAsset(url: assetURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        self.symlinkURL = symlinkURL

        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.appliesPreferredTrackTransform = true
        self.generator = gen
    }

    deinit {
        // Clean up symlink when actor is deallocated
        if let symlinkURL = symlinkURL {
            try? FileManager.default.removeItem(at: symlinkURL)
        }
    }

    /// Extract a frame at the given time - serialized by actor
    func cgImage(at time: CMTime) throws -> CGImage {
        var actual = CMTime.zero
        return try generator.copyCGImage(at: time, actualTime: &actual)
    }

    /// Check if symlink still exists (for cache validation)
    var isValid: Bool {
        if let symlinkURL = symlinkURL {
            return FileManager.default.fileExists(atPath: symlinkURL.path)
        }
        return true
    }
}

// MARK: - Generator Cache

/// Thread-safe cache for FrameGenerator actors
/// Uses NSCache for automatic memory management with LRU eviction
private final class GeneratorCache: @unchecked Sendable {
    private let cache = NSCache<NSString, AnyObject>()
    private let lock = NSLock()

    init(countLimit: Int) {
        cache.countLimit = countLimit
    }

    func get(_ key: String) -> FrameGenerator? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key as NSString) as? FrameGenerator
    }

    func set(_ key: String, generator: FrameGenerator) {
        lock.lock()
        defer { lock.unlock() }
        cache.setObject(generator as AnyObject, forKey: key as NSString)
    }

    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeObject(forKey: key as NSString)
    }
}

// MARK: - HEVC Storage Extractor (Retrace)

/// Image extractor for Retrace's custom HEVC storage
/// Uses actor-based serialization for safe concurrent access
public final class HEVCStorageExtractor: ImageExtractor {
    private let storageRoot: String
    private let imageCache = NSCache<NSString, NSData>()
    private let generatorCache: GeneratorCache

    public init(storageManager: StorageManager) {
        self.storageRoot = StorageConfig.default.expandedStorageRootPath
        imageCache.countLimit = 100
        imageCache.totalCostLimit = 5 * 1024 * 1024
        generatorCache = GeneratorCache(countLimit: 10)
    }

    public init(storageRoot: String) {
        self.storageRoot = storageRoot
        imageCache.countLimit = 100
        imageCache.totalCostLimit = 5 * 1024 * 1024
        generatorCache = GeneratorCache(countLimit: 10)
    }

    public func extractFrame(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> Data {
        // Check image cache first
        let frameCacheKey = "\(videoPath)_\(frameIndex)" as NSString
        if let cached = imageCache.object(forKey: frameCacheKey) {
            return cached as Data
        }

        // Construct full path
        let fullVideoPath: String
        if videoPath.hasPrefix("/") {
            fullVideoPath = videoPath
        } else {
            fullVideoPath = "\(storageRoot)/\(videoPath)"
        }

        // Get or create frame generator for this video
        let generator = try await getOrCreateGenerator(for: fullVideoPath)

        // Calculate CMTime from frame index
        let effectiveFrameRate = frameRate ?? 30.0
        let time: CMTime
        if effectiveFrameRate == 30.0 {
            time = CMTime(value: Int64(frameIndex) * 20, timescale: 600)
        } else {
            let timeInSeconds = Double(frameIndex) / effectiveFrameRate
            time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)
        }

        // Extract frame using serialized actor
        let cgImage: CGImage
        do {
            cgImage = try await generator.cgImage(at: time)
        } catch {
            // On failure, invalidate cache (file may have changed)
            generatorCache.remove(fullVideoPath)
            throw ImageExtractionError.extractionFailed(
                path: fullVideoPath,
                frameIndex: frameIndex,
                error: error
            )
        }

        // Convert to JPEG
        let jpegData = try convertToJPEG(cgImage: cgImage, path: fullVideoPath)

        // Cache the result
        imageCache.setObject(jpegData as NSData, forKey: frameCacheKey, cost: jpegData.count)
        return jpegData
    }

    private func getOrCreateGenerator(for fullVideoPath: String) async throws -> FrameGenerator {
        // Check cache first
        if let cached = generatorCache.get(fullVideoPath) {
            // Verify generator is still valid
            if await cached.isValid {
                return cached
            }
            generatorCache.remove(fullVideoPath)
        }

        // Validate file exists
        guard FileManager.default.fileExists(atPath: fullVideoPath) else {
            throw ImageExtractionError.invalidPath(fullVideoPath)
        }

        // Check if file is empty
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fullVideoPath)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            Log.warning("[HEVCStorageExtractor] Video file is empty (0 bytes): \(fullVideoPath)", category: .storage)
            throw ImageExtractionError.extractionFailed(
                path: fullVideoPath,
                frameIndex: 0,
                error: NSError(domain: "HEVCStorageExtractor", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Video file is empty"])
            )
        }

        // Handle extensionless files by creating symlink
        let originalURL = URL(fileURLWithPath: fullVideoPath)
        let assetURL: URL
        var symlinkURL: URL? = nil

        if originalURL.pathExtension.lowercased() == "mp4" {
            assetURL = originalURL
        } else {
            // Create symlink with .mp4 extension
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            symlinkURL = tempPath

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

        // Create generator actor (owns symlink lifetime)
        let generator = FrameGenerator(assetURL: assetURL, symlinkURL: symlinkURL)
        generatorCache.set(fullVideoPath, generator: generator)
        return generator
    }

    private func convertToJPEG(cgImage: CGImage, path: String) throws -> Data {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapImage.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.8]
              ) else {
            throw ImageExtractionError.conversionFailed(path: path)
        }
        return jpegData
    }
}

// MARK: - AVAsset Extractor (Rewind)

/// Image extractor for Rewind's MP4 videos using AVFoundation
/// Uses actor-based serialization for safe concurrent access
public final class AVAssetExtractor: ImageExtractor {
    private let imageCache = NSCache<NSString, NSData>()
    private let generatorCache: GeneratorCache
    private let storageRoot: String

    public init(storageRoot: String) {
        self.storageRoot = storageRoot
        imageCache.countLimit = 100
        imageCache.totalCostLimit = 5 * 1024 * 1024
        generatorCache = GeneratorCache(countLimit: 10)
    }

    public func extractFrame(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> Data {
        // Check image cache first
        let frameCacheKey = "\(videoPath)_\(frameIndex)" as NSString
        if let cached = imageCache.object(forKey: frameCacheKey) {
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
        if !FileManager.default.fileExists(atPath: fullVideoPath) {
            let pathWithExtension = fullVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                fullVideoPath = pathWithExtension
            }
        }

        // Get or create frame generator for this video
        let generator = try await getOrCreateGenerator(for: fullVideoPath)

        // Calculate CMTime from frame index
        let effectiveFrameRate = frameRate ?? 30.0
        let time: CMTime
        if effectiveFrameRate == 30.0 {
            time = CMTime(value: Int64(frameIndex) * 20, timescale: 600)
        } else {
            let timeInSeconds = Double(frameIndex) / effectiveFrameRate
            time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)
        }

        // Extract frame using serialized actor
        let cgImage: CGImage
        do {
            cgImage = try await generator.cgImage(at: time)
        } catch {
            // On failure, invalidate cache (file may have changed)
            generatorCache.remove(fullVideoPath)
            throw ImageExtractionError.extractionFailed(
                path: fullVideoPath,
                frameIndex: frameIndex,
                error: error
            )
        }

        // Convert to JPEG
        let jpegData = try convertToJPEG(cgImage: cgImage, path: fullVideoPath)

        // Cache the result
        imageCache.setObject(jpegData as NSData, forKey: frameCacheKey, cost: jpegData.count)
        return jpegData
    }

    private func getOrCreateGenerator(for fullVideoPath: String) async throws -> FrameGenerator {
        // Check cache first
        if let cached = generatorCache.get(fullVideoPath) {
            // Verify generator is still valid
            if await cached.isValid {
                return cached
            }
            generatorCache.remove(fullVideoPath)
        }

        // Check if file is empty
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fullVideoPath)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            Log.warning("[AVAssetExtractor] Video file is empty (0 bytes): \(fullVideoPath)", category: .storage)
            throw ImageExtractionError.extractionFailed(
                path: fullVideoPath,
                frameIndex: 0,
                error: NSError(domain: "AVAssetExtractor", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Video file is empty"])
            )
        }

        // Handle extensionless files by creating symlink
        let originalURL = URL(fileURLWithPath: fullVideoPath)
        let assetURL: URL
        var symlinkURL: URL? = nil

        if originalURL.pathExtension.lowercased() == "mp4" {
            assetURL = originalURL
        } else {
            // Create symlink with .mp4 extension
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            symlinkURL = tempPath

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

        // Create generator actor (owns symlink lifetime)
        let generator = FrameGenerator(assetURL: assetURL, symlinkURL: symlinkURL)
        generatorCache.set(fullVideoPath, generator: generator)
        return generator
    }

    private func convertToJPEG(cgImage: CGImage, path: String) throws -> Data {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapImage.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.8]
              ) else {
            throw ImageExtractionError.conversionFailed(path: path)
        }
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
