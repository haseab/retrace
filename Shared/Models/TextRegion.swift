import Foundation
import CoreGraphics

// MARK: - Text Region

/// Represents OCR-detected text with spatial coordinates on a frame
/// Enables UI features like click-to-zoom and visual highlighting
public struct TextRegion: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Database row ID (used as id when available)
    private let dbID: Int64?

    /// Identifiable conformance - provides a stable ID
    public var id: Int { hashValue }

    /// Accessor for database ID
    public var databaseID: Int64? { dbID }

    /// Frame this text appears in
    public let frameID: FrameID

    /// Recognized text content
    public let text: String

    /// Bounding box on screen
    public let bounds: CGRect

    /// OCR confidence score (0.0 - 1.0)
    public let confidence: Double?

    /// When this was created
    public let createdAt: Date

    public init(
        id: Int64? = nil,
        frameID: FrameID,
        text: String,
        bounds: CGRect,
        confidence: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.dbID = id
        self.frameID = frameID
        self.text = text
        self.bounds = bounds
        self.confidence = confidence
        self.createdAt = createdAt
    }

    /// Convenience init from separate coordinates
    public init(
        id: Int64? = nil,
        frameID: FrameID,
        text: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        confidence: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.dbID = id
        self.frameID = frameID
        self.text = text
        self.bounds = CGRect(x: x, y: y, width: width, height: height)
        self.confidence = confidence
        self.createdAt = createdAt
    }

    /// X coordinate
    public var x: Int { Int(bounds.origin.x) }

    /// Y coordinate
    public var y: Int { Int(bounds.origin.y) }

    /// Width of bounding box
    public var width: Int { Int(bounds.width) }

    /// Height of bounding box
    public var height: Int { Int(bounds.height) }

    /// Center point of the text region
    public var center: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Whether this text region contains a given point
    public func contains(_ point: CGPoint) -> Bool {
        bounds.contains(point)
    }

    /// Whether this text region intersects with another
    public func intersects(_ other: TextRegion) -> Bool {
        bounds.intersects(other.bounds)
    }
}

// MARK: - Audio Capture

/// Represents a word or phrase from audio transcription
/// Scaffolding for future speech-to-text feature
public struct AudioCapture: Codable, Sendable, Equatable {
    /// Database row ID
    public let id: Int64?

    /// App segment during which this audio was captured (optional)
    public let segmentID: SegmentID?

    /// Transcribed text
    public let text: String

    /// When this word/phrase started
    public let startTime: Date

    /// When this word/phrase ended
    public let endTime: Date

    /// Speaker identifier (for multi-speaker scenarios)
    public let speaker: String?

    /// Audio source (e.g., "zoom", "system", "microphone")
    public let source: AudioSource?

    /// Transcription confidence score (0.0 - 1.0)
    public let confidence: Double?

    /// When this was created
    public let createdAt: Date

    public init(
        id: Int64? = nil,
        segmentID: SegmentID? = nil,
        text: String,
        startTime: Date,
        endTime: Date,
        speaker: String? = nil,
        source: AudioSource? = nil,
        confidence: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.segmentID = segmentID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.source = source
        self.confidence = confidence
        self.createdAt = createdAt
    }

    /// Duration of this audio segment in seconds
    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

// MARK: - Audio Source

/// Source of audio transcription
public enum AudioSource: String, Codable, Sendable, CaseIterable {
    /// Zoom meeting audio
    case zoom = "zoom"

    /// System audio (apps playing sound)
    case system = "system"

    /// Microphone input
    case microphone = "microphone"

    /// Google Meet
    case googleMeet = "google_meet"

    /// Microsoft Teams
    case microsoftTeams = "microsoft_teams"

    /// Slack huddle
    case slack = "slack"

    /// Discord
    case discord = "discord"

    /// Unknown source
    case unknown = "unknown"

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .system: return "System Audio"
        case .microphone: return "Microphone"
        case .googleMeet: return "Google Meet"
        case .microsoftTeams: return "Microsoft Teams"
        case .slack: return "Slack"
        case .discord: return "Discord"
        case .unknown: return "Unknown"
        }
    }
}
