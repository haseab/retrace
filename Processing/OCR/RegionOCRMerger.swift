import Foundation
import CoreGraphics
import Shared

/// Merges OCR results from cached tiles and newly processed tiles
/// into a single array of TextRegions for the full frame
public struct RegionOCRMerger: Sendable {

    public init() {}

    /// Merge cached and new OCR results into a unified list
    /// - Parameters:
    ///   - cachedResults: Results from cache (tile cacheKey -> regions)
    ///   - newResults: Results from fresh OCR (tile cacheKey -> regions)
    /// - Returns: Merged, sorted, and deduplicated TextRegions
    public func merge(
        cachedResults: [String: [TextRegion]],
        newResults: [String: [TextRegion]]
    ) -> [TextRegion] {
        var allRegions: [TextRegion] = []

        // Collect all regions from cached tiles
        for (_, regions) in cachedResults {
            allRegions.append(contentsOf: regions)
        }

        // Collect all regions from newly OCR'd tiles
        for (_, regions) in newResults {
            allRegions.append(contentsOf: regions)
        }

        // Sort by reading order: top-to-bottom, then left-to-right
        // Group regions into approximate rows (within 20px of each other)
        allRegions.sort { a, b in
            // If on approximately the same line (within tolerance), sort by X
            if abs(a.bounds.origin.y - b.bounds.origin.y) < 20 {
                return a.bounds.origin.x < b.bounds.origin.x
            }
            // Otherwise sort by Y (top to bottom)
            return a.bounds.origin.y < b.bounds.origin.y
        }

        // Deduplicate overlapping regions (can happen at tile boundaries)
        return deduplicateOverlapping(allRegions)
    }

    /// Remove duplicate text regions that overlap significantly
    /// Text can span tile boundaries and be detected in both adjacent tiles
    private func deduplicateOverlapping(_ regions: [TextRegion]) -> [TextRegion] {
        guard !regions.isEmpty else { return [] }

        var result: [TextRegion] = []

        for region in regions {
            let isDuplicate = result.contains { existing in
                // Check if text is identical and bounds overlap significantly
                existing.text == region.text && boundsOverlapSignificantly(existing.bounds, region.bounds)
            }

            if !isDuplicate {
                result.append(region)
            }
        }

        return result
    }

    /// Check if two rectangles overlap by more than 50%
    private func boundsOverlapSignificantly(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        if intersection.isNull || intersection.isEmpty {
            return false
        }

        let intersectionArea = intersection.width * intersection.height
        let smallerArea = min(a.width * a.height, b.width * b.height)

        guard smallerArea > 0 else { return false }

        return intersectionArea / smallerArea > 0.5
    }
}
