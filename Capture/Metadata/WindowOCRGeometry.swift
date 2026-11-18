import CoreGraphics
import Foundation

/// One crop per meaningfully visible application window, in front-to-back order.
/// Geometry only. Covered pixels are masked by Processing, not split into OCR jobs.
enum WindowOCRGeometry {
    static let maximumRegions = 16

    static func normalizedRegions(
        windows: [[String: Any]], displayBounds: CGRect, imageSize: CGSize,
        excludedWindowIDs: Set<CGWindowID>, ignoredWindowIDs: Set<CGWindowID> = []
    ) -> [CGRect]? {
        guard displayBounds.width > 0, displayBounds.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let screen = CGRect(origin: .zero, size: imageSize)
        var covered: [CGRect] = []
        var selected: [CGRect] = []
        for window in windows {
            guard (window[kCGWindowIsOnscreen as String] as? Bool) != false,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let dict = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
                  bounds.width > 0, bounds.height > 0 else { continue }
            let excluded = excludedWindowIDs.contains(id)
            guard excluded || !ignoredWindowIDs.contains(id) else { continue }
            // Status items, menus, tooltips and system overlays are not application
            // windows. Their composited pixels stay with the underlying application.
            guard excluded || (window[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            let left = ((bounds.minX - displayBounds.minX) * imageSize.width / displayBounds.width).rounded()
            let top = ((bounds.minY - displayBounds.minY) * imageSize.height / displayBounds.height).rounded()
            let right = ((bounds.maxX - displayBounds.minX) * imageSize.width / displayBounds.width).rounded()
            let bottom = ((bounds.maxY - displayBounds.minY) * imageSize.height / displayBounds.height).rounded()
            let pixels = CGRect(x: left, y: top, width: right - left, height: bottom - top).intersection(screen)
            guard !pixels.isEmpty, !pixels.isNull else { continue }
            var visible = [pixels]
            for front in covered {
                visible = visible.flatMap { subtract(front, from: $0) }
                if visible.isEmpty { break }
                guard visible.count <= 256 else { return nil }
            }
            let exposedArea = visible.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
            let significant = exposedArea >= pixels.width * pixels.height * 0.01 &&
                visible.contains { $0.width >= 4 && $0.height >= 4 }
            if !excluded, bounds.width >= 32, bounds.height >= 32, significant {
                selected.append(pixels)
                guard selected.count <= maximumRegions else { return nil }
                covered.append(pixels)
            } else if excluded {
                // These pixels are already removed by capture's privacy masking.
                covered.append(pixels)
            }
            // Fully covered windows and tiny slivers create neither crops nor new
            // boundaries. Never create extra jobs for the uncovered desktop.
        }
        return selected.map { CGRect(x: $0.minX / imageSize.width, y: $0.minY / imageSize.height,
                                     width: $0.width / imageSize.width, height: $0.height / imageSize.height) }
    }

    private static func subtract(_ cut: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(cut)
        guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
        return [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
            CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
            CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
            CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)
        ].filter { !$0.isEmpty }
    }
}
