import AppKit
import CoreGraphics
import Foundation
import Shared

/// Builds a frame's window map: the windows that contributed pixels to a captured
/// display image, front to back, in frame pixel coordinates.
///
/// Called right after the display image is grabbed, so the map matches the pixels.
/// Windows Retrace excluded from capture are left out entirely; windows it redacted keep
/// their bounds but lose their title.
enum WindowMapProvider {

    /// The fields of one `CGWindowListCopyWindowInfo` entry that the window map uses.
    struct WindowEntry: Equatable {
        let windowID: CGWindowID
        let ownerPID: pid_t?
        let ownerName: String?
        let title: String?
        /// Global display coordinates (points, top-left origin).
        let bounds: CGRect
        let layer: Int
        let alpha: Double
    }

    /// Windows smaller than this (in frame pixels, either side) are dropped. They are
    /// mostly invisible helper windows and cannot hold readable text.
    static let minimumSideLength: CGFloat = 4

    /// Windows above the normal layer that cover at least this share of the frame are
    /// system overlays (Dock, Notification Center, screen-wide shields). They report full
    /// alpha but are mostly see-through, so they are left out of the map.
    static let fullScreenOverlayCoverage: CGFloat = 0.9

    /// Snapshot the on-screen window list and build the window map for a frame.
    static func capture(
        displayID: CGDirectDisplayID,
        frameWidth: Int,
        frameHeight: Int,
        excludedWindowIDs: Set<CGWindowID>,
        redactedWindowIDs: Set<CGWindowID>
    ) -> [CapturedWindow] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var bundleIDByPID: [pid_t: String?] = [:]
        let entries = windowList.compactMap(entry(from:))
        return build(
            entries: entries,
            displayBounds: CGDisplayBounds(displayID),
            frameSize: CGSize(width: frameWidth, height: frameHeight),
            excludedWindowIDs: excludedWindowIDs,
            redactedWindowIDs: redactedWindowIDs,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            bundleIDForPID: { pid in
                if let cached = bundleIDByPID[pid] { return cached }
                let resolved = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                bundleIDByPID[pid] = resolved
                return resolved
            }
        )
    }

    /// Pure core of `capture`: turn window-list entries (front to back) into a window map.
    static func build(
        entries: [WindowEntry],
        displayBounds: CGRect,
        frameSize: CGSize,
        excludedWindowIDs: Set<CGWindowID>,
        redactedWindowIDs: Set<CGWindowID>,
        frontmostPID: pid_t?,
        bundleIDForPID: (pid_t) -> String?
    ) -> [CapturedWindow] {
        guard displayBounds.width > 0, displayBounds.height > 0,
              frameSize.width > 0, frameSize.height > 0 else {
            return []
        }

        let scaleX = frameSize.width / displayBounds.width
        let scaleY = frameSize.height / displayBounds.height
        let frameRect = CGRect(origin: .zero, size: frameSize)

        var windows: [CapturedWindow] = []
        var opaqueCoverage: [CGRect] = []
        // The focused window is the frontmost app's topmost normal window that has a title.
        // Untitled helper windows can sit above it, like the toolbar strip of a full-screen
        // AppKit window. With no titled window, the topmost one is used.
        var firstFrontmostIndex: Int?
        var firstTitledFrontmostIndex: Int?

        for entry in entries {
            // Capture adds redacted windows to both sets (their pixels are masked). They stay
            // in the map with bounds but no title; other excluded windows are left out.
            let isRedacted = redactedWindowIDs.contains(entry.windowID)
            guard entry.alpha > 0, isRedacted || !excludedWindowIDs.contains(entry.windowID) else { continue }

            let local = CGRect(
                x: (entry.bounds.minX - displayBounds.minX) * scaleX,
                y: (entry.bounds.minY - displayBounds.minY) * scaleY,
                width: entry.bounds.width * scaleX,
                height: entry.bounds.height * scaleY
            ).intersection(frameRect)

            guard !local.isNull,
                  local.width >= minimumSideLength,
                  local.height >= minimumSideLength else {
                continue
            }

            if entry.layer != 0,
               local.width * local.height >= frameRect.width * frameRect.height * fullScreenOverlayCoverage {
                continue
            }

            // Skip windows completely hidden behind a single opaque window in front of them.
            if opaqueCoverage.contains(where: { $0.contains(local) }) { continue }

            if entry.layer == 0, let frontmostPID, entry.ownerPID == frontmostPID {
                if firstFrontmostIndex == nil { firstFrontmostIndex = windows.count }
                if firstTitledFrontmostIndex == nil, normalized(entry.title) != nil {
                    firstTitledFrontmostIndex = windows.count
                }
            }

            let title = redactedWindowIDs.contains(entry.windowID) ? nil : normalized(entry.title)
            windows.append(
                CapturedWindow(
                    windowID: entry.windowID,
                    zOrder: windows.count,
                    bundleID: entry.ownerPID.flatMap(bundleIDForPID),
                    appName: normalized(entry.ownerName),
                    title: title,
                    bounds: local.integral.intersection(frameRect),
                    layer: entry.layer,
                    isFocused: false
                )
            )

            // Only normal app windows reliably paint their whole frame; panels, menus
            // and overlays on other layers often report alpha 1 while being see-through.
            if entry.alpha >= 1, entry.layer == 0 {
                opaqueCoverage.append(local)
            }
        }

        if let focusedIndex = firstTitledFrontmostIndex ?? firstFrontmostIndex {
            let window = windows[focusedIndex]
            windows[focusedIndex] = CapturedWindow(
                windowID: window.windowID,
                zOrder: window.zOrder,
                bundleID: window.bundleID,
                appName: window.appName,
                title: window.title,
                bounds: window.bounds,
                layer: window.layer,
                isFocused: true
            )
        }

        return windows
    }

    static func entry(from info: [String: Any]) -> WindowEntry? {
        guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let width = boundsDict["Width"] as? CGFloat,
              let height = boundsDict["Height"] as? CGFloat else {
            return nil
        }

        return WindowEntry(
            windowID: windowID,
            ownerPID: info[kCGWindowOwnerPID as String] as? pid_t,
            ownerName: info[kCGWindowOwnerName as String] as? String,
            title: info[kCGWindowName as String] as? String,
            bounds: CGRect(x: x, y: y, width: width, height: height),
            layer: info[kCGWindowLayer as String] as? Int ?? 0,
            alpha: info[kCGWindowAlpha as String] as? Double ?? 1
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
