import SwiftUI
import Shared

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case capture = "Capture"
    case storage = "Storage"
    case exportData = "Export & Data"
    case privacy = "Privacy"
    case power = "Power"
    case tags = "Tags"
    case advanced = "Advanced"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "video"
        case .storage: return "externaldrive"
        case .exportData: return "square.and.arrow.up"
        case .privacy: return "lock.shield"
        case .power: return "bolt.fill"
        case .tags: return "tag"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    var description: String {
        switch self {
        case .general: return "Startup, appearance, and shortcuts"
        case .capture: return "Frame rate, resolution, and display options"
        case .storage: return "Retention, limits, and compression"
        case .exportData: return "Export and manage your data"
        case .privacy: return "Encryption, exclusions, and permissions"
        case .power: return "OCR processing and battery optimization"
        case .tags: return "Manage and delete tags"
        case .advanced: return "Database, encoding, and developer tools"
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .general: return .retraceAccentGradient
        case .capture: return .retracePurpleGradient
        case .storage: return .retraceOrangeGradient
        case .exportData: return .retraceAccentGradient
        case .privacy: return .retraceGreenGradient
        case .power: return .retraceOrangeGradient
        case .tags: return .retraceAccentGradient
        case .advanced: return .retracePurpleGradient
        }
    }

    func resetAction(for view: SettingsView) -> (() -> Void)? {
        switch self {
        case .general:
            return { view.resetGeneralSettings() }
        case .capture:
            return { view.resetCaptureSettings() }
        case .storage:
            return { view.resetStorageSettings() }
        case .privacy:
            return { view.resetPrivacySettings() }
        case .power:
            return { view.resetPowerSettings() }
        case .advanced:
            return { view.resetAdvancedSettings() }
        case .exportData, .tags:
            return nil
        }
    }
}

enum ThemePreference: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

enum TimelineScrollOrientation: String, CaseIterable, Identifiable {
    case horizontal
    case vertical

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .horizontal:
            return "Left/Right"
        case .vertical:
            return "Up/Down"
        }
    }

    var displayName: String {
        shortLabel
    }

    var description: String {
        switch self {
        case .horizontal:
            return "Use left/right scroll movement to scrub the timeline"
        case .vertical:
            return "Use up/down scroll movement to scrub the timeline"
        }
    }
}

enum CaptureResolution: String, CaseIterable, Identifiable {
    case original = "Original"
    case uhd4k = "4K"
    case fullHD = "1080p"
    case hd = "720p"

    var id: String { rawValue }
}

enum CompressionQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case lossless = "Lossless"

    var id: String { rawValue }
}

enum PermissionStatus: String {
    case granted = "Granted"
    case denied = "Denied"
    case notDetermined = "Not Determined"
}

struct ExcludedAppInfo: Codable, Identifiable, Equatable {
    let bundleID: String
    let name: String
    let iconPath: String?

    var id: String { bundleID }

    static func from(appURL: URL) -> ExcludedAppInfo? {
        guard let bundle = Bundle(url: appURL),
              let bundleID = bundle.bundleIdentifier else {
            return nil
        }

        let name = FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")

        return ExcludedAppInfo(
            bundleID: bundleID,
            name: name,
            iconPath: appURL.path
        )
    }
}

enum QuickDeleteOption: String, Identifiable {
    case fiveMinutes
    case oneHour
    case oneDay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fiveMinutes: return "last 5 minutes"
        case .oneHour: return "last hour"
        case .oneDay: return "last 24 hours"
        }
    }

    var timeInterval: TimeInterval {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .oneHour: return 60 * 60
        case .oneDay: return 24 * 60 * 60
        }
    }

    var cutoffDate: Date {
        Date().addingTimeInterval(-timeInterval)
    }
}
