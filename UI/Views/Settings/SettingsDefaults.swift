import SwiftUI
import Shared
import App

/// Shared UserDefaults store for consistent settings across debug/release builds.
let settingsStore: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
let rewindCutoffDateDefaultsKey = "rewindCutoffDate"
let phraseLevelRedactionEnabledDefaultsKey = "phraseLevelRedactionEnabled"

enum MasterKeyProtectedFeature: String, Identifiable {
    case phraseLevelRedaction

    var id: String { rawValue }

    var metricSource: String {
        rawValue
    }

    var setupPromptTitle: String {
        "Create Master Key?"
    }

    var setupPromptMessage: String {
        "Turning on keyword redaction requires a master key stored in your Keychain. Retrace will create it locally on this Mac before enabling the feature."
    }

    var successTitle: String {
        "Master Key Created"
    }
}

struct MasterKeySetupSession: Identifiable {
    enum Step: Equatable {
        case created
        case recovery
    }

    let id = UUID()
    let feature: MasterKeyProtectedFeature
    let recoveryPhrase: String
    var step: Step = .created
}

// MARK: - Settings Defaults

enum SettingsDefaults {
    static let launchAtLogin = false
    static let showDockIcon = true
    static let showMenuBarIcon = true
    static let theme: ThemePreference = .auto
    static let automaticUpdateChecks = true
    static let automaticallyDownloadUpdates = false

    static let fontStyle: RetraceFontStyle = .default
    static let colorTheme = "blue"
    static let timelineColoredBorders = false
    static let scrubbingAnimationDuration: Double = 0.10
    static let scrollSensitivity: Double = 0.50
    static let timelineScrollOrientation: TimelineScrollOrientation = .horizontal
    static let dashboardAppUsageViewMode = "list"

    static let pauseReminderDelayMinutes: Double = 30
    static let captureIntervalSeconds: Double = 2.0
    static let captureResolution: CaptureResolution = .original
    static let captureActiveDisplayOnly = false
    static let excludeCursor = false
    static let captureMousePosition = true
    static let videoQuality: Double = 0.5
    static let deleteDuplicateFrames = true
    static let deduplicationThreshold: Double = CaptureConfig.defaultDeduplicationThreshold
    static let keepFramesOnMouseMovement = true
    static let captureOnWindowChange = true
    static let captureOnMouseClick = false
    static let collectInPageURLsExperimental = false

    static let retentionDays: Int = 0
    static let maxStorageGB: Double = 50.0
    static let useRewindData = false
    static let rewindCutoffDate = ServiceContainer.defaultRewindCutoffDate()

    static let excludedApps = ""
    static let excludePrivateWindows = false
    static let enableCustomPatternWindowRedaction = true
    static let redactWindowTitlePatterns = ""
    static let redactBrowserURLPatterns = ""
    static let phraseLevelRedactionEnabled = false
    static let phraseLevelRedactionPhrases = "[]"
    static let excludeSafariPrivate = true
    static let excludeChromeIncognito = true
    static let encryptionEnabled = true

    static let showFrameIDs = false
    static let enableFrameIDSearch = false
    static let showOCRDebugOverlay = false
    static let showVideoControls = false

    static let ocrEnabled = true
    static let ocrOnlyWhenPluggedIn = false
    static let ocrPauseInLowPowerMode = false
    static let ocrMaxFramesPerSecond: Double = 0
    static let ocrProcessingLevel: Int = 3
    static let ocrAppFilterMode: OCRAppFilterMode = .allApps
    static let ocrFilteredApps = ""
    static let autoMaxOCR = false
}

enum DashboardAppUsageViewModeSetting: String, CaseIterable {
    case list = "list"
    case hardDrive = "squares"

    var shortLabel: String {
        switch self {
        case .list:
            return "List"
        case .hardDrive:
            return "Tiles"
        }
    }

    var displayName: String {
        switch self {
        case .list:
            return "List view"
        case .hardDrive:
            return "Tiles view"
        }
    }
}
