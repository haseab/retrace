import Foundation
import IOKit.ps

/// Monitors power source state (AC/Battery) - lightweight, no run loop needed
/// Power changes detected via NSWorkspace notifications in AppDelegate
public final class PowerStateMonitor: @unchecked Sendable {
    public static let shared = PowerStateMonitor()

    public enum PowerSource: Sendable {
        case ac
        case battery
        case unknown
    }

    private init() {}

    /// Get current power source (thread-safe, called on demand)
    public func getCurrentPowerSource() -> PowerSource {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            // Desktop Mac (no battery) - always AC
            return .ac
        }

        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let state = info[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue ? .ac : .battery
            }
        }
        return .unknown
    }

    /// Check if currently on AC power
    public var isOnACPower: Bool {
        getCurrentPowerSource() == .ac
    }

    /// Check if currently on battery
    public var isOnBattery: Bool {
        getCurrentPowerSource() == .battery
    }
}

// MARK: - OCR App Filter Mode

/// Defines how the OCR app filter works
public enum OCRAppFilterMode: String, CaseIterable, Sendable {
    case allApps = "all"
    case onlyTheseApps = "include"
    case allExceptTheseApps = "exclude"

    public var displayName: String {
        switch self {
        case .allApps: return "All apps"
        case .onlyTheseApps: return "Only these apps"
        case .allExceptTheseApps: return "All except these apps"
        }
    }
}
