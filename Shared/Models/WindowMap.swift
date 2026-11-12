import CoreGraphics
import Foundation

/// One on-screen window as it was stacked at the moment a frame was captured.
///
/// The window map records every window that contributed pixels to a frame, front to
/// back. Processing uses it to group OCR text by window, so text from side-by-side or
/// overlapping windows is not interleaved, and to tell which app owns a piece of text.
public struct CapturedWindow: Codable, Sendable, Equatable {
    /// CoreGraphics window number (`kCGWindowNumber`). Only stable while the window lives.
    public let windowID: UInt32

    /// Stacking position within the frame; 0 is the frontmost window.
    public let zOrder: Int

    /// Bundle identifier of the owning app, when it could be resolved.
    public let bundleID: String?

    /// Display name of the owning app (`kCGWindowOwnerName` or the app's localized name).
    public let appName: String?

    /// Window title. Nil when unavailable, or when the window was redacted.
    public let title: String?

    /// Window bounds in frame pixel coordinates (top-left origin), clipped to the frame.
    public let bounds: CGRect

    /// CoreGraphics window layer (0 for normal app windows; menu bar, panels and
    /// overlays use other layers).
    public let layer: Int

    /// True for the focused window of the frontmost app.
    public let isFocused: Bool

    public init(
        windowID: UInt32,
        zOrder: Int,
        bundleID: String?,
        appName: String?,
        title: String?,
        bounds: CGRect,
        layer: Int,
        isFocused: Bool
    ) {
        self.windowID = windowID
        self.zOrder = zOrder
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.bounds = bounds
        self.layer = layer
        self.isFocused = isFocused
    }
}

public enum WindowMap {
    /// Index of the frontmost window in `windows` (assumed sorted front to back) that
    /// contains `point`, or nil when no window covers it.
    public static func windowIndex(at point: CGPoint, in windows: [CapturedWindow]) -> Int? {
        windows.firstIndex { $0.bounds.contains(point) }
    }

    /// Index of the window that owns a text region: the frontmost window containing the
    /// region's center. Using the center keeps a region that straddles a window edge with
    /// the window it mostly sits in.
    public static func owningWindowIndex(for region: CGRect, in windows: [CapturedWindow]) -> Int? {
        windowIndex(at: CGPoint(x: region.midX, y: region.midY), in: windows)
    }
}
