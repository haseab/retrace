import Foundation

// MARK: - Tag ID

/// Unique identifier for a tag (INTEGER in database)
public struct TagID: Hashable, Codable, Sendable, Identifiable {
    public let value: Int64
    public var id: Int64 { value }

    public init(value: Int64) {
        self.value = value
    }

    public init?(int: Int) {
        self.value = Int64(int)
    }
}

// MARK: - Tag

/// Represents a tag that can be applied to segments
public struct Tag: Codable, Sendable, Equatable, Identifiable {
    /// Database row ID (INTEGER PRIMARY KEY AUTOINCREMENT)
    public let id: TagID

    /// Tag name (unique)
    public let name: String

    public init(id: TagID, name: String) {
        self.id = id
        self.name = name
    }

    /// The built-in "hidden" tag name
    public static let hiddenTagName = "hidden"

    /// Check if this is the hidden tag
    public var isHidden: Bool {
        name == Tag.hiddenTagName
    }
}

// MARK: - Segment Tag

/// Represents the association between a segment and a tag
public struct SegmentTag: Codable, Sendable, Equatable {
    /// The segment this tag is applied to
    public let segmentId: SegmentID

    /// The tag applied to the segment
    public let tagId: TagID

    /// When the tag was applied (Unix timestamp in milliseconds)
    public let createdAt: Date

    public init(segmentId: SegmentID, tagId: TagID, createdAt: Date = Date()) {
        self.segmentId = segmentId
        self.tagId = tagId
        self.createdAt = createdAt
    }
}
