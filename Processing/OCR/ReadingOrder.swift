import CoreGraphics
import Foundation
import Shared

/// Puts OCR regions in reading order using the frame's window map and page layout.
///
/// Sorting every region on screen top-to-bottom interleaves unrelated text: a sidebar
/// row lands between two lines of the paragraph beside it, and text from overlapping
/// windows mixes. Instead:
/// 1. Each region is assigned to the frontmost window containing its center.
/// 2. Windows are read front to back; regions outside every window come last.
/// 3. Within a window, regions are split into blocks with a recursive XY-cut
///    (columns at wide vertical gutters, sections at tall horizontal gaps), and blocks
///    are read left-to-right / top-to-bottom.
/// 4. Within a block, lines are read top-to-bottom, left-to-right.
public enum ReadingOrder {

    public struct OrderedRegion: Equatable {
        public let region: TextRegion
        /// Index into the window map (equal to the window's zOrder), or nil.
        public let windowIndex: Int?
    }

    /// A vertical gutter must be at least this many median line heights wide to split
    /// a block into columns.
    static let columnGapLineHeights: CGFloat = 2.0

    /// A horizontal gap must be at least this many median line heights tall to split a
    /// block into stacked sections.
    static let sectionGapLineHeights: CGFloat = 1.2

    /// Lines whose top edges are within this many median line heights share a row.
    static let sameRowLineHeights: CGFloat = 0.5

    public static func order(_ regions: [TextRegion], windows: [CapturedWindow]) -> [OrderedRegion] {
        guard !regions.isEmpty else { return [] }

        let lineHeight = medianHeight(of: regions)
        var groups: [Int?: [TextRegion]] = [:]
        for region in regions {
            let index = windows.isEmpty ? nil : WindowMap.owningWindowIndex(for: region.bounds, in: windows)
            groups[index, default: []].append(region)
        }

        let windowOrder: [Int?] = groups.keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            default: return false
            }
        }

        var result: [OrderedRegion] = []
        result.reserveCapacity(regions.count)
        for windowIndex in windowOrder {
            let ordered = xyCut(groups[windowIndex] ?? [], lineHeight: lineHeight)
            result.append(contentsOf: ordered.map { OrderedRegion(region: $0, windowIndex: windowIndex) })
        }
        return result
    }

    // MARK: - XY-cut

    static func xyCut(_ regions: [TextRegion], lineHeight: CGFloat) -> [TextRegion] {
        guard regions.count > 1 else { return regions }

        let column = widestGap(in: regions.map { ($0.bounds.minX, $0.bounds.maxX) })
        let section = widestGap(in: regions.map { ($0.bounds.minY, $0.bounds.maxY) })
        let columnScore = column.map { $0.width / (lineHeight * columnGapLineHeights) } ?? 0
        let sectionScore = section.map { $0.width / (lineHeight * sectionGapLineHeights) } ?? 0

        if columnScore >= 1, columnScore >= sectionScore, let cut = column?.position {
            let left = regions.filter { $0.bounds.midX < cut }
            let right = regions.filter { $0.bounds.midX >= cut }
            if !left.isEmpty, !right.isEmpty {
                return xyCut(left, lineHeight: lineHeight) + xyCut(right, lineHeight: lineHeight)
            }
        }

        if sectionScore >= 1, let cut = section?.position {
            let top = regions.filter { $0.bounds.midY < cut }
            let bottom = regions.filter { $0.bounds.midY >= cut }
            if !top.isEmpty, !bottom.isEmpty {
                return xyCut(top, lineHeight: lineHeight) + xyCut(bottom, lineHeight: lineHeight)
            }
        }

        return sortedByRows(regions, lineHeight: lineHeight)
    }

    /// Widest empty interval between the union of `intervals` (projected onto one axis),
    /// with the cut position at its middle. Nil when the intervals leave no gap.
    static func widestGap(in intervals: [(CGFloat, CGFloat)]) -> (width: CGFloat, position: CGFloat)? {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        guard var reach = sorted.first?.1 else { return nil }

        var best: (width: CGFloat, position: CGFloat)?
        for (start, end) in sorted.dropFirst() {
            if start > reach {
                let width = start - reach
                if width > (best?.width ?? 0) {
                    best = (width, reach + width / 2)
                }
            }
            reach = max(reach, end)
        }
        return best
    }

    static func sortedByRows(_ regions: [TextRegion], lineHeight: CGFloat) -> [TextRegion] {
        let tolerance = max(lineHeight * sameRowLineHeights, 1)
        let byTop = regions.sorted {
            $0.bounds.minY == $1.bounds.minY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.minY < $1.bounds.minY
        }

        var rows: [[TextRegion]] = []
        var rowTop: CGFloat = -.greatestFiniteMagnitude
        for region in byTop {
            if region.bounds.minY - rowTop <= tolerance, !rows.isEmpty {
                rows[rows.count - 1].append(region)
            } else {
                rows.append([region])
                rowTop = region.bounds.minY
            }
        }
        return rows.flatMap { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    }

    static func medianHeight(of regions: [TextRegion]) -> CGFloat {
        let heights = regions.map(\.bounds.height).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return 1 }
        return max(heights[heights.count / 2], 1)
    }
}
