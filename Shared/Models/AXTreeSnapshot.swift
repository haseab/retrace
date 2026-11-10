import CoreGraphics
import CryptoKit
import Foundation

/// One accessibility element captured from an app's UI.
public struct AXNodeSnapshot: Codable, Sendable, Equatable {
    /// `kAXRoleAttribute`, e.g. "AXStaticText", "AXButton".
    public let role: String
    /// `kAXSubroleAttribute`.
    public let subrole: String?
    /// `kAXTitleAttribute`.
    public let title: String?
    /// `kAXValueAttribute`, when it is a string (truncated to `AXTreeSnapshot.maxValueLength`).
    public let value: String?
    /// `kAXDescriptionAttribute`, the accessibility label.
    public let label: String?
    /// Element frame in frame pixel coordinates (top-left origin), when known.
    public let bounds: CGRect?
    public let children: [AXNodeSnapshot]

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        label: String? = nil,
        bounds: CGRect? = nil,
        children: [AXNodeSnapshot] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.label = label
        self.bounds = bounds
        self.children = children
    }

    /// Content hash of this node and its whole subtree. Identical subtrees in different
    /// frames hash the same, which lets storage keep one copy of each.
    public func contentHash(childHashes: [Data]) -> Data {
        var hasher = SHA256()
        func field(_ string: String?) {
            if let string {
                hasher.update(data: Data([1]))
                hasher.update(data: Data(string.utf8))
            }
            hasher.update(data: Data([0]))
        }
        field(role)
        field(subrole)
        field(title)
        field(value)
        field(label)
        if let bounds {
            let rounded = [bounds.minX, bounds.minY, bounds.width, bounds.height].map { Int64($0.rounded()) }
            hasher.update(data: Data([1]))
            for component in rounded {
                withUnsafeBytes(of: component.littleEndian) { hasher.update(bufferPointer: $0) }
            }
        } else {
            hasher.update(data: Data([0]))
        }
        withUnsafeBytes(of: Int64(childHashes.count).littleEndian) { hasher.update(bufferPointer: $0) }
        for childHash in childHashes {
            hasher.update(data: childHash)
        }
        return Data(hasher.finalize())
    }
}

/// An app's accessibility tree captured with a frame.
public struct AXTreeSnapshot: Codable, Sendable, Equatable {
    /// Longest string value kept for one element. Editors can expose whole documents.
    public static let maxValueLength = 4_000

    /// Most text, in characters, `textLines()` returns for one snapshot.
    public static let maxTextLength = 50_000

    public let bundleID: String?
    public let processID: Int32
    public let root: AXNodeSnapshot
    public let nodeCount: Int
    /// True when the walk stopped early (time, depth or node budget).
    public let isTruncated: Bool
    public let walkMilliseconds: Int

    public init(
        bundleID: String?,
        processID: Int32,
        root: AXNodeSnapshot,
        nodeCount: Int,
        isTruncated: Bool,
        walkMilliseconds: Int
    ) {
        self.bundleID = bundleID
        self.processID = processID
        self.root = root
        self.nodeCount = nodeCount
        self.isTruncated = isTruncated
        self.walkMilliseconds = walkMilliseconds
    }

    public struct TextLine: Equatable, Sendable {
        public let text: String
        public let bounds: CGRect?
    }

    /// Readable text in tree (document) order, one entry per element string, with exact
    /// duplicates removed. Static text and text fields contribute their value; other
    /// elements contribute their title or label. Controls (buttons, menus, toggles) are
    /// skipped: their labels are mostly icon names and shortcut hints ("Toggle Panel
    /// (⌘J)"), and any label drawn on screen is already read by OCR.
    public func textLines() -> [TextLine] {
        var lines: [TextLine] = []
        var seen = Set<String>()
        var total = 0

        func add(_ raw: String?, _ bounds: CGRect?) {
            guard total < Self.maxTextLength,
                  let raw,
                  case let text = raw.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  seen.insert(text).inserted else {
                return
            }
            lines.append(TextLine(text: text, bounds: bounds))
            total += text.count
        }

        func visit(_ node: AXNodeSnapshot) {
            if Self.valueRoles.contains(node.role) {
                add(node.value, node.bounds)
            }
            if !Self.controlRoles.contains(node.role) {
                add(node.title, node.bounds)
                if node.children.isEmpty || !Self.valueRoles.contains(node.role) {
                    add(node.label, node.bounds)
                }
            }
            for child in node.children {
                visit(child)
            }
        }

        visit(root)
        return lines
    }

    /// Roles whose `value` is their visible text. Capture reads values only for these.
    public static let valueRoles: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXHeading", "AXCell"
    ]

    /// Interactive controls whose title and label are not indexed (see `textLines`).
    static let controlRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXDisclosureTriangle",
        "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem", "AXToolbar", "AXSlider",
        "AXIncrementor", "AXScrollBar", "AXSplitter", "AXValueIndicator", "AXColorWell"
    ]
}

/// Why a kept frame did or did not get an accessibility snapshot. Used for metrics.
public enum AXSnapshotOutcome: String, Codable, Sendable, CaseIterable {
    case captured
    case disabled
    case noPermission = "no_permission"
    case redactedFrame = "redacted_frame"
    case excludedApp = "excluded_app"
    case appChanged = "app_changed"
    case noFocusedWindow = "no_focused_window"
    case windowMismatch = "window_mismatch"
    case privateWindow = "private_window"
    case offDisplay = "off_display"
}
