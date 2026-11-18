import CoreGraphics
import Foundation
import Shared

struct ConferenceWindowImageSnapshot: Sendable {
    let image: CGImage
    let bounds: CGRect
    let ownerPID: pid_t

    func hasSameContent(as other: Self) -> Bool {
        guard bounds == other.bounds, ownerPID == other.ownerPID else { return false }
        let metadata = FrameMetadata(displayID: 0)
        return CaptureFrameCandidate(image: image, timestamp: .distantPast, metadata: metadata)
            .hasIdenticalPixels(to: CaptureFrameCandidate(image: other.image, timestamp: .distantPast, metadata: metadata))
    }
}

/// Source pixels must come from the matched window, not an overlapping desktop ROI.
protocol ConferenceWindowImageProviding: Sendable {
    func snapshot(for windowID: CGWindowID) -> ConferenceWindowImageSnapshot?
}

struct ConferenceWindowImageProvider: ConferenceWindowImageProviding {
    func snapshot(for windowID: CGWindowID) -> ConferenceWindowImageSnapshot? {
        guard let before = Self.windowMetadata(windowID),
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                                 [.boundsIgnoreFraming, .bestResolution]),
              let after = Self.windowMetadata(windowID),
              before.bounds == after.bounds, before.pid == after.pid else { return nil }
        return ConferenceWindowImageSnapshot(image: image, bounds: after.bounds, ownerPID: after.pid)
    }

    private static func windowMetadata(_ windowID: CGWindowID) -> (bounds: CGRect, pid: pid_t)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let window = windows.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }),
              let pid = window[kCGWindowOwnerPID as String] as? pid_t,
              let rawBounds = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else { return nil }
        return (bounds, pid)
    }

    /// Quartz can return transparent black when a window cannot be read.
    /// Reject transparent samples conservatively: a sparse transparent window
    /// may use the desktop fallback, but an unreadable source cannot disable blur.
    static func isReadable(_ image: CGImage) -> Bool {
        guard image.width > 1, image.height > 1,
              let sample = CGContext(data: nil, width: 1, height: 1,
                  bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return false }
        sample.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (sample.data?.assumingMemoryBound(to: UInt8.self)[3] ?? 0) > 0
    }
}

/// Window coordinates are in desktop points (top-left origin); mask coordinates
/// are in source-image pixels (bottom-left origin). Display images may be Retina.
enum ConferenceWindowMaskProjection {
    static func project(
        _ rects: [CGRect], sourceWidth: Int, sourceHeight: Int,
        windowBounds: CGRect, displayBounds: CGRect,
        imageWidth: Int, imageHeight: Int
    ) -> [CGRect] {
        guard sourceWidth > 0, sourceHeight > 0, imageWidth > 0, imageHeight > 0,
              displayBounds.width > 0, displayBounds.height > 0,
              windowBounds.width > 0, windowBounds.height > 0 else { return [] }
        let scaleX = CGFloat(imageWidth) / displayBounds.width
        let scaleY = CGFloat(imageHeight) / displayBounds.height
        let originX = (windowBounds.minX - displayBounds.minX) * scaleX
        let originY = (displayBounds.maxY - windowBounds.maxY) * scaleY
        let windowScaleX = windowBounds.width * scaleX / CGFloat(sourceWidth)
        let windowScaleY = windowBounds.height * scaleY / CGFloat(sourceHeight)
        let canvas = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        return rects.compactMap { rect in
            let projected = CGRect(x: originX + rect.minX * windowScaleX,
                                   y: originY + rect.minY * windowScaleY,
                                   width: rect.width * windowScaleX,
                                   height: rect.height * windowScaleY)
            // Keep the complete ellipse geometry. The rendering context clips
            // it to the canvas; clipping its bounds first would reshape the mask.
            return projected.intersects(canvas) ? projected : nil
        }
    }
}
