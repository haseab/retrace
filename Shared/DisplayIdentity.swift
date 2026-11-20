import Foundation
import CoreGraphics
import ColorSync

/// One process-wide authority for capture and topology persistence. UUIDs are provided
/// by WindowServer and do not depend on the display's current pixel dimensions.
public final class DisplayIdentityRegistry: @unchecked Sendable {
    public static let shared = DisplayIdentityRegistry()
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var persisted: [String: UInt32]
    private var reservations: [UInt32: (fingerprint: String, id: UInt32)] = [:]
    private let sessionID = UUID().uuidString
    private static let defaultsKey = "displayIdentityRegistry.v1"

    public init(defaults: UserDefaults = UserDefaults(suiteName: AppPaths.settingsSuiteName) ?? .standard) {
        self.defaults = defaults
        self.persisted = (defaults.dictionary(forKey: Self.defaultsKey) ?? [:]).reduce(into: [:]) { result, item in
            if let number = item.value as? NSNumber, number.uint64Value > 0,
               number.uint64Value <= UInt64(Int32.max) {
                result[item.key] = number.uint32Value
            }
        }
    }

    public func displayID(for runtimeID: UInt32) -> UInt32 {
        lock.lock()
        reservations = reservations.filter { CGDisplayIsOnline($0.key) != 0 }
        lock.unlock()
        let uuid = CGDisplayCreateUUIDFromDisplayID(runtimeID)?.takeRetainedValue()
        let fingerprint = uuid.map { CFUUIDCreateString(nil, $0) as String }
        return displayID(for: runtimeID, uuid: fingerprint)
    }

    /// Separate entry point allows deterministic identity/restart tests without live monitors.
    public func displayID(for runtimeID: UInt32, uuid: String?) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let fingerprint = uuid.map { "uuid:\($0)" } ?? "session:\(sessionID):\(runtimeID)"
        if let existing = reservations[runtimeID], existing.fingerprint == fingerprint {
            return existing.id
        }
        reservations.removeValue(forKey: runtimeID)
        var key = fingerprint
        // Broken/virtual drivers can report the same UUID for two displays. Never
        // merge their writers. Such ambiguous displays get session-scoped identities.
        if reservations.values.contains(where: { $0.fingerprint == fingerprint }) {
            key += ":session:\(sessionID):\(runtimeID)"
        }
        let occupied = Set(persisted.values).union(reservations.values.map(\.id))
        let id: UInt32
        if let saved = persisted[key], !reservations.values.contains(where: { $0.id == saved }) {
            id = saved
        } else {
            var candidate: UInt32 = 2_166_136_261
            for byte in key.utf8 { candidate = (candidate ^ UInt32(byte)) &* 16_777_619 }
            candidate = max(1, candidate & 0x7fff_ffff)
            while occupied.contains(candidate) { candidate = candidate == UInt32(Int32.max) ? 1 : candidate + 1 }
            id = candidate
            if !key.contains(":session:") && uuid != nil {
                persisted[key] = id
                defaults.set(persisted.mapValues { NSNumber(value: $0) }, forKey: Self.defaultsKey)
            }
        }
        reservations[runtimeID] = (fingerprint, id)
        return id
    }
}
