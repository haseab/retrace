import Foundation

// MARK: - Segment ID

/// Unique identifier for a segment (INTEGER in Rewind database)
public struct SegmentID: Hashable, Codable, Sendable, Identifiable {
    public let value: Int64
    public var id: Int64 { value }

    public init(value: Int64) {
        self.value = value
    }

    public init?(int: Int) {
        self.value = Int64(int)
    }
}

// MARK: - Segment

/// Represents a recording session in a specific application
/// Matches Rewind's "segment" table - tracks app focus periods and window changes
public struct Segment: Codable, Sendable, Equatable, Identifiable {
    /// Database row ID (INTEGER PRIMARY KEY AUTOINCREMENT)
    public let id: SegmentID

    /// Bundle identifier of the focused application (e.g., "com.google.Chrome")
    public let bundleID: String

    /// When this segment started (Unix timestamp in milliseconds)
    public let startDate: Date

    /// When this segment ended (Unix timestamp in milliseconds)
    public var endDate: Date

    /// Title of the focused window
    public let windowName: String?

    /// URL if the active app is a browser (Chrome, Safari, etc.)
    public let browserUrl: String?

    /// Segment type: 0 = screen capture, 1 = audio recording
    public let type: Int

    public init(
        id: SegmentID,
        bundleID: String,
        startDate: Date,
        endDate: Date,
        windowName: String? = nil,
        browserUrl: String? = nil,
        type: Int = 0
    ) {
        self.id = id
        self.bundleID = bundleID
        self.startDate = startDate
        self.endDate = endDate
        self.windowName = windowName
        self.browserUrl = browserUrl
        self.type = type
    }

    /// Duration of this segment in seconds
    public var duration: TimeInterval {
        return endDate.timeIntervalSince(startDate)
    }

    /// Update the end date of this segment
    public mutating func updateEndDate(_ date: Date) {
        self.endDate = date
    }
}

public extension Sequence where Element == SegmentID {
    func uniquePreservingOrder() -> [SegmentID] {
        var seen = Set<Int64>()
        var ordered: [SegmentID] = []

        for segmentID in self where seen.insert(segmentID.value).inserted {
            ordered.append(segmentID)
        }

        return ordered
    }
}

// MARK: - Deletion Job

/// Entity type for deletion queue
public enum DeletionEntityType: String, Codable, Sendable {
    case frame = "frame"
    case segment = "segment"
    case document = "document"
}

/// Represents an entity queued for asynchronous deletion
public struct DeletionJob: Codable, Sendable, Equatable {
    /// Database row ID
    public let id: Int64?

    /// Type of entity to delete
    public let entityType: DeletionEntityType

    /// ID of the entity (UUID string)
    public let entityID: String

    /// Associated file path to delete (if any)
    public let filePath: String?

    /// When the deletion was queued
    public let createdAt: Date

    public init(
        id: Int64? = nil,
        entityType: DeletionEntityType,
        entityID: String,
        filePath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.filePath = filePath
        self.createdAt = createdAt
    }
}
