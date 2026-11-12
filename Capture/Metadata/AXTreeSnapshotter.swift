import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Shared

/// Captures the focused window's accessibility tree at capture time.
///
/// The snapshot is taken when a frame is kept, so its text matches what was on screen,
/// unlike reading the accessibility tree later from the processing queue. The walk is
/// bounded by time, depth and node count, is clipped to the captured display and to the
/// window, skips content scrolled out of view, and never requests secure field values.
enum AXTreeSnapshotter {

    struct Limits: Sendable {
        var timeBudget: TimeInterval = 0.05
        var maxDepth = 48
        var maxNodes = 3_000
        /// Per-call IPC timeout, so one unresponsive app cannot stall capture.
        var messagingTimeout: Float = 0.02
    }

    /// Capture privacy rules re-checked against the window actually being read, because
    /// focus can move to another window (for example a private one) after the frame's own
    /// privacy decision was made.
    struct PrivacyRules: Sendable {
        var excludePrivateWindows: Bool
        /// Window-title substrings (case-insensitive) that make a window off limits.
        var windowTitlePatterns: [String]
    }

    enum Result {
        case captured(AXTreeSnapshot)
        case skipped(AXSnapshotOutcome)
    }

    /// UserDefaults key (in the `io.retrace.app` suite) that turns snapshots off when false.
    static let enabledDefaultsKey = "captureAccessibilityTree"

    static var isEnabled: Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// Edges of the focused window may differ from the window map by this many frame
    /// pixels (rounding, shadows) and still count as the same window.
    static let windowMatchTolerance: CGFloat = 6

    /// Snapshot the focused window of the frontmost app, but only when it is the window
    /// the frame's window map recorded as focused (`expectedWindow`) and it still passes
    /// the capture privacy rules.
    static func captureFocusedWindow(
        expectedBundleID: String?,
        expectedWindow: CapturedWindow?,
        privacy: PrivacyRules,
        displayID: CGDirectDisplayID,
        frameWidth: Int,
        frameHeight: Int,
        limits: Limits = Limits()
    ) -> Result {
        guard isEnabled else { return .skipped(.disabled) }
        guard AXIsProcessTrusted() else { return .skipped(.noPermission) }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .skipped(.appChanged)
        }
        if let expectedBundleID, app.bundleIdentifier != expectedBundleID {
            return .skipped(.appChanged)
        }
        guard let expectedWindow else { return .skipped(.noFocusedWindow) }

        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.width > 0, displayBounds.height > 0, frameWidth > 0, frameHeight > 0 else {
            return .skipped(.offDisplay)
        }
        let transform = CoordinateTransform(
            displayOrigin: displayBounds.origin,
            scaleX: CGFloat(frameWidth) / displayBounds.width,
            scaleY: CGFloat(frameHeight) / displayBounds.height
        )
        let frameRect = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, limits.messagingTimeout)
        enableChromiumAccessibilityIfNeeded(appElement, pid: app.processIdentifier)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .skipped(.noFocusedWindow)
        }
        let window = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(window, limits.messagingTimeout)

        // The window being read must be the one captured as focused.
        let windowTitle = stringAttribute(window, kAXTitleAttribute)
        guard let windowFrame = frameAttribute(window),
              matches(
                  windowFrame: transform.frameRect(windowFrame).intersection(frameRect).integral,
                  title: windowTitle,
                  expected: expectedWindow
              ) else {
            return .skipped(.windowMismatch)
        }

        // Re-check privacy against this window: focus may have moved after the frame's
        // own privacy decision.
        if let windowTitle, titleMatchesAnyPattern(windowTitle, patterns: privacy.windowTitlePatterns) {
            return .skipped(.privateWindow)
        }
        if privacy.excludePrivateWindows, let bundleID = app.bundleIdentifier,
           PrivateWindowDetector.isPrivateWindowElement(window, bundleID: bundleID) {
            return .skipped(.privateWindow)
        }

        var walker = Walker(limits: limits, transform: transform)
        guard let root = walker.walk(window, depth: 0, clip: displayBounds) else {
            return .skipped(.offDisplay)
        }

        return .captured(
            AXTreeSnapshot(
                bundleID: app.bundleIdentifier,
                processID: app.processIdentifier,
                root: root,
                nodeCount: walker.nodeCount,
                isTruncated: walker.isTruncated,
                walkMilliseconds: Int((Date().timeIntervalSince(walker.start) * 1_000).rounded())
            )
        )
    }

    /// True when an accessibility window (frame pixels, clipped to the frame) and title
    /// describe the window-map entry `expected`.
    static func matches(windowFrame: CGRect, title: String?, expected: CapturedWindow) -> Bool {
        let tolerance = windowMatchTolerance
        let bounds = expected.bounds
        guard abs(windowFrame.minX - bounds.minX) <= tolerance,
              abs(windowFrame.minY - bounds.minY) <= tolerance,
              abs(windowFrame.maxX - bounds.maxX) <= tolerance,
              abs(windowFrame.maxY - bounds.maxY) <= tolerance else {
            return false
        }
        if let expectedTitle = expected.title {
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == expectedTitle
        }
        return true
    }

    static func titleMatchesAnyPattern(_ title: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frameAttribute(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else {
            return nil
        }
        return Walker.globalRect(position: position, size: size)
    }

    // MARK: - Walk

    struct CoordinateTransform {
        let displayOrigin: CGPoint
        let scaleX: CGFloat
        let scaleY: CGFloat

        func frameRect(_ global: CGRect) -> CGRect {
            CGRect(
                x: (global.minX - displayOrigin.x) * scaleX,
                y: (global.minY - displayOrigin.y) * scaleY,
                width: global.width * scaleX,
                height: global.height * scaleY
            )
        }
    }

    /// Read in one IPC call per element. The value is not in this batch: it is requested
    /// separately, only for text roles and never for secure fields.
    private static let attributes: [CFString] = [
        kAXRoleAttribute as CFString,
        kAXSubroleAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString,
        kAXChildrenAttribute as CFString
    ]

    /// Containers that can hold thousands of off-screen rows; read only what is visible.
    private static let visibleChildrenAttributeByRole: [String: String] = [
        "AXTable": "AXVisibleRows",
        "AXOutline": "AXVisibleRows",
        "AXList": "AXVisibleChildren",
        "AXBrowser": "AXVisibleColumns",
        "AXGrid": "AXVisibleChildren"
    ]

    /// Roles whose value must never be read.
    private static let secureSubroles: Set<String> = ["AXSecureTextField"]

    private struct Walker {
        let limits: Limits
        let transform: CoordinateTransform
        let start = Date()
        var nodeCount = 0
        var isTruncated = false

        init(limits: Limits, transform: CoordinateTransform) {
            self.limits = limits
            self.transform = transform
        }

        mutating func walk(_ element: AXUIElement, depth: Int, clip: CGRect?) -> AXNodeSnapshot? {
            guard nodeCount < limits.maxNodes, Date().timeIntervalSince(start) < limits.timeBudget else {
                isTruncated = true
                return nil
            }
            nodeCount += 1
            AXUIElementSetMessagingTimeout(element, limits.messagingTimeout)

            var rawValues: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(
                element, AXTreeSnapshotter.attributes as CFArray, [], &rawValues
            ) == .success, let values = rawValues as? [Any], values.count == AXTreeSnapshotter.attributes.count else {
                return nil
            }

            let role = values[0] as? String ?? "AXUnknown"
            let subrole = values[1] as? String
            let isSecure = AXTreeSnapshotter.secureSubroles.contains(subrole ?? "")
                || AXTreeSnapshotter.secureSubroles.contains(role)
            let title = Self.text(values[2])
            let label = Self.text(values[3])
            let bounds = Self.globalRect(position: values[4], size: values[5])
            var value: String?
            if !isSecure, AXTreeSnapshot.valueRoles.contains(role) {
                var rawValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &rawValue) == .success,
                   let rawValue {
                    value = Self.text(rawValue).map { String($0.prefix(AXTreeSnapshot.maxValueLength)) }
                }
            }

            // Skip content outside the clip (another display, or scrolled out of view): it is
            // not on screen in this frame.
            if let bounds, let clip, !bounds.intersects(clip), bounds.width > 0, bounds.height > 0 {
                return nil
            }
            let childClip = clip.map { bounds.map($0.intersection) ?? $0 } ?? bounds

            var children: [AXNodeSnapshot] = []
            if depth + 1 < limits.maxDepth {
                for child in childElements(element, role: role, children: values[6]) {
                    if let snapshot = walk(child, depth: depth + 1, clip: childClip) {
                        children.append(snapshot)
                    }
                    if isTruncated { break }
                }
            } else {
                isTruncated = true
            }

            // Leaves with no text carry nothing searchable; drop them to save space.
            if children.isEmpty, title == nil, value == nil, label == nil, depth > 0 {
                return nil
            }

            return AXNodeSnapshot(
                role: role,
                subrole: subrole,
                title: title,
                value: value,
                label: label,
                bounds: bounds.map(transform.frameRect),
                children: children
            )
        }

        private func childElements(_ element: AXUIElement, role: String, children: Any) -> [AXUIElement] {
            if let attribute = AXTreeSnapshotter.visibleChildrenAttributeByRole[role] {
                var visible: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &visible) == .success,
                   let visible = visible as? [AXUIElement] {
                    return visible
                }
            }
            return children as? [AXUIElement] ?? []
        }

        private static func text(_ value: Any) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : string
        }

        static func globalRect(position: Any, size: Any) -> CGRect? {
            guard CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
                  CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else {
                return nil
            }
            var point = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
                return nil
            }
            return CGRect(origin: point, size: extent)
        }
    }

    // MARK: - Chromium / Electron

    private static let manualAccessibilityLock = NSLock()
    nonisolated(unsafe) private static var manualAccessibilityPIDs = Set<pid_t>()

    /// Chromium and Electron apps only build their accessibility tree once asked to.
    /// `AXManualAccessibility` is the switch they provide for assistive apps; set it once
    /// per process.
    private static func enableChromiumAccessibilityIfNeeded(_ appElement: AXUIElement, pid: pid_t) {
        manualAccessibilityLock.lock()
        let isNew = manualAccessibilityPIDs.insert(pid).inserted
        manualAccessibilityLock.unlock()
        guard isNew else { return }
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
