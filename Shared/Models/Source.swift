import Foundation

// MARK: - Frame Source

/// Identifies the origin of captured frames and segments
/// Used to distinguish native Retrace captures from imported third-party data
public enum FrameSource: String, Codable, Sendable, CaseIterable {
    /// Native Retrace capture
    case native = "native"

    /// Imported from Rewind AI
    case rewind = "rewind"

    /// Imported from ScreenMemory (future support)
    case screenMemory = "screen_memory"

    /// Imported from TimeScroll (future support)
    case timeScroll = "time_scroll"

    /// Imported from Pensieve (future support)
    case pensieve = "pensieve"

    /// Unknown or unspecified source
    case unknown = "unknown"

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .native: return "Retrace"
        case .rewind: return "Rewind AI"
        case .screenMemory: return "ScreenMemory"
        case .timeScroll: return "TimeScroll"
        case .pensieve: return "Pensieve"
        case .unknown: return "Unknown"
        }
    }

    /// Whether this source is from a third-party application
    public var isThirdParty: Bool {
        self != .native
    }

    /// Bundle identifier associated with this source (if applicable)
    public var bundleIdentifier: String? {
        switch self {
        case .native: return nil // Our own app
        case .rewind: return "com.memoryvault.MemoryVault" // Rewind AI bundle ID
        case .screenMemory: return nil // TODO: Add when implementing
        case .timeScroll: return nil // TODO: Add when implementing
        case .pensieve: return nil // TODO: Add when implementing
        case .unknown: return nil
        }
    }

    /// Default data directory path for this source (absolute path with tilde)
    /// For Rewind, use AppPaths.rewindStorageRoot for the actual configurable path
    public var defaultDataPath: String? {
        switch self {
        case .native: return nil
        case .rewind: return AppPaths.defaultRewindStorageRoot
        case .screenMemory: return nil
        case .timeScroll: return nil
        case .pensieve: return nil
        case .unknown: return nil
        }
    }
}
