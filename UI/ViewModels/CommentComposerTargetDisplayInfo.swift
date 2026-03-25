import Foundation
import Shared

public struct CommentComposerTargetDisplayInfo: Sendable, Equatable {
    private static let expandedWindowTitleThreshold = 20

    public let frameID: FrameID
    public let segmentID: SegmentID
    public let source: FrameSource
    public let timestamp: Date
    public let appBundleID: String?
    public let appName: String?
    public let windowName: String?
    public let browserURL: String?
    public let tagNames: [String]

    public init(
        frameID: FrameID,
        segmentID: SegmentID,
        source: FrameSource,
        timestamp: Date,
        appBundleID: String?,
        appName: String?,
        windowName: String?,
        browserURL: String?,
        tagNames: [String] = []
    ) {
        self.frameID = frameID
        self.segmentID = segmentID
        self.source = source
        self.timestamp = timestamp
        self.appBundleID = Self.normalized(appBundleID)
        self.appName = Self.normalized(appName)
        self.windowName = Self.normalized(windowName)
        self.browserURL = Self.normalized(browserURL)
        self.tagNames = tagNames
    }

    public var title: String {
        windowName ?? appName ?? appBundleID ?? "Untitled Window"
    }

    public var shouldUseExpandedWindowTitle: Bool {
        guard let windowName else { return false }
        return windowName.count > Self.expandedWindowTitleThreshold
    }

    public var subtitle: String? {
        shouldUseExpandedWindowTitle ? nil : appName
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
