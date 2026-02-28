import Foundation

// MARK: - Segment Comment ID

/// Unique identifier for a segment comment (INTEGER in database)
public struct SegmentCommentID: Hashable, Codable, Sendable, Identifiable {
    public let value: Int64
    public var id: Int64 { value }

    public init(value: Int64) {
        self.value = value
    }

    public init?(int: Int) {
        self.value = Int64(int)
    }
}

// MARK: - Segment Comment Attachment

/// Attachment metadata for a segment comment.
/// Files are stored on disk; this stores the metadata and file location.
public struct SegmentCommentAttachment: Codable, Sendable, Equatable, Identifiable {
    /// Stable attachment identifier
    public let id: String

    /// Absolute or storage-root-relative file path
    public let filePath: String

    /// Original file name shown in UI
    public let fileName: String

    /// Optional MIME type (e.g. "image/png")
    public let mimeType: String?

    /// Optional file size in bytes
    public let sizeBytes: Int64?

    public init(
        id: String = UUID().uuidString,
        filePath: String,
        fileName: String,
        mimeType: String? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }
}

// MARK: - Segment Comment

/// User-authored comment that can be linked to one or more segments.
public struct SegmentComment: Codable, Sendable, Equatable, Identifiable {
    /// Database row ID (INTEGER PRIMARY KEY AUTOINCREMENT)
    public let id: SegmentCommentID

    /// Long-form comment body
    public let body: String

    /// Author display name
    public let author: String

    /// Optional attachment metadata (stored as JSON in DB)
    public let attachments: [SegmentCommentAttachment]

    /// Optional frame anchor for where this comment was created.
    public let frameID: FrameID?

    /// Creation timestamp
    public let createdAt: Date

    /// Last update timestamp
    public let updatedAt: Date

    public init(
        id: SegmentCommentID,
        body: String,
        author: String,
        attachments: [SegmentCommentAttachment] = [],
        frameID: FrameID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.body = body
        self.author = author
        self.attachments = attachments
        self.frameID = frameID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Segment Comment Link

/// Association between a segment and a comment.
public struct SegmentCommentLink: Codable, Sendable, Equatable {
    public let segmentId: SegmentID
    public let commentId: SegmentCommentID
    public let createdAt: Date

    public init(
        segmentId: SegmentID,
        commentId: SegmentCommentID,
        createdAt: Date = Date()
    ) {
        self.segmentId = segmentId
        self.commentId = commentId
        self.createdAt = createdAt
    }
}
