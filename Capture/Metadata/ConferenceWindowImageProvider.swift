import CoreGraphics

/// Source pixels must come from the matched window, not an overlapping desktop ROI.
protocol ConferenceWindowImageProviding: Sendable {
    func image(for windowID: CGWindowID) -> CGImage?
}

struct ConferenceWindowImageProvider: ConferenceWindowImageProviding {
    func image(for windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                               [.boundsIgnoreFraming, .bestResolution])
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
