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

    /// Extract a single frame as a CGImage without JPEG encoding/decoding round-trips.
    func extractFrameCGImage(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> CGImage
}

/// Optional cache-control interface for extractors that keep AVFoundation decode state alive.
public protocol FrameExtractionCacheInvalidating: Sendable {
    func purgeFrameExtractionCaches(reason: String)
}

private struct CacheFootprintSummary: Sendable {
    let entryCount: Int
    let bytes: Int64
}

private struct FrameGeneratorMemoryEstimate: Sendable {
    let bytes: Int64
    let pixelWidth: Int
    let pixelHeight: Int
}

private struct GeneratorCacheSummary: Sendable {
    let generatorCount: Int
    let bytes: Int64
    let maxPixelWidth: Int
    let maxPixelHeight: Int
}

// MARK: - Frame Generator Actor

/// Actor that serializes access to AVAssetImageGenerator for a single video file
/// This prevents concurrent access issues that cause intermittent decode failures
private actor FrameGenerator {
    private static let bytesPerPixel: Int64 = 4
    private static let retainedSurfaceMultiplier: Int64 = 2
    private static let minimumEstimatedBytes: Int64 = 4 * 1024 * 1024
    private static let generatorOverheadBytes: Int64 = 512 * 1024

    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator
    private let symlinkURL: URL?

    nonisolated static func makeAsset(url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
    }

    nonisolated static func estimateDecodeState(for asset: AVURLAsset) -> FrameGeneratorMemoryEstimate {
        guard let track = asset.tracks(withMediaType: .video).first else {
            return FrameGeneratorMemoryEstimate(
                bytes: Self.minimumEstimatedBytes,
                pixelWidth: 0,
                pixelHeight: 0
            )
        }

        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        let pixelWidth = max(Int(abs(transformedSize.width.rounded())), 0)
        let pixelHeight = max(Int(abs(transformedSize.height.rounded())), 0)
        guard pixelWidth > 0, pixelHeight > 0 else {
            return FrameGeneratorMemoryEstimate(
                bytes: Self.minimumEstimatedBytes,
                pixelWidth: 0,
                pixelHeight: 0
            )
        }

        let surfaceBytes = Int64(pixelWidth) * Int64(pixelHeight) * Self.bytesPerPixel
        let estimatedBytes = max(
            surfaceBytes * Self.retainedSurfaceMultiplier + Self.generatorOverheadBytes,
            Self.minimumEstimatedBytes
        )
        return FrameGeneratorMemoryEstimate(
            bytes: estimatedBytes,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    init(asset: AVURLAsset, symlinkURL: URL?) {
        self.asset = asset
        self.symlinkURL = symlinkURL

        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.appliesPreferredTrackTransform = true
        self.generator = gen
    }

    deinit {
        generator.cancelAllCGImageGeneration()
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

/// Thread-safe cache for FrameGenerator actors.
/// Uses an explicit LRU map so eviction never re-enters the cache while a lock is held.
private final class GeneratorCache: @unchecked Sendable {
    private struct Entry {
        let generator: FrameGenerator
        let estimate: FrameGeneratorMemoryEstimate
        var lastAccess: Date
    }

    private let lock = NSLock()
    private let countLimit: Int
    private var entries: [String: Entry] = [:]

    init(countLimit: Int) {
        self.countLimit = max(1, countLimit)
    }

    func get(_ key: String) -> FrameGenerator? {
        let referenceTime = Date()
        var generator: FrameGenerator?
        var evictedGenerators: [FrameGenerator] = []

        lock.lock()
        if var entry = entries[key] {
            entry.lastAccess = referenceTime
            entries[key] = entry
            generator = entry.generator
        }
        evictedGenerators = evictEntriesLocked(referenceTime: referenceTime)
        lock.unlock()

        withExtendedLifetime(evictedGenerators) {}
        return generator
    }

    func set(_ key: String, generator: FrameGenerator, estimate: FrameGeneratorMemoryEstimate) {
        let referenceTime = Date()
        var evictedGenerators: [FrameGenerator] = []

        lock.lock()
        if let existing = entries.removeValue(forKey: key) {
            evictedGenerators.append(existing.generator)
        }
        entries[key] = Entry(
            generator: generator,
            estimate: estimate,
            lastAccess: referenceTime
        )
        evictedGenerators.append(contentsOf: evictEntriesLocked(referenceTime: referenceTime))
        lock.unlock()

        withExtendedLifetime(evictedGenerators) {}
    }

    func summary() -> GeneratorCacheSummary {
        lock.lock()
        defer { lock.unlock() }
        let estimates = entries.values.map(\.estimate)
        let totalBytes = estimates.reduce(into: Int64(0)) { total, estimate in
            total = Self.clampedAdd(total, estimate.bytes)
        }
        let maxWidth = estimates.map(\.pixelWidth).max() ?? 0
        let maxHeight = estimates.map(\.pixelHeight).max() ?? 0
        return GeneratorCacheSummary(
            generatorCount: entries.count,
            bytes: totalBytes,
            maxPixelWidth: maxWidth,
            maxPixelHeight: maxHeight
        )
    }

    func remove(_ key: String) {
        var removedGenerator: FrameGenerator?
        lock.lock()
        removedGenerator = entries.removeValue(forKey: key)?.generator
        lock.unlock()
        withExtendedLifetime(removedGenerator) {}
    }

    func removeAll() {
        var removedGenerators: [FrameGenerator] = []
        lock.lock()
        removedGenerators = entries.values.map(\.generator)
        entries.removeAll()
        lock.unlock()
        withExtendedLifetime(removedGenerators) {}
    }

    private func evictEntriesLocked(referenceTime: Date) -> [FrameGenerator] {
        let keysToRemove = GeneratorCachePolicy.keysToEvict(
            lastAccessByKey: entries.mapValues(\.lastAccess),
            referenceTime: referenceTime,
            countLimit: countLimit
        )
        guard !keysToRemove.isEmpty else {
            return []
        }
        var removedGenerators: [FrameGenerator] = []
        for key in keysToRemove {
            if let removed = entries.removeValue(forKey: key) {
                removedGenerators.append(removed.generator)
            }
        }
        return removedGenerators
    }

    private static func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        if lhs > Int64.max - rhs {
            return Int64.max
        }
        return lhs + rhs
    }
}

private final class TrackedDataCache: @unchecked Sendable {
    private struct Entry {
        let data: Data
        let byteCount: Int64
        var lastAccess: Date
    }

    private let lock = NSLock()
    private let countLimit: Int
    private let totalCostLimit: Int64
    private var entries: [String: Entry] = [:]
    private var totalBytes: Int64 = 0

    init(countLimit: Int, totalCostLimit: Int) {
        self.countLimit = max(1, countLimit)
        self.totalCostLimit = max(1, Int64(totalCostLimit))
    }

    func get(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else {
            return nil
        }
        entry.lastAccess = Date()
        entries[key] = entry
        return entry.data
    }

    func set(_ key: String, data: Data) {
        let referenceTime = Date()
        let byteCount = Int64(data.count)
        lock.lock()
        if let existing = entries[key] {
            totalBytes -= existing.byteCount
        }
        entries[key] = Entry(data: data, byteCount: byteCount, lastAccess: referenceTime)
        totalBytes = Self.clampedAdd(totalBytes, byteCount)
        trimLocked()
        lock.unlock()
    }

    func summary() -> CacheFootprintSummary {
        lock.lock()
        defer { lock.unlock() }
        return CacheFootprintSummary(entryCount: entries.count, bytes: totalBytes)
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        totalBytes = 0
        lock.unlock()
    }

    private func trimLocked() {
        while entries.count > countLimit || totalBytes > totalCostLimit {
            guard let lruKey = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key,
                  let removed = entries.removeValue(forKey: lruKey) else {
                break
            }
            totalBytes = max(0, totalBytes - removed.byteCount)
        }
    }

    private static func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        if lhs > Int64.max - rhs {
            return Int64.max
        }
        return lhs + rhs
    }
}

// MARK: - HEVC Storage Extractor (Retrace)

/// Image extractor for Retrace's custom HEVC storage
/// Uses actor-based serialization for safe concurrent access
public final class HEVCStorageExtractor: ImageExtractor, FrameExtractionCacheInvalidating {
    private static let memoryLedgerGeneratorCacheTag = "storage.frameExtraction.retrace.generatorCache"
    private static let memoryLedgerImageCacheTag = "storage.frameExtraction.retrace.jpegCache"
    private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 30
    private static let generatorCacheCountLimit = GeneratorCachePolicy.defaultCountLimit
    private static let imageCacheTotalCostLimit = 5 * 1024 * 1024

    private let storageRoot: String
    private let imageCache: TrackedDataCache
    private let generatorCache: GeneratorCache

    public init(storageManager: StorageManager) {
        self.storageRoot = AppPaths.expandedStorageRoot
        imageCache = TrackedDataCache(countLimit: 100, totalCostLimit: Self.imageCacheTotalCostLimit)
        generatorCache = GeneratorCache(countLimit: Self.generatorCacheCountLimit)
        updateMemoryLedger()
    }

    public init(storageRoot: String) {
        self.storageRoot = storageRoot
        imageCache = TrackedDataCache(countLimit: 100, totalCostLimit: Self.imageCacheTotalCostLimit)
        generatorCache = GeneratorCache(countLimit: Self.generatorCacheCountLimit)
        updateMemoryLedger()
    }

    public func extractFrame(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> Data {
        // Check image cache first
        let frameCacheKey = "\(videoPath)_\(frameIndex)"
        if let cached = imageCache.get(frameCacheKey) {
            return cached
        }

        let fullVideoPath = resolveFullVideoPath(videoPath)
        let cgImage = try await extractFrameCGImageInternal(
            fullVideoPath: fullVideoPath,
            frameIndex: frameIndex,
            frameRate: frameRate
        )

        // Convert to JPEG
        let jpegData = try convertToJPEG(cgImage: cgImage, path: fullVideoPath)

        // Cache the result
        imageCache.set(frameCacheKey, data: jpegData)
        updateMemoryLedger()
        return jpegData
    }

    public func extractFrameCGImage(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> CGImage {
        let fullVideoPath = resolveFullVideoPath(videoPath)
        return try await extractFrameCGImageInternal(
            fullVideoPath: fullVideoPath,
            frameIndex: frameIndex,
            frameRate: frameRate
        )
    }

    private func resolveFullVideoPath(_ videoPath: String) -> String {
        if videoPath.hasPrefix("/") {
            return videoPath
        }
        return "\(storageRoot)/\(videoPath)"
    }

    private func frameTime(frameIndex: Int, frameRate: Double?) -> CMTime {
        let effectiveFrameRate = frameRate ?? 30.0
        if effectiveFrameRate == 30.0 {
            return CMTime(value: Int64(frameIndex) * 20, timescale: 600)
        }
        let timeInSeconds = Double(frameIndex) / effectiveFrameRate
        return CMTime(seconds: timeInSeconds, preferredTimescale: 600)
    }

    private func extractFrameCGImageInternal(
        fullVideoPath: String,
        frameIndex: Int,
        frameRate: Double?
    ) async throws -> CGImage {
        let generator = try await getOrCreateGenerator(for: fullVideoPath)
        let time = frameTime(frameIndex: frameIndex, frameRate: frameRate)

        do {
            return try await generator.cgImage(at: time)
        } catch {
            // On failure, invalidate cache (file may have changed)
            generatorCache.remove(fullVideoPath)
            updateMemoryLedger()
            throw ImageExtractionError.extractionFailed(
                path: fullVideoPath,
                frameIndex: frameIndex,
                error: error
            )
        }
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
        let asset = FrameGenerator.makeAsset(url: assetURL)
        let estimate = FrameGenerator.estimateDecodeState(for: asset)
        let generator = FrameGenerator(asset: asset, symlinkURL: symlinkURL)
        generatorCache.set(fullVideoPath, generator: generator, estimate: estimate)
        updateMemoryLedger()
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

    public func purgeFrameExtractionCaches(reason: String) {
        imageCache.removeAll()
        generatorCache.removeAll()
        updateMemoryLedger()
    }

    private func updateMemoryLedger() {
        let imageSummary = imageCache.summary()
        let generatorSummary = generatorCache.summary()

        MemoryLedger.set(
            tag: Self.memoryLedgerGeneratorCacheTag,
            bytes: generatorSummary.bytes,
            count: generatorSummary.generatorCount,
            unit: "generators",
            function: "storage.frame_extraction.retrace",
            kind: "decode-generator-cache",
            note: Self.generatorCacheNote(for: generatorSummary),
            category: .inferred
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerImageCacheTag,
            bytes: imageSummary.bytes,
            count: imageSummary.entryCount,
            unit: "frames",
            function: "storage.frame_extraction.retrace",
            kind: "jpeg-cache",
            note: "compressed"
        )
        MemoryLedger.emitSummary(
            reason: "storage.frame_extraction.memory",
            category: .storage,
            minIntervalSeconds: Self.memoryLedgerSummaryIntervalSeconds
        )
    }

    private static func generatorCacheNote(for summary: GeneratorCacheSummary) -> String {
        guard summary.maxPixelWidth > 0, summary.maxPixelHeight > 0 else {
            return "estimated-native"
        }
        return "estimated-native,max=\(summary.maxPixelWidth)x\(summary.maxPixelHeight)"
    }
}

// MARK: - AVAsset Extractor (Rewind)

/// Image extractor for Rewind's MP4 videos using AVFoundation
/// Uses actor-based serialization for safe concurrent access
public final class AVAssetExtractor: ImageExtractor, FrameExtractionCacheInvalidating {
    private static let memoryLedgerGeneratorCacheTag = "storage.frameExtraction.rewind.generatorCache"
    private static let memoryLedgerImageCacheTag = "storage.frameExtraction.rewind.jpegCache"
    private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 30
    private static let generatorCacheCountLimit = GeneratorCachePolicy.defaultCountLimit
    private static let imageCacheTotalCostLimit = 5 * 1024 * 1024

    private let imageCache: TrackedDataCache
    private let generatorCache: GeneratorCache
    private let storageRoot: String

    public init(storageRoot: String) {
        self.storageRoot = storageRoot
        imageCache = TrackedDataCache(countLimit: 100, totalCostLimit: Self.imageCacheTotalCostLimit)
        generatorCache = GeneratorCache(countLimit: Self.generatorCacheCountLimit)
        updateMemoryLedger()
    }

    public func extractFrame(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> Data {
        // Check image cache first
        let frameCacheKey = "\(videoPath)_\(frameIndex)"
        if let cached = imageCache.get(frameCacheKey) {
            return cached
        }

        let fullVideoPath = resolveFullVideoPath(videoPath)
        let cgImage = try await extractFrameCGImageInternal(
            fullVideoPath: fullVideoPath,
            frameIndex: frameIndex,
            frameRate: frameRate
        )

        // Convert to JPEG
        let jpegData = try convertToJPEG(cgImage: cgImage, path: fullVideoPath)

        // Cache the result
        imageCache.set(frameCacheKey, data: jpegData)
        updateMemoryLedger()
        return jpegData
    }

    public func extractFrameCGImage(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> CGImage {
        let fullVideoPath = resolveFullVideoPath(videoPath)
        return try await extractFrameCGImageInternal(
            fullVideoPath: fullVideoPath,
            frameIndex: frameIndex,
            frameRate: frameRate
        )
    }

    private func resolveFullVideoPath(_ videoPath: String) -> String {
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

        return fullVideoPath
    }

    private func frameTime(frameIndex: Int, frameRate: Double?) -> CMTime {
        let effectiveFrameRate = frameRate ?? 30.0
        if effectiveFrameRate == 30.0 {
            return CMTime(value: Int64(frameIndex) * 20, timescale: 600)
        }
        let timeInSeconds = Double(frameIndex) / effectiveFrameRate
        return CMTime(seconds: timeInSeconds, preferredTimescale: 600)
    }

    private func extractFrameCGImageInternal(
        fullVideoPath: String,
        frameIndex: Int,
        frameRate: Double?
    ) async throws -> CGImage {
        let generator = try await getOrCreateGenerator(for: fullVideoPath)
        let time = frameTime(frameIndex: frameIndex, frameRate: frameRate)

        do {
            return try await generator.cgImage(at: time)
        } catch {
            // On failure, invalidate cache (file may have changed)
            generatorCache.remove(fullVideoPath)
            updateMemoryLedger()
            throw ImageExtractionError.extractionFailed(
                path: fullVideoPath,
                frameIndex: frameIndex,
                error: error
            )
        }
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
        let asset = FrameGenerator.makeAsset(url: assetURL)
        let estimate = FrameGenerator.estimateDecodeState(for: asset)
        let generator = FrameGenerator(asset: asset, symlinkURL: symlinkURL)
        generatorCache.set(fullVideoPath, generator: generator, estimate: estimate)
        updateMemoryLedger()
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

    public func purgeFrameExtractionCaches(reason: String) {
        imageCache.removeAll()
        generatorCache.removeAll()
        updateMemoryLedger()
    }

    private func updateMemoryLedger() {
        let imageSummary = imageCache.summary()
        let generatorSummary = generatorCache.summary()

        MemoryLedger.set(
            tag: Self.memoryLedgerGeneratorCacheTag,
            bytes: generatorSummary.bytes,
            count: generatorSummary.generatorCount,
            unit: "generators",
            function: "storage.frame_extraction.rewind",
            kind: "decode-generator-cache",
            note: Self.generatorCacheNote(for: generatorSummary),
            category: .inferred
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerImageCacheTag,
            bytes: imageSummary.bytes,
            count: imageSummary.entryCount,
            unit: "frames",
            function: "storage.frame_extraction.rewind",
            kind: "jpeg-cache",
            note: "compressed"
        )
        MemoryLedger.emitSummary(
            reason: "storage.frame_extraction.memory",
            category: .storage,
            minIntervalSeconds: Self.memoryLedgerSummaryIntervalSeconds
        )
    }

    private static func generatorCacheNote(for summary: GeneratorCacheSummary) -> String {
        guard summary.maxPixelWidth > 0, summary.maxPixelHeight > 0 else {
            return "estimated-native"
        }
        return "estimated-native,max=\(summary.maxPixelWidth)x\(summary.maxPixelHeight)"
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
