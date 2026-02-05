import Foundation
import Shared

/// Statistics for region-based OCR processing
public struct RegionOCRStats: Sendable {
    /// Number of tiles that needed fresh OCR
    public let tilesOCRed: Int
    /// Number of tiles reused from cache
    public let tilesCached: Int
    /// Total tiles in frame
    public let totalTiles: Int
    /// Time spent on change detection (ms)
    public let changeDetectionTimeMs: Double
    /// Time spent on OCR (ms)
    public let ocrTimeMs: Double
    /// Time spent on merging results (ms)
    public let mergeTimeMs: Double

    /// Estimated energy savings compared to full-frame OCR (0-1)
    public var energySavings: Double {
        guard totalTiles > 0 else { return 0 }
        return 1.0 - (Double(tilesOCRed) / Double(totalTiles))
    }

    /// Percentage of tiles that were cached
    public var cacheHitRate: Double {
        guard totalTiles > 0 else { return 0 }
        return Double(tilesCached) / Double(totalTiles)
    }

    /// Total processing time
    public var totalTimeMs: Double {
        changeDetectionTimeMs + ocrTimeMs + mergeTimeMs
    }

    public init(
        tilesOCRed: Int,
        tilesCached: Int,
        totalTiles: Int,
        changeDetectionTimeMs: Double,
        ocrTimeMs: Double,
        mergeTimeMs: Double
    ) {
        self.tilesOCRed = tilesOCRed
        self.tilesCached = tilesCached
        self.totalTiles = totalTiles
        self.changeDetectionTimeMs = changeDetectionTimeMs
        self.ocrTimeMs = ocrTimeMs
        self.mergeTimeMs = mergeTimeMs
    }

    /// Stats for when full-frame OCR was required (no caching)
    public static func fullFrame(totalTiles: Int, ocrTimeMs: Double) -> RegionOCRStats {
        RegionOCRStats(
            tilesOCRed: totalTiles,
            tilesCached: 0,
            totalTiles: totalTiles,
            changeDetectionTimeMs: 0,
            ocrTimeMs: ocrTimeMs,
            mergeTimeMs: 0
        )
    }
}

/// Result of region-based OCR combining cached and fresh results
public struct RegionOCRResult: Sendable {
    /// All text regions (merged from cached + new OCR)
    public let regions: [TextRegion]
    /// Processing statistics
    public let stats: RegionOCRStats

    public init(regions: [TextRegion], stats: RegionOCRStats) {
        self.regions = regions
        self.stats = stats
    }
}

extension RegionOCRStats: CustomStringConvertible {
    public var description: String {
        let savings = Int(energySavings * 100)
        return "RegionOCR: \(tilesOCRed)/\(totalTiles) tiles OCR'd, \(tilesCached) cached (\(savings)% energy saved), \(String(format: "%.1f", totalTimeMs))ms total"
    }
}
