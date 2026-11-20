import Foundation
import Vision
import CoreGraphics
import Shared

struct VisionRecognitionOutput {
    let regions: [TextRegion]
    let attributedBytes: Int64
}

struct EnvelopeRecognitionOutput {
    let regions: [TextRegion]
    let blindResidualClaim: MemoryLedger.ResidualClaim?
}

extension VisionOCR {
    static func recognitionLevel(for config: ProcessingConfig) -> VNRequestTextRecognitionLevel {
        switch config.ocrAccuracyLevel {
        case .fast:
            return .fast
        case .accurate:
            return .accurate
        }
    }

    func boundsOverlapSignificantly(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        if intersection.isNull || intersection.isEmpty {
            return false
        }

        let intersectionArea = intersection.width * intersection.height
        let smallerArea = min(a.width * a.height, b.width * b.height)

        guard smallerArea > 0 else { return false }
        return intersectionArea / smallerArea > 0.3
    }

    func calculateBoundingBox(for tiles: [TileInfo]) -> CGRect {
        guard !tiles.isEmpty else { return .zero }

        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = CGFloat.zero
        var maxY = CGFloat.zero

        for tile in tiles {
            minX = min(minX, tile.pixelBounds.minX)
            minY = min(minY, tile.pixelBounds.minY)
            maxX = max(maxX, tile.pixelBounds.maxX)
            maxY = max(maxY, tile.pixelBounds.maxY)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func expandReOCRTiles(
        changedTiles: [TileInfo],
        affectedRegions: [TextRegion],
        frameWidth: Int,
        frameHeight: Int,
        changeDetector: TileChangeDetector
    ) -> [TileInfo] {
        guard !affectedRegions.isEmpty else { return changedTiles }

        var tilesByKey: [String: TileInfo] = Dictionary(
            uniqueKeysWithValues: changedTiles.map { ($0.cacheKey, $0) }
        )

        for tile in changeDetector.createTileGrid(frameWidth: frameWidth, frameHeight: frameHeight) {
            guard tilesByKey[tile.cacheKey] == nil else { continue }
            if affectedRegions.contains(where: { $0.bounds.intersects(tile.pixelBounds) }) {
                tilesByKey[tile.cacheKey] = tile
            }
        }

        return Array(tilesByKey.values)
    }

    func createCGImage(from data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
