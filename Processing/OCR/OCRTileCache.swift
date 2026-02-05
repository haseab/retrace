import Foundation
import Shared

/// Cached OCR result for a single tile
public struct CachedTileOCR: Sendable {
    /// The tile this cache entry is for
    public let tile: TileInfo
    /// OCR text regions with bounds in frame coordinates
    public let regions: [TextRegion]
    /// When this cache entry was created
    public let timestamp: Date

    public init(tile: TileInfo, regions: [TextRegion], timestamp: Date = Date()) {
        self.tile = tile
        self.regions = regions
        self.timestamp = timestamp
    }
}

/// LRU cache for tile OCR results
/// Automatically invalidates on resolution change or app switch
public actor OCRTileCache {
    /// Maximum number of tiles to cache
    private let maxCacheSize: Int

    /// Cache keyed by tile cacheKey -> CachedTileOCR
    private var cache: [String: CachedTileOCR] = [:]

    /// Access order for LRU eviction (most recent at end)
    private var accessOrder: [String] = []

    /// Current frame dimensions (cache invalidated on change)
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0

    /// Current app bundle ID (cache invalidated on change)
    private var currentAppBundleID: String?

    /// Statistics
    private var hitCount: Int = 0
    private var missCount: Int = 0

    public init(maxCacheSize: Int = 500) {
        self.maxCacheSize = maxCacheSize
    }

    /// Validate cache for a new frame
    /// Returns true if cache was invalidated (full OCR needed)
    public func validateForFrame(
        width: Int,
        height: Int,
        appBundleID: String?
    ) -> Bool {
        var invalidated = false

        // Invalidate on resolution change
        if width != currentWidth || height != currentHeight {
            invalidateAll()
            currentWidth = width
            currentHeight = height
            invalidated = true
        }

        // Invalidate on app switch (different UI = different text positions)
        if appBundleID != currentAppBundleID {
            invalidateAll()
            currentAppBundleID = appBundleID
            invalidated = true
        }

        return invalidated
    }

    /// Get cached OCR for a tile
    /// Returns nil if not cached
    public func get(tile: TileInfo) -> CachedTileOCR? {
        let key = tile.cacheKey

        guard let cached = cache[key] else {
            missCount += 1
            return nil
        }

        // Update access order (move to end for LRU)
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
            accessOrder.append(key)
        }

        hitCount += 1
        return cached
    }

    /// Store OCR result for a tile
    public func set(tile: TileInfo, regions: [TextRegion]) {
        let key = tile.cacheKey

        // Evict if needed
        evictIfNeeded()

        // Remove old entry if exists
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }

        // Add new entry
        cache[key] = CachedTileOCR(tile: tile, regions: regions)
        accessOrder.append(key)
    }

    /// Get cached results for multiple tiles
    /// Returns dictionary of tile -> regions (only for tiles that were cached)
    public func getMultiple(tiles: [TileInfo]) -> [String: [TextRegion]] {
        var results: [String: [TextRegion]] = [:]

        for tile in tiles {
            if let cached = get(tile: tile) {
                results[tile.cacheKey] = cached.regions
            }
        }

        return results
    }

    /// Store results for multiple tiles
    public func setMultiple(results: [(TileInfo, [TextRegion])]) {
        for (tile, regions) in results {
            set(tile: tile, regions: regions)
        }
    }

    /// Invalidate entire cache
    public func invalidateAll() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// Get cache statistics
    public func getStats() -> (hits: Int, misses: Int, size: Int, hitRate: Double) {
        let total = hitCount + missCount
        let hitRate = total > 0 ? Double(hitCount) / Double(total) : 0.0
        return (hitCount, missCount, cache.count, hitRate)
    }

    /// Reset statistics
    public func resetStats() {
        hitCount = 0
        missCount = 0
    }

    /// LRU eviction when cache is full
    private func evictIfNeeded() {
        while cache.count >= maxCacheSize {
            if let oldest = accessOrder.first {
                accessOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            } else {
                break
            }
        }
    }
}
