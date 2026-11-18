import CoreGraphics

/// Returns no frame if any part of the required masking fails. Coordinates use image top-left origin.
enum ExcludedWindowMasker {
    static func makeContext(_ image: CGImage) -> CGContext? {
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func mask(
        _ image: CGImage, regions: [CGRect], blur: (CGImage) -> CGImage?,
        contextFactory: (CGImage) -> CGContext? = makeContext,
        imageFactory: (CGContext) -> CGImage? = { $0.makeImage() }
    ) -> CGImage? {
        guard !regions.isEmpty else { return image }
        guard let context = contextFactory(image), let blurred = blur(image) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        for region in regions {
            guard region.minX.isFinite, region.minY.isFinite, region.width.isFinite, region.height.isFinite,
                  region.width > 0, region.height > 0 else { return nil }
            let flipped = CGRect(x: region.minX, y: CGFloat(image.height) - region.maxY,
                                 width: region.width, height: region.height)
            context.saveGState()
            context.clip(to: flipped.integral)
            context.draw(blurred, in: bounds)
            context.restoreGState()
        }
        return imageFactory(context)
    }
}
