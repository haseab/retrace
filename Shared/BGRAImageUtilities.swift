import CoreGraphics
import Foundation

public enum BGRAImageUtilitiesError: Error, Sendable {
    case bitmapContextCreationFailed
}

public struct BGRAPatch: Sendable, Equatable {
    public var data: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(data: Data, width: Int, height: Int, bytesPerRow: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }
}

public enum BGRAImageUtilities {
    public static func makeData(from image: CGImage) throws -> Data {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )

        let drawResult = data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drawResult else {
            throw BGRAImageUtilitiesError.bitmapContextCreationFailed
        }
        return data
    }

    public static func pixelRect(
        from normalizedRect: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }

        let minXNorm = max(0, min(1, normalizedRect.minX))
        let minYNorm = max(0, min(1, normalizedRect.minY))
        let maxXNorm = max(minXNorm, min(1, normalizedRect.maxX))
        let maxYNorm = max(minYNorm, min(1, normalizedRect.maxY))

        let minX = max(0, min(imageWidth, Int(floor(minXNorm * CGFloat(imageWidth)))))
        let minY = max(0, min(imageHeight, Int(floor(minYNorm * CGFloat(imageHeight)))))
        let maxX = max(minX, min(imageWidth, Int(ceil(maxXNorm * CGFloat(imageWidth)))))
        let maxY = max(minY, min(imageHeight, Int(ceil(maxYNorm * CGFloat(imageHeight)))))

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    public static func extractPatch(
        from frameData: Data,
        frameBytesPerRow: Int,
        rect: CGRect
    ) -> BGRAPatch? {
        let patchWidth = Int(rect.width)
        let patchHeight = Int(rect.height)
        guard patchWidth > 0, patchHeight > 0 else { return nil }

        let originX = Int(rect.origin.x)
        let originY = Int(rect.origin.y)
        let patchBytesPerRow = patchWidth * 4
        var patch = Data(count: patchBytesPerRow * patchHeight)

        frameData.withUnsafeBytes { frameRaw in
            patch.withUnsafeMutableBytes { patchRaw in
                guard let frameBase = frameRaw.baseAddress,
                      let patchBase = patchRaw.baseAddress else {
                    return
                }

                for row in 0..<patchHeight {
                    let srcOffset = (originY + row) * frameBytesPerRow + (originX * 4)
                    let dstOffset = row * patchBytesPerRow
                    memcpy(
                        patchBase.advanced(by: dstOffset),
                        frameBase.advanced(by: srcOffset),
                        patchBytesPerRow
                    )
                }
            }
        }

        return BGRAPatch(
            data: patch,
            width: patchWidth,
            height: patchHeight,
            bytesPerRow: patchBytesPerRow
        )
    }

    public static func writePatch(
        _ patch: BGRAPatch,
        into frameData: inout Data,
        frameBytesPerRow: Int,
        rect: CGRect
    ) {
        let patchHeight = Int(rect.height)
        guard patchHeight > 0 else { return }

        let originX = Int(rect.origin.x)
        let originY = Int(rect.origin.y)

        patch.data.withUnsafeBytes { patchRaw in
            frameData.withUnsafeMutableBytes { frameRaw in
                guard let patchBase = patchRaw.baseAddress,
                      let frameBase = frameRaw.baseAddress else {
                    return
                }

                for row in 0..<patchHeight {
                    let srcOffset = row * patch.bytesPerRow
                    let dstOffset = (originY + row) * frameBytesPerRow + (originX * 4)
                    memcpy(
                        frameBase.advanced(by: dstOffset),
                        patchBase.advanced(by: srcOffset),
                        patch.bytesPerRow
                    )
                }
            }
        }
    }
}
