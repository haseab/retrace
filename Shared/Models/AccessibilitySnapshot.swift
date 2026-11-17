import Foundation
import CoreGraphics

/// Capture-time reference only. Bounds use screenshot pixels, top-left origin.
public struct AccessibilitySnapshot: Codable, Sendable, Equatable {
    public struct Element: Codable, Sendable, Equatable {
        public let text: String
        public let bounds: CGRect
        public let precise: Bool
        public init(text: String, bounds: CGRect, precise: Bool) {
            self.text = text; self.bounds = bounds; self.precise = precise
        }
    }
    public let capturedAt: Date
    public let elements: [Element]
    public let truncated: Bool
    public init(capturedAt: Date, elements: [Element], truncated: Bool = false) {
        self.capturedAt = capturedAt; self.elements = elements; self.truncated = truncated
    }
    public static let maximumBytes = 131072

    /// References share the enclosing database's storage/encryption policy.
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw SnapshotError.tooLarge }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SnapshotError.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public enum SnapshotError: Error { case tooLarge }
}
