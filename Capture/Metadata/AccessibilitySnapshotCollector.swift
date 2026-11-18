import Foundation
import ApplicationServices
import CoreGraphics
import Shared

/// Runs on the capture actor, never on main. AX calls have a short messaging timeout;
/// the wall-clock deadline is best effort because a single system call can overrun it.
enum AccessibilitySnapshotCollector {
    static func collect(pid: pid_t?, windowID: CGWindowID?, windowBounds: CGRect?, displayBounds: CGRect,
                        width: Int, height: Int, capturedAt: Date, capturedImage: CGImage) -> AccessibilitySnapshot? {
        guard AXIsProcessTrusted(), let pid, let windowID, let expectedBounds = windowBounds else { return nil }
        let start = Date()
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let targetIndex = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }) else { return nil }
        let occluders = windows.prefix(targetIndex).compactMap { info -> CGRect? in
            guard let dictionary = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.01)
        let applicationName = windows[targetIndex][kCGWindowOwnerName as String] as? String
        let expectedTitle = windows[targetIndex][kCGWindowName as String] as? String
        guard let window = matchedWindow(app, bounds: expectedBounds, title: expectedTitle, applicationName: applicationName, startedAt: start),
              let initialBounds = rect(window) else { return nil }
        let title = attribute(window, kAXTitleAttribute) as? String
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var result: [AccessibilitySnapshot.Element] = []
        var visited = 0, bytes = 0
        var truncated = false
        let sx = CGFloat(width) / displayBounds.width, sy = CGFloat(height) / displayBounds.height
        while let (element, depth) = stack.popLast() {
            guard visited < 750, depth < 40, Date().timeIntervalSince(start) < 0.06 else { truncated = true; break }
            visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" || attribute(element, kAXHiddenAttribute) as? Bool == true { continue }
            if let bounds = rect(element), !bounds.intersects(initialBounds.intersection(displayBounds)) { continue }
            if ["AXStaticText", "AXTextArea", "AXTextField", "AXLink"].contains(role), let bounds = rect(element) {
                let text: String
                if role == "AXTextArea" || role == "AXTextField" {
                    // Ask for the bounded visible range directly. Reading AXValue first
                    // can materialize an entire document even when we later truncate it.
                    text = visibleText(element) ?? ""
                } else {
                    let content = (attribute(element, kAXValueAttribute) as? String)
                        ?? (attribute(element, kAXTitleAttribute) as? String) ?? ""
                    text = String(content.prefix(12000))
                }
                if !text.isEmpty, bounds.width > 0, bounds.height > 0, initialBounds.contains(bounds), displayBounds.contains(bounds) {
                    let pixelBounds = CGRect(x: (bounds.minX-displayBounds.minX)*sx, y: (bounds.minY-displayBounds.minY)*sy,
                                             width: bounds.width*sx, height: bounds.height*sy)
                    let precise = role != "AXTextArea" && bounds.height*sy <= 45
                    let item = AccessibilitySnapshot.Element(text: text, bounds: pixelBounds, precise: precise)
                    let cost = (try? JSONEncoder().encode(item).count) ?? AccessibilitySnapshot.maximumBytes
                    if bytes + cost < 110000 { result.append(item); bytes += cost } else { truncated = true }
                }
            }
            let childName = ["AXTable", "AXOutline", "AXList"].contains(role) ? kAXVisibleChildrenAttribute : kAXChildrenAttribute
            let remaining = max(0, 750 - visited - stack.count)
            var childCount: CFIndex = 0
            if remaining > 0, AXUIElementGetAttributeValueCount(element, childName as CFString, &childCount) == .success {
                let requested = min(childCount, remaining)
                var children: CFArray?
                if childCount > requested { truncated = true }
                if requested > 0,
                   AXUIElementCopyAttributeValues(element, childName as CFString, 0, requested, &children) == .success,
                   let values = children as? [AXUIElement] {
                    stack.append(contentsOf: values.reversed().map { ($0, depth+1) })
                }
            }

        }
        // Verify overlapping regions against the frame, not the overlay's bounding box.
        // A second image is only needed when at least one candidate may be covered.
        func screenRect(_ item: AccessibilitySnapshot.Element) -> CGRect {
            CGRect(x: item.bounds.minX / sx + displayBounds.minX,
                   y: item.bounds.minY / sy + displayBounds.minY,
                   width: item.bounds.width / sx, height: item.bounds.height / sy)
        }
        func overlaps(_ item: AccessibilitySnapshot.Element) -> Bool {
            occluders.contains { $0.intersects(screenRect(item)) }
        }
        if result.contains(where: overlaps) {
            let windowImage = CGWindowListCreateImage(displayBounds, .optionIncludingWindow, windowID,
                                                      [.boundsIgnoreFraming, .bestResolution])
            let verificationStart = Date()
            var remainingPixels = 2_000_000
            result = result.filter { item in
                guard overlaps(item) else { return true }
                guard Date().timeIntervalSince(verificationStart) < 0.05, let windowImage else {
                    truncated = true
                    return false
                }
                return AccessibilityPixelVisibility.matches(captured: capturedImage, window: windowImage,
                    rect: item.bounds, remainingPixels: &remainingPixels)
            }
        }
        guard let currentWindows = windowList(app), currentWindows.contains(where: { CFEqual($0, window) }),
              rect(window) == initialBounds, (attribute(window, kAXTitleAttribute) as? String) == title else { return nil }
        Log.recordLatency("capture.accessibility_snapshot", valueMs: Date().timeIntervalSince(start)*1000, category: .capture)
        return AccessibilitySnapshot(capturedAt: capturedAt, elements: result, truncated: truncated)
    }
    private static func visibleText(_ element: AXUIElement) -> String? {
        guard let value = attribute(element, kAXVisibleCharacterRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length > 0 else { return nil }
        range.length = min(range.length, 12000)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &text) == .success else { return nil }
        return (text as? String).map { String($0.prefix(12000)) }
    }
    private static func windowList(_ app: AXUIElement) -> [AXUIElement]? {
        // Bound the window list too; never pick an arbitrary candidate when truncated.
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count) == .success,
              count > 0, count <= 64 else { return nil }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, count, &values) == .success,
              let windows = values as? [AXUIElement], windows.count == count else { return nil }
        return windows
    }
    private static func matchedWindow(_ app: AXUIElement, bounds: CGRect, title: String?, applicationName: String?, startedAt: Date) -> AXUIElement? {
        guard let windows = windowList(app) else { return nil }
        var geometries: [CGRect?] = []
        var titles: [String?] = []
        for window in windows {
            guard Date().timeIntervalSince(startedAt) < 0.06 else { return nil }
            geometries.append(rect(window))
            titles.append(attribute(window, kAXTitleAttribute) as? String)
        }
        guard let index = AccessibilityWindowMatcher.uniqueIndex(bounds: geometries, titles: titles,
                                                                 expectedBounds: bounds, expectedTitle: title, applicationName: applicationName) else { return nil }
        return windows[index]
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    private static func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
