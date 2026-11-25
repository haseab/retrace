#!/usr/bin/env swift

import Cocoa
import CoreGraphics
import ApplicationServices

// MARK: - Types

struct WindowInfo: CustomStringConvertible {
    let ownerName: String
    let windowName: String?
    let pid: pid_t
    let bounds: CGRect
    let layer: Int

    var description: String {
        let title = windowName ?? "(no title)"
        return "\(ownerName) — \"\(title)\" [pid=\(pid) layer=\(layer)] bounds=\(bounds)"
    }
}

// MARK: - 1. Topmost window per display

func frontmostWindowsPerDisplay() -> [(displayIndex: Int, displayID: CGDirectDisplayID, displayFrame: CGRect, window: WindowInfo)] {
    // Use CGDisplayBounds (CG coordinates) to match CGWindowListCopyWindowInfo coordinate space
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)
    guard displayCount > 0 else { return [] }
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
    let displays = displayIDs.map { CGDisplayBounds($0) }

    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as NSArray?
    let list = (raw as? [[String: Any]]) ?? []

    var best: [Int: WindowInfo] = [:]

    for w in list {
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -1

        let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
        if alpha < 0.05 { continue }

        guard
            let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { continue }

        if bounds.width < 80 || bounds.height < 80 { continue }

        let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? -1
        if pid <= 0 { continue }

        let owner = (w[kCGWindowOwnerName as String] as? String) ?? "Unknown"
        let name  = (w[kCGWindowName as String] as? String)

        let info = WindowInfo(
            ownerName: owner,
            windowName: (name?.isEmpty == false) ? name : nil,
            pid: pid_t(pid),
            bounds: bounds,
            layer: layer
        )

        if let displayIndex = displayIndexForWindow(bounds: bounds, displays: displays) {
            if best[displayIndex] == nil {
                best[displayIndex] = info
            }
        }

        if best.count == displays.count { break }
    }

    return displays.indices.compactMap { idx in
        guard let win = best[idx] else { return nil }
        return (idx, displayIDs[idx], displays[idx], win)
    }
}

// MARK: - 2. Active window (same as codebase: NSWorkspace + AX)

func getActiveWindow() -> (app: String, bundleID: String?, windowTitle: String?, displayIndex: Int?) {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        return ("Unknown", nil, nil, nil)
    }

    let appName = frontApp.localizedName ?? "Unknown"
    let bundleID = frontApp.bundleIdentifier
    let pid = frontApp.processIdentifier

    // Get window title via Accessibility API (same approach as AppInfoProvider)
    let appElement = AXUIElementCreateApplication(pid)
    var focusedWindow: AnyObject?
    let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

    var windowTitle: String? = nil
    var windowBounds: CGRect? = nil

    if result == .success, let window = focusedWindow {
        // Get title
        var titleValue: AnyObject?
        if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success {
            windowTitle = titleValue as? String
        }

        // Get position + size to determine which display
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &posValue) == .success,
           AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success {
            var point = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            windowBounds = CGRect(origin: point, size: size)
        }
    }

    // Determine which display the active window is on (using CG coordinates)
    var displayIdx: Int? = nil
    if let bounds = windowBounds {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        let displays = displayIDs.map { CGDisplayBounds($0) }
        displayIdx = displayIndexForWindow(bounds: bounds, displays: displays)
    }

    return (appName, bundleID, windowTitle, displayIdx)
}

// MARK: - Helpers

private func displayIndexForWindow(bounds: CGRect, displays: [CGRect]) -> Int? {
    var bestIdx: Int?
    var bestArea: CGFloat = 0

    for (i, df) in displays.enumerated() {
        let inter = df.intersection(bounds)
        if inter.isNull || inter.isEmpty { continue }
        let area = inter.width * inter.height
        if area > bestArea {
            bestArea = area
            bestIdx = i
        }
    }

    return bestIdx
}

// MARK: - Main (NSApplication run loop so NSWorkspace stays up to date)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited) // no dock icon, no menu bar

// Poll on a timer via the run loop
Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
    // Clear screen
    print("\u{1B}[2J\u{1B}[H", terminator: "")

    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(timestamp)]\n")

    // Show all connected displays
    var dCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &dCount)
    var dIDs = [CGDirectDisplayID](repeating: 0, count: Int(dCount))
    CGGetActiveDisplayList(dCount, &dIDs, &dCount)
    print("Connected displays: \(dCount)")
    for (i, did) in dIDs.enumerated() {
        let b = CGDisplayBounds(did)
        print("  Display \(i + 1): id=\(did) bounds=\(b)")
    }
    print()

    print("=== Topmost Window Per Display ===\n")

    let results = frontmostWindowsPerDisplay()
    if results.isEmpty {
        print("No windows found (do you have Screen Recording permission?)")
    } else {
        for r in results {
            print("Display \(r.displayIndex + 1) (id=\(r.displayID)): \(r.window)")
        }
    }

    print("\n=== Active Window (NSWorkspace + AX) ===\n")

    let active = getActiveWindow()
    let displayStr = active.displayIndex.map { "Display \($0 + 1)" } ?? "Unknown display"
    print("App:      \(active.app)")
    print("Bundle:   \(active.bundleID ?? "n/a")")
    print("Window:   \(active.windowTitle ?? "(no title)")")
    print("Display:  \(displayStr)")

    fflush(stdout)
}

// Fire immediately on first run
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
    print("Polling every 3 seconds. Press Ctrl+C to stop.\n")
}

app.run()
