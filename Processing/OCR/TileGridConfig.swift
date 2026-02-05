import Foundation

/// Configuration for tile-based change detection and region-based OCR
public struct TileGridConfig: Sendable {
    /// Tile size in pixels (128x128 is a good balance between granularity and overhead)
    public let tileSize: Int

    /// Minimum fraction of pixels that must differ (0-1) to consider a tile "changed"
    /// 0.02 = 2% of sampled pixels must differ
    public let changeThreshold: Double

    /// Per-pixel color difference threshold (0-255)
    /// 13 ≈ 5% of 255, matching FrameDeduplicator tolerance
    public let pixelDifferenceThreshold: Int

    /// Sampling stride within tiles (2 = check every other pixel for speed)
    public let samplingStride: Int

    public init(
        tileSize: Int = 64,  // Smaller tiles = finer granularity for change detection
        changeThreshold: Double = 0.02,
        pixelDifferenceThreshold: Int = 13,
        samplingStride: Int = 2
    ) {
        self.tileSize = tileSize
        self.changeThreshold = changeThreshold
        self.pixelDifferenceThreshold = pixelDifferenceThreshold
        self.samplingStride = samplingStride
    }

    public static let `default` = TileGridConfig()
}
