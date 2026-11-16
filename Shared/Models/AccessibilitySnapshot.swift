import Foundation
import CoreGraphics
import CryptoKit

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

    /// Domain-separated encryption, with frame identity authenticated to prevent swapping snapshots.
    public func sealed(masterKey: Data, identity: String) throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw SnapshotError.tooLarge }
        return try AES.GCM.seal(data, using: Self.key(masterKey), authenticating: Data(identity.utf8)).combined!
    }
    public static func open(_ data: Data, masterKey: Data, identity: String) throws -> Self {
        guard data.count <= maximumBytes + 28 else { throw SnapshotError.tooLarge }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(masterKey), authenticating: Data(identity.utf8))
        return try JSONDecoder().decode(Self.self, from: plain)
    }
    private static func key(_ bytes: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: Data("retrace.ax.v1".utf8), info: Data("capture-reference".utf8), outputByteCount: 32)
    }
    public enum SnapshotError: Error { case tooLarge }
}
