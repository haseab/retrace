import CoreGraphics
import Foundation
import Shared

/// Window bounds do not establish pixel opacity. Compare the entire AX region with
/// the captured frame before using text behind a potentially transparent overlay.
enum AccessibilityPixelVisibility {
    static func matches(captured: CGImage, window: CGImage, rect: CGRect,
                        remainingPixels: inout Int) -> Bool {
        let rect = rect.integral
        guard captured.width == window.width, captured.height == window.height,
              rect.width > 0, rect.height > 0,
              CGRect(x: 0, y: 0, width: captured.width, height: captured.height).contains(rect),
              rect.width * rect.height <= CGFloat(remainingPixels) else { return false }
        remainingPixels -= Int(rect.width * rect.height)
        guard let framePatch = captured.cropping(to: rect), let windowPatch = window.cropping(to: rect),
              let frame = try? BGRAImageUtilities.makeData(from: framePatch),
              let reference = try? BGRAImageUtilities.makeData(from: windowPatch),
              frame.count == reference.count else { return false }
        return frame.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            reference.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for i in stride(from: 0, to: a.count, by: 4) {
                    // A transparent window pixel cannot establish ownership of frame text.
                    guard a[i+3] == 255, b[i+3] == 255 else { return false }
                    for channel in 0..<3 where abs(Int(a[i+channel]) - Int(b[i+channel])) > 2 {
                        return false
                    }
                }
                return true
            }
        }
    }
}
