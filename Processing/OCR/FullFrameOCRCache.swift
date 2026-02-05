import Foundation
import CoreGraphics
import Shared

/// Cache for full-frame OCR results with paragraph-level bounding boxes
/// This cache stores regions from full-frame OCR and allows incremental updates
/// when only parts of the screen change.
public actor FullFrameOCRCache {

    /// Cached OCR regions from the last processed frame
    private var cachedRegions: [TextRegion] = []

    /// Tile grid from the last processed frame (for change detection mapping)
    private var cachedTileGrid: [TileInfo] = []

    /// Current frame dimensions (cache invalidated on change)
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0

    /// Current app bundle ID (cache invalidated on change)
    private var currentAppBundleID: String?

    /// Statistics
    private var hitCount: Int = 0
    private var missCount: Int = 0

    public init() {}

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

    /// Check if we have cached regions
    public func hasCachedRegions() -> Bool {
        return !cachedRegions.isEmpty
    }

    /// Get all cached regions
    public func getCachedRegions() -> [TextRegion] {
        return cachedRegions
    }

    /// Get cached tile grid
    public func getCachedTileGrid() -> [TileInfo] {
        return cachedTileGrid
    }

    /// Store full-frame OCR results
    public func setFullFrameResults(regions: [TextRegion], tileGrid: [TileInfo]) {
        cachedRegions = regions
        cachedTileGrid = tileGrid
        hitCount += 1
    }

    /// Find regions that intersect with any of the given changed tiles
    /// Returns (affectedRegions, unaffectedRegions)
    public func findAffectedRegions(changedTiles: [TileInfo]) -> (affected: [TextRegion], unaffected: [TextRegion]) {
        var affected: [TextRegion] = []
        var unaffected: [TextRegion] = []

        // Create a set of changed tile coordinates for fast lookup
        let changedTileSet = Set(changedTiles.map { "\($0.col)_\($0.row)" })

        for region in cachedRegions {
            // Check if this region intersects any changed tile
            let regionIntersectsChanged = cachedTileGrid.contains { tile in
                // Only check changed tiles
                guard changedTileSet.contains(tile.cacheKey) else { return false }
                // Check if region bounds intersect this tile's pixel bounds
                return region.bounds.intersects(tile.pixelBounds)
            }

            if regionIntersectsChanged {
                affected.append(region)
            } else {
                unaffected.append(region)
            }
        }

        missCount += affected.count
        hitCount += unaffected.count

        return (affected, unaffected)
    }

    /// Update cache with new OCR results for specific regions
    /// Replaces affected regions with new results
    public func updateWithNewResults(
        unaffectedRegions: [TextRegion],
        newRegions: [TextRegion]
    ) {
        // Combine unaffected cached regions with new OCR results
        cachedRegions = unaffectedRegions + newRegions
    }

    /// Invalidate entire cache
    public func invalidateAll() {
        cachedRegions = []
        cachedTileGrid = []
    }

    /// Get cache statistics
    public func getStats() -> (hits: Int, misses: Int, regionCount: Int, hitRate: Double) {
        let total = hitCount + missCount
        let hitRate = total > 0 ? Double(hitCount) / Double(total) : 0.0
        return (hitCount, missCount, cachedRegions.count, hitRate)
    }

    /// Reset statistics
    public func resetStats() {
        hitCount = 0
        missCount = 0
    }
}
