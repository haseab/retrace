import Foundation
import CoreGraphics
import Shared

/// Represents a single tile's position in the grid
public struct TileInfo: Sendable, Hashable {
    /// Column index (0-based from left)
    public let col: Int
    /// Row index (0-based from top)
    public let row: Int
    /// Pixel bounds in the original frame (origin at top-left)
    public let pixelBounds: CGRect
    /// Normalized bounds (0-1) for Vision regionOfInterest
    public let normalizedBounds: CGRect

    public init(col: Int, row: Int, pixelBounds: CGRect, normalizedBounds: CGRect) {
        self.col = col
        self.row = row
        self.pixelBounds = pixelBounds
        self.normalizedBounds = normalizedBounds
    }

    /// Unique key for cache lookups
    public var cacheKey: String {
        "\(col)_\(row)"
    }
}

/// Result of comparing tiles between two frames
public struct TileChangeResult: Sendable {
    /// Tiles that changed and need OCR
    public let changedTiles: [TileInfo]
    /// Tiles that are unchanged (can reuse cached OCR)
    public let unchangedTiles: [TileInfo]
    /// Total number of tiles in the grid
    public let totalTiles: Int
    /// Time spent on change detection (ms)
    public let detectionTimeMs: Double

    /// Fraction of screen that changed (0-1)
    public var changeRatio: Double {
        guard totalTiles > 0 else { return 1.0 }
        return Double(changedTiles.count) / Double(totalTiles)
    }
}

/// Detects which tiles changed between consecutive frames
public struct TileChangeDetector: Sendable {
    private let config: TileGridConfig

    public init(config: TileGridConfig = .default) {
        self.config = config
    }

    /// Compare two frames and identify changed tiles
    /// - Parameters:
    ///   - current: The current frame to analyze
    ///   - previous: The previous frame to compare against (nil = all tiles changed)
    /// - Returns: TileChangeResult, or nil if dimensions differ (requires full OCR)
    public func detectChanges(
        current: CapturedFrame,
        previous: CapturedFrame?
    ) -> TileChangeResult? {
        let startTime = Date()

        // If no previous frame, all tiles are "changed"
        guard let previous = previous else {
            let allTiles = createTileGrid(
                frameWidth: current.width,
                frameHeight: current.height
            )
            return TileChangeResult(
                changedTiles: allTiles,
                unchangedTiles: [],
                totalTiles: allTiles.count,
                detectionTimeMs: Date().timeIntervalSince(startTime) * 1000
            )
        }

        // If dimensions changed, signal full OCR needed
        guard current.width == previous.width,
              current.height == previous.height else {
            return nil
        }

        // Calculate tile grid
        let cols = (current.width + config.tileSize - 1) / config.tileSize
        let rows = (current.height + config.tileSize - 1) / config.tileSize

        var changedTiles: [TileInfo] = []
        var unchangedTiles: [TileInfo] = []

        // Compare each tile
        current.imageData.withUnsafeBytes { currentBytes in
            previous.imageData.withUnsafeBytes { previousBytes in
                guard let currentBase = currentBytes.baseAddress,
                      let previousBase = previousBytes.baseAddress else { return }

                let currentPixels = currentBase.assumingMemoryBound(to: UInt8.self)
                let previousPixels = previousBase.assumingMemoryBound(to: UInt8.self)

                for row in 0..<rows {
                    for col in 0..<cols {
                        let tile = createTileInfo(
                            row: row,
                            col: col,
                            frameWidth: current.width,
                            frameHeight: current.height
                        )

                        let changed = isTileChanged(
                            tile: tile,
                            currentPixels: currentPixels,
                            previousPixels: previousPixels,
                            bytesPerRow: current.bytesPerRow
                        )

                        if changed {
                            changedTiles.append(tile)
                        } else {
                            unchangedTiles.append(tile)
                        }
                    }
                }
            }
        }

        return TileChangeResult(
            changedTiles: changedTiles,
            unchangedTiles: unchangedTiles,
            totalTiles: cols * rows,
            detectionTimeMs: Date().timeIntervalSince(startTime) * 1000
        )
    }

    /// Create a grid of all tiles for a frame
    public func createTileGrid(frameWidth: Int, frameHeight: Int) -> [TileInfo] {
        let cols = (frameWidth + config.tileSize - 1) / config.tileSize
        let rows = (frameHeight + config.tileSize - 1) / config.tileSize

        var tiles: [TileInfo] = []
        tiles.reserveCapacity(cols * rows)

        for row in 0..<rows {
            for col in 0..<cols {
                tiles.append(createTileInfo(
                    row: row,
                    col: col,
                    frameWidth: frameWidth,
                    frameHeight: frameHeight
                ))
            }
        }

        return tiles
    }

    /// Create TileInfo for a specific grid position
    private func createTileInfo(row: Int, col: Int, frameWidth: Int, frameHeight: Int) -> TileInfo {
        let startX = col * config.tileSize
        let startY = row * config.tileSize
        let endX = min(startX + config.tileSize, frameWidth)
        let endY = min(startY + config.tileSize, frameHeight)

        let pixelBounds = CGRect(
            x: CGFloat(startX),
            y: CGFloat(startY),
            width: CGFloat(endX - startX),
            height: CGFloat(endY - startY)
        )

        // Normalized bounds for Vision regionOfInterest (0-1 range)
        // Vision uses bottom-left origin, so we flip Y
        let normalizedX = CGFloat(startX) / CGFloat(frameWidth)
        let normalizedWidth = CGFloat(endX - startX) / CGFloat(frameWidth)
        let normalizedHeight = CGFloat(endY - startY) / CGFloat(frameHeight)
        // Flip Y: Vision y=0 at bottom, our y=0 at top
        let normalizedY = 1.0 - (CGFloat(endY) / CGFloat(frameHeight))

        let normalizedBounds = CGRect(
            x: normalizedX,
            y: normalizedY,
            width: normalizedWidth,
            height: normalizedHeight
        )

        return TileInfo(
            col: col,
            row: row,
            pixelBounds: pixelBounds,
            normalizedBounds: normalizedBounds
        )
    }

    /// Check if a single tile has changed between frames
    private func isTileChanged(
        tile: TileInfo,
        currentPixels: UnsafePointer<UInt8>,
        previousPixels: UnsafePointer<UInt8>,
        bytesPerRow: Int
    ) -> Bool {
        let startX = Int(tile.pixelBounds.origin.x)
        let startY = Int(tile.pixelBounds.origin.y)
        let endX = Int(tile.pixelBounds.maxX)
        let endY = Int(tile.pixelBounds.maxY)

        // Calculate how many pixels we'll sample
        let sampledWidth = (endX - startX + config.samplingStride - 1) / config.samplingStride
        let sampledHeight = (endY - startY + config.samplingStride - 1) / config.samplingStride
        let totalSamples = sampledWidth * sampledHeight
        let changeThresholdCount = Int(Double(totalSamples) * config.changeThreshold)

        var changedPixels = 0

        // Sample pixels with stride for speed
        for y in stride(from: startY, to: endY, by: config.samplingStride) {
            for x in stride(from: startX, to: endX, by: config.samplingStride) {
                let offset = y * bytesPerRow + x * 4

                // BGRA format
                let bDiff = abs(Int(currentPixels[offset]) - Int(previousPixels[offset]))
                let gDiff = abs(Int(currentPixels[offset + 1]) - Int(previousPixels[offset + 1]))
                let rDiff = abs(Int(currentPixels[offset + 2]) - Int(previousPixels[offset + 2]))

                // Pixel is different if any channel exceeds threshold
                if bDiff > config.pixelDifferenceThreshold ||
                   gDiff > config.pixelDifferenceThreshold ||
                   rDiff > config.pixelDifferenceThreshold {
                    changedPixels += 1

                    // Early exit once we've confirmed the tile changed
                    if changedPixels > changeThresholdCount {
                        return true
                    }
                }
            }
        }

        return changedPixels > changeThresholdCount
    }
}
