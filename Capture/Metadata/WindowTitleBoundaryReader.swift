import AppKit
import ApplicationServices
import Shared

/// Fresh, uncached focused-window AX title, bound to the visible CG window.
/// Synchronous AX work runs off the UI actor.
struct WindowTitleBoundaryReader: Sendable {
    func read(displayID: CGDirectDisplayID, expectedPID: Int32, expectedWindowID: UInt32? = nil) async -> WindowTitleObservation? {
        let front = await MainActor.run { () -> (Int32, String?)? in
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return (app.processIdentifier, app.bundleIdentifier)
        }
        guard let (pid, bundleID) = front, pid == expectedPID, pid != ProcessInfo.processInfo.processIdentifier,
              !ForegroundWindowSelection.isComputerUse(bundleID: bundleID), AXIsProcessTrusted() else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        defer { Log.recordLatency("capture.window_title_ax", valueMs: (ProcessInfo.processInfo.systemUptime - started) * 1000, category: .capture) }
        let display = CGDisplayBounds(displayID)
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              let visible = windows.first(where: {
                  ForegroundWindowSelection.isEligible($0, foregroundPID: pid, bundleID: bundleID, displayBounds: display)
              }), let id = visible[kCGWindowNumber as String] as? UInt32,
              let dictionary = visible[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              expectedWindowID == nil || expectedWindowID == id else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.015)
        guard let window = element(app, kAXFocusedWindowAttribute),
              let axBounds = rect(window), abs(axBounds.minX - bounds.minX) < 3,
              abs(axBounds.minY - bounds.minY) < 3, abs(axBounds.width - bounds.width) < 3,
              abs(axBounds.height - bounds.height) < 3,
              let title = value(window, kAXTitleAttribute) as? String, !title.isEmpty else { return nil }
        let region: CGRect?
        if BrowserURLExtractor.isBrowser(bundleID ?? "") {
            // Other visible tabs can contain the stale title. Only the selected tab is evidence.
            region = selectedTab(window, bounds: bounds, deadline: started + 0.05)
        } else {
            // Whole caption width, not text-sized AX bounds: retain distinguishing suffixes.
            region = CGRect(x: bounds.minX + 80, y: bounds.minY,
                            width: max(0, bounds.width - 160), height: 32)
        }
        guard ProcessInfo.processInfo.systemUptime - started <= 0.065 else { return nil }
        let normalized = region.map { r -> CGRect in
            let r = r.intersection(display)
            guard !r.isNull, display.width > 0, display.height > 0 else { return .zero }
            return CGRect(x: (r.minX - display.minX) / display.width,
                          y: (r.minY - display.minY) / display.height,
                          width: r.width / display.width, height: r.height / display.height)
        }
        return WindowTitleObservation(pid: pid, windowID: id, bounds: bounds, title: title, titleRegion: normalized)
    }
    private func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(e, 0.015)
        var output: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, key as CFString, &output) == .success ? output : nil
    }
    private func element(_ e: AXUIElement, _ key: String) -> AXUIElement? {
        guard let v = value(e, key), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private func rect(_ e: AXUIElement) -> CGRect? {
        guard let p = value(e, kAXPositionAttribute), let s = value(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private func selectedTab(_ window: AXUIElement, bounds: CGRect, deadline: Double) -> CGRect? {
        var queue = [window], index = 0
        var selected: [CGRect] = []
        while index < queue.count, index < 160, ProcessInfo.processInfo.systemUptime < deadline {
            let e = queue[index]; index += 1
            let role = value(e, kAXRoleAttribute) as? String
            if role == "AXWebArea" { continue }
            if let r = rect(e), r.width > 0, r.height > 0,
               (r.minY > bounds.minY + 80 || r.maxY < bounds.minY) { continue }
            if role == kAXRadioButtonRole,
               ((value(e, kAXValueAttribute) as? NSNumber)?.boolValue == true ||
                (value(e, kAXSelectedAttribute) as? NSNumber)?.boolValue == true),
               let r = rect(e), r.width > 40, r.height > 10,
               r.minY >= bounds.minY, r.maxY <= bounds.minY + 80 { selected.append(r) }
            if let children = value(e, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(160))
            }
        }
        return selected.count == 1 ? selected[0] : nil
    }
}
