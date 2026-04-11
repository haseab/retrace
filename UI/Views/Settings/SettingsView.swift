import SwiftUI
import Shared
import AppKit
import App
import Database
import Carbon.HIToolbox
import ScreenCaptureKit
import SQLCipher
import ServiceManagement
import Darwin
import Carbon
import UniformTypeIdentifiers

public struct SettingsView: View {
    enum ManagedShortcutKind: Hashable {
        case timeline
        case dashboard
        case recording
        case systemMonitor
        case comment
    }

    // MARK: - Properties

    /// Optional initial tab to open (passed from parent when navigating to specific section)
    let onboardingManager = OnboardingManager()
    @StateObject var shellViewModel: SettingsShellViewModel

    // MARK: - Initialization

    public init(initialTab: SettingsTab? = nil, initialScrollTargetID: String? = nil) {
        _shellViewModel = StateObject(
            wrappedValue: SettingsShellViewModel(
                initialTab: initialTab,
                initialScrollTargetID: initialScrollTargetID
            )
        )
    }

    // MARK: General Settings
    @AppStorage("launchAtLogin", store: settingsStore) var launchAtLogin = SettingsDefaults.launchAtLogin
    @AppStorage("showDockIcon", store: settingsStore) var showDockIcon = SettingsDefaults.showDockIcon
    @AppStorage("showMenuBarIcon", store: settingsStore) var showMenuBarIcon = SettingsDefaults.showMenuBarIcon
    @AppStorage("theme", store: settingsStore) var theme: ThemePreference = SettingsDefaults.theme
    @AppStorage("retraceColorThemePreference", store: settingsStore) var colorThemePreference: String = SettingsDefaults.colorTheme
    @AppStorage("timelineColoredBorders", store: settingsStore) var timelineColoredBorders: Bool = SettingsDefaults.timelineColoredBorders
    @AppStorage("scrubbingAnimationDuration", store: settingsStore) var scrubbingAnimationDuration: Double = SettingsDefaults.scrubbingAnimationDuration
    @AppStorage("scrollSensitivity", store: settingsStore) var scrollSensitivity: Double = SettingsDefaults.scrollSensitivity
    @AppStorage("timelineScrollOrientation", store: settingsStore) var timelineScrollOrientation: TimelineScrollOrientation = SettingsDefaults.timelineScrollOrientation
    @AppStorage("dashboardAppUsageViewMode", store: settingsStore) var dashboardAppUsageViewMode: String = SettingsDefaults.dashboardAppUsageViewMode

    // Font style - tracked as @State to trigger view refresh on change
    @State var fontStyle: RetraceFontStyle = RetraceFont.currentStyle

    // Refresh ID to force view recreation when font or color theme changes
    @State var appearanceRefreshID = UUID()

    // Keyboard shortcuts
    @State var timelineShortcut = SettingsShortcutKey(from: .defaultTimeline)
    @State var dashboardShortcut = SettingsShortcutKey(from: .defaultDashboard)
    @State var recordingShortcut = SettingsShortcutKey(from: .defaultRecording)
    @State var isRecordingTimelineShortcut = false
    @State var isRecordingDashboardShortcut = false
    @State var isRecordingRecordingShortcut = false
    @State var systemMonitorShortcut = SettingsShortcutKey(from: .defaultSystemMonitor)
    @State var isRecordingSystemMonitorShortcut = false
    @State var commentShortcut = SettingsShortcutKey(from: .defaultCommentCapture)
    @State var isRecordingCommentShortcut = false
    @State var shortcutError: String? = nil
    @State var recordingTimeoutTask: Task<Void, Never>? = nil

    // MARK: Capture Settings
    @AppStorage("pauseReminderDelayMinutes", store: settingsStore) var pauseReminderDelayMinutes: Double = SettingsDefaults.pauseReminderDelayMinutes
    @AppStorage("captureIntervalSeconds", store: settingsStore) var captureIntervalSeconds: Double = SettingsDefaults.captureIntervalSeconds
    @AppStorage("captureResolution", store: settingsStore) var captureResolution: CaptureResolution = SettingsDefaults.captureResolution
    @AppStorage("captureActiveDisplayOnly", store: settingsStore) var captureActiveDisplayOnly = SettingsDefaults.captureActiveDisplayOnly
    @AppStorage("excludeCursor", store: settingsStore) var excludeCursor = SettingsDefaults.excludeCursor
    @AppStorage("captureMousePosition", store: settingsStore) var captureMousePosition: Bool = SettingsDefaults.captureMousePosition
    @AppStorage("videoQuality", store: settingsStore) var videoQuality: Double = SettingsDefaults.videoQuality
    @AppStorage("deleteDuplicateFrames", store: settingsStore) var deleteDuplicateFrames: Bool = SettingsDefaults.deleteDuplicateFrames
    @AppStorage("deduplicationThreshold", store: settingsStore) var deduplicationThreshold: Double = SettingsDefaults.deduplicationThreshold
    @AppStorage("keepFramesOnMouseMovement", store: settingsStore) var keepFramesOnMouseMovement = SettingsDefaults.keepFramesOnMouseMovement
    @AppStorage("captureOnWindowChange", store: settingsStore) var captureOnWindowChange: Bool = SettingsDefaults.captureOnWindowChange
    @AppStorage("captureOnMouseClick", store: settingsStore) var captureOnMouseClick: Bool = SettingsDefaults.captureOnMouseClick
    @AppStorage("collectInPageURLsExperimental", store: settingsStore) var collectInPageURLsExperimental: Bool = SettingsDefaults.collectInPageURLsExperimental
    @AppStorage("inPageURLPermissionCache", store: settingsStore) var inPageURLPermissionCacheRaw = ""
    @State var lastNonZeroCaptureIntervalSeconds = SettingsDefaults.captureIntervalSeconds
    @State var isProgrammaticCaptureIntervalChange = false
    @State var isProgrammaticWindowChangeCaptureToggleChange = false

    // MARK: Storage Settings
    @AppStorage("retentionDays", store: settingsStore) var retentionDays: Int = SettingsDefaults.retentionDays
    @State var retentionSettingChanged = false
    @State var retentionChangeProgress: CGFloat = 0  // Progress for auto-dismiss animation (0 to 1)
    @State var retentionChangeTimer: Timer?
    @State var showRetentionConfirmation = false
    @State var pendingRetentionDays: Int?
    @State var previewRetentionDays: Int?  // Visual preview while selecting
    @AppStorage("maxStorageGB", store: settingsStore) var maxStorageGB: Double = SettingsDefaults.maxStorageGB
    @AppStorage("useRewindData", store: settingsStore) var useRewindData: Bool = SettingsDefaults.useRewindData
    @State var rewindCutoffDateSelection: Date = ServiceContainer.rewindCutoffDate(in: settingsStore)
    @State var isRefreshingRewindCutoff = false
    @State var settingsToastMessage: String?
    @State var settingsToastVisible = false
    @State var settingsToastIsError = false
    @State var settingsToastDismissTask: Task<Void, Never>?
    @State var rewindCutoffRefreshTask: Task<Void, Never>?

    // Retention exclusion settings - data from these won't be deleted during cleanup
    @AppStorage("retentionExcludedApps", store: settingsStore) var retentionExcludedAppsString = ""
    @AppStorage("retentionExcludedTagIds", store: settingsStore) var retentionExcludedTagIdsString = ""
    @AppStorage("retentionExcludeHidden", store: settingsStore) var retentionExcludeHidden: Bool = false
    @State var retentionExcludedAppsPopoverShown = false
    @State var retentionExcludedTagsPopoverShown = false
    @State var installedAppsForRetention: [(bundleID: String, name: String)] = []
    @State var otherAppsForRetention: [(bundleID: String, name: String)] = []
    @State var availableTagsForRetention: [Tag] = []

    // Database location settings
    @AppStorage("customRetraceDBLocation", store: settingsStore) var customRetraceDBLocation: String?
    @AppStorage("customRewindDBLocation", store: settingsStore) var customRewindDBLocation: String?
    @State var rewindDBLocationChanged = false

    // Track the Retrace DB path the app was launched with (to know if restart is needed)
    @State var launchedWithRetraceDBPath: String?
    @State var launchedPathInitialized = false

    // MARK: Privacy Settings
    @AppStorage("excludedApps", store: settingsStore) var excludedAppsString = SettingsDefaults.excludedApps
    @AppStorage("excludePrivateWindows", store: settingsStore) var excludePrivateWindows = SettingsDefaults.excludePrivateWindows
    @AppStorage("enableCustomPatternWindowRedaction", store: settingsStore) var enableCustomPatternWindowRedaction = SettingsDefaults.enableCustomPatternWindowRedaction
    @AppStorage("redactWindowTitlePatterns", store: settingsStore) var redactWindowTitlePatternsRaw = SettingsDefaults.redactWindowTitlePatterns
    @AppStorage("redactBrowserURLPatterns", store: settingsStore) var redactBrowserURLPatternsRaw = SettingsDefaults.redactBrowserURLPatterns
    @AppStorage("phraseLevelRedactionPhrases", store: settingsStore) var phraseLevelRedactionPhrasesRaw = SettingsDefaults.phraseLevelRedactionPhrases
    @State var phraseLevelRedactionInput = ""
    @State var phraseLevelRedactionEnabled = SettingsDefaults.phraseLevelRedactionEnabled
    @State var phraseLevelRedactionToggleInitialized = false
    @State var hasMasterKeyInKeychain = false
    @State var pendingMasterKeyFeature: MasterKeyProtectedFeature?
    @State var masterKeySetupSession: MasterKeySetupSession?
    @State var isCreatingMasterKey = false
    @State var animateMasterKeyCreatedState = false

    // Computed property to manage excluded apps as array
    var excludedApps: [ExcludedAppInfo] {
        get {
            PrivacySettingsViewModel.decodeExcludedApps(from: excludedAppsString)
        }
        set {
            excludedAppsString = PrivacySettingsViewModel.encodeExcludedApps(newValue)
        }
    }

    @AppStorage("excludeSafariPrivate", store: settingsStore) var excludeSafariPrivate = SettingsDefaults.excludeSafariPrivate
    @AppStorage("excludeChromeIncognito", store: settingsStore) var excludeChromeIncognito = SettingsDefaults.excludeChromeIncognito
    @AppStorage("encryptionEnabled", store: settingsStore) var encryptionEnabled = SettingsDefaults.encryptionEnabled

    // Computed property to manage retention-excluded apps as a Set
    var retentionExcludedApps: Set<String> {
        get {
            guard !retentionExcludedAppsString.isEmpty else { return [] }
            return Set(retentionExcludedAppsString.split(separator: ",").map { String($0) })
        }
        set {
            retentionExcludedAppsString = newValue.sorted().joined(separator: ",")
        }
    }

    // Computed property to manage retention-excluded tag IDs as a Set
    var retentionExcludedTagIds: Set<Int64> {
        get {
            guard !retentionExcludedTagIdsString.isEmpty else { return [] }
            return Set(retentionExcludedTagIdsString.split(separator: ",").compactMap { Int64($0) })
        }
        set {
            retentionExcludedTagIdsString = newValue.sorted().map { String($0) }.joined(separator: ",")
        }
    }

    // MARK: Developer Settings
    @AppStorage("showFrameIDs", store: settingsStore) var showFrameIDs = SettingsDefaults.showFrameIDs
    @AppStorage("enableFrameIDSearch", store: settingsStore) var enableFrameIDSearch = SettingsDefaults.enableFrameIDSearch
    @AppStorage("showOCRDebugOverlay", store: settingsStore) var showOCRDebugOverlay = SettingsDefaults.showOCRDebugOverlay
    @AppStorage("showVideoControls", store: settingsStore) var showVideoControls = SettingsDefaults.showVideoControls
    @AppStorage(menuBarCaptureFeedbackDefaultsKey, store: settingsStore) var showMenuBarCaptureFeedback = SettingsDefaults.showMenuBarCaptureFeedback

    // MARK: OCR Power Settings
    @AppStorage("ocrEnabled", store: settingsStore) var ocrEnabled = SettingsDefaults.ocrEnabled
    @AppStorage("ocrOnlyWhenPluggedIn", store: settingsStore) var ocrOnlyWhenPluggedIn = SettingsDefaults.ocrOnlyWhenPluggedIn
    @AppStorage("ocrPauseInLowPowerMode", store: settingsStore) var ocrPauseInLowPowerMode = SettingsDefaults.ocrPauseInLowPowerMode
    @AppStorage("ocrMaxFramesPerSecond", store: settingsStore) var ocrMaxFramesPerSecond = SettingsDefaults.ocrMaxFramesPerSecond
    @AppStorage("ocrProcessingLevel", store: settingsStore) var ocrProcessingLevel = SettingsDefaults.ocrProcessingLevel
    @AppStorage("ocrAppFilterMode", store: settingsStore) var ocrAppFilterMode: OCRAppFilterMode = SettingsDefaults.ocrAppFilterMode
    @AppStorage("ocrFilteredApps", store: settingsStore) var ocrFilteredAppsString = SettingsDefaults.ocrFilteredApps
    @State var excludedAppsPopoverShown = false
    @State var installedAppsForExcludedRedaction: [(bundleID: String, name: String)] = []
    @State var otherAppsForExcludedRedaction: [(bundleID: String, name: String)] = []
    @State var ocrFilteredAppsPopoverShown = false
    @State var installedAppsForOCR: [(bundleID: String, name: String)] = []
    @State var otherAppsForOCR: [(bundleID: String, name: String)] = []
    @State var currentPowerSource: PowerStateMonitor.PowerSource = .unknown
    @State var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State var pendingOCRFrameCount: Int = 0

    // MARK: Tag Management
    @State var tagsForSettings: [Tag] = []
    @State var tagSegmentCounts: [TagID: Int] = [:]
    @State var tagColorsForSettings: [TagID: Color] = [:]
    @State var tagToDelete: Tag? = nil
    @State var showTagDeleteConfirmation = false
    @State var newTagName: String = ""
    @State var newTagColor: Color = TagColorStore.suggestedColor(for: "")
    @State var isCreatingTag = false
    @State var tagCreationError: String? = nil

    // Check if Rewind data folder exists
    var rewindDataExists: Bool {
        return FileManager.default.fileExists(atPath: AppPaths.expandedRewindStorageRoot)
    }

    // Check if Retrace database location is accessible
    var retraceDBAccessible: Bool {
        let path = customRetraceDBLocation ?? AppPaths.defaultStorageRoot
        return FileManager.default.fileExists(atPath: path)
    }

    // Resolve Rewind folder path from custom setting (supports legacy file-path values)
    var rewindFolderPath: String {
        guard let customPath = customRewindDBLocation else {
            return AppPaths.defaultRewindStorageRoot
        }
        return Self.normalizeRewindFolderPath(customPath)
    }

    // Check if Rewind database folder is accessible
    var rewindDBAccessible: Bool {
        let dbPath = "\(rewindFolderPath)/db-enc.sqlite3"
        return FileManager.default.fileExists(atPath: dbPath)
    }

    var hasCustomRewindCutoffDate: Bool {
        rewindCutoffDateSelection != SettingsDefaults.rewindCutoffDate
    }

    var defaultRewindCutoffDateDescription: String {
        SettingsDefaults.rewindCutoffDate.formatted(date: .long, time: .omitted)
    }

    var customRewindCutoffWarningText: String {
        let formattedCutoff = rewindCutoffDateSelection.formatted(date: .abbreviated, time: .shortened)
        return "When Rewind data is enabled, any native Retrace data before \(formattedCutoff) will not be available."
    }

    // Permission states
    @State var hasScreenRecordingPermission = false
    @State var hasAccessibilityPermission = false
    @State var hasListenEventAccess = false
    @State var isProgrammaticMouseClickCaptureToggleChange = false
    @State var browserExtractionPermissionStatus: PermissionStatus = .notDetermined
    @State var inPageURLTargets: [InPageURLBrowserTarget] = []
    @State var inPageURLPermissionStateByBundleID: [String: InPageURLPermissionState] = [:]
    @State var inPageURLBusyBundleIDs: Set<String> = []
    @State var inPageURLRunningBundleIDs: Set<String> = []
    @State var inPageURLIconByBundleID: [String: NSImage] = [:]
    @State var inPageURLIconLoadTasksByBundleID: [String: Task<Void, Never>] = [:]
    @State var inPageURLVerificationByBundleID: [String: InPageURLVerificationState] = [:]
    @State var inPageURLVerificationBusyBundleIDs: Set<String> = []
    @State var isRefreshingInPageURLTargets = false
    @State var inPageURLVerificationSummary: String? = nil
    @State var isSafariInPageInstructionsExpanded = false
    @State var isChromeInPageInstructionsExpanded = false
    @State var unsupportedInPageURLTargets: [UnsupportedInPageURLTarget] = []
    @State var privateModeAXCompatibleTargets: [PrivateModeAutomationTarget] = []
    @State var privateModeAutomationTargets: [PrivateModeAutomationTarget] = []
    @State var privateModeAutomationPermissionStateByBundleID: [String: InPageURLPermissionState] = [:]
    @State var privateModeAutomationBusyBundleIDs: Set<String> = []
    @State var privateModeAutomationRunningBundleIDs: Set<String> = []
    @State var isRefreshingPrivateModeAutomationTargets = false

    // Quick delete state
    @State var quickDeleteConfirmation: QuickDeleteOption? = nil
    @State var deletingOption: QuickDeleteOption? = nil
    @State var isDeleting = false

    // Danger zone confirmation states
    @State var showingResetConfirmation = false
    @State var showingDeleteConfirmation = false

    // Database schema display
    @State var showingDatabaseSchema = false
    @State var databaseSchemaText: String = ""

    // App coordinator for deletion operations
    @EnvironmentObject var coordinatorWrapper: AppCoordinatorWrapper

    // Observe UpdaterManager for automatic updates toggle
    @ObservedObject var updaterManager = UpdaterManager.shared

    // MARK: - Body

    /// Max width for the entire settings panel before it detaches and centers
    let settingsMaxWidth: CGFloat = 1200
    /// Minimum width to keep settings usable while allowing split-screen layouts.
    let settingsMinWidth: CGFloat = 760
    static let pauseReminderIntervalTargetID = "settings.pauseReminderInterval"
    static let pauseReminderCardAnchorID = "settings.pauseReminderCard"
    static let timelineScrollOrientationTargetID = "settings.timelineScrollOrientation"
    static let timelineScrollOrientationAnchorID = "settings.timelineScrollOrientationAnchor"
    static let powerOCRCardTargetID = "settings.powerOCRCard"
    static let powerOCRCardAnchorID = "settings.powerOCRCardAnchor"
    static let powerOCRPriorityTargetID = "settings.powerOCRPriority"
    static let powerOCRPriorityAnchorID = "settings.powerOCRPriorityAnchor"
    static let inPageURLPermissionProbeQueue = DispatchQueue(
        label: "io.retrace.settings.inPageURLPermissionProbe",
        qos: .utility,
        attributes: .concurrent
    )
    nonisolated static let inPageURLKnownBrowserBundleIDs: [String] = AppInfo.supportedBrowserBundleIDOrder
    nonisolated static let inPageURLUnsupportedBundleIDs: [String] = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxbeta",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.duckduckgo.macos.browser",
        "com.sigmaos.sigmaos.macos",
        "com.openai.atlas",
    ]
    nonisolated static let inPageURLChromiumHostBundleIDPrefixes: [String] = AppInfo.chromiumHostBrowserBundleIDPrefixes
    static let inPageURLTestURLString = "https://en.wikipedia.org/wiki/Cat"
    static let inPageURLNoMatchingWindowToken = "__NO_MATCHING_WINDOW__"
    nonisolated static let privateModeAutomationFallbackBundleIDs: [String] = [
        "com.vivaldi.Vivaldi",
        "com.sigmaos.sigmaos.macos",
    ]
    nonisolated static let privateModeAXCompatibleBrowserBundleIDs: [String] = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.chromium.Chromium",
        "org.mozilla.firefox",
        "org.mozilla.firefoxbeta",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",
        "ai.perplexity.comet",
        "company.thebrowser.dia",
        "com.duckduckgo.macos.browser",
        "com.nicklockwood.Thorium",
    ]

    nonisolated static var privateModeAutomationRequiredBundleIDs: [String] {
        privateModeAutomationFallbackBundleIDs
    }

    nonisolated static var privateModeAXCompatibleBundleIDs: [String] {
        privateModeAXCompatibleBrowserBundleIDs
    }

    var settingsBackground: some View {
        ZStack {
            themeBaseBackground

            // Subtle gradient orb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.retraceAccent.opacity(0.05), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 400
                    )
                )
                .frame(width: 800, height: 800)
                .offset(x: 200, y: -100)
                .blur(radius: 80)
        }
        .ignoresSafeArea()
    }

    var settingsShell: some View {
        GeometryReader { geometry in
            let windowWidth = geometry.size.width
            let detached = windowWidth > settingsMaxWidth

            HStack(spacing: 0) {
                // Sidebar
                sidebar
                    .frame(width: 220)

                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)

                // Content
                content
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: detached ? settingsMaxWidth : .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(minWidth: settingsMinWidth, minHeight: 650)
        .background(settingsBackground)
    }

    var settingsBodyBase: some View {
        settingsShell
        .onAppear {
            // Capture the Retrace DB path the app was launched with (only once)
            if !launchedPathInitialized {
                launchedWithRetraceDBPath = customRetraceDBLocation
                launchedPathInitialized = true
            }

            initializeProtectedFeatureStateIfNeeded()

            // Sync launch at login toggle with actual system state
            let systemLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            if launchAtLogin != systemLaunchAtLoginEnabled {
                launchAtLogin = systemLaunchAtLoginEnabled
            }

            postSelectedTabNotification(shellViewModel.selectedTab)
        }
        .onDisappear {
            shellViewModel.cancelTransientTasks()
            settingsToastDismissTask?.cancel()
            settingsToastDismissTask = nil
            rewindCutoffRefreshTask?.cancel()
            rewindCutoffRefreshTask = nil
            cancelAllInPageURLIconLoads()
        }
        .overlay {
            settingsSearchOverlay
                .animation(.easeOut(duration: 0.15), value: shellViewModel.showSettingsSearch)
        }
        .alert(item: $pendingMasterKeyFeature) { feature in
            Alert(
                title: Text(feature.setupPromptTitle),
                message: Text(feature.setupPromptMessage),
                primaryButton: .default(Text(isCreatingMasterKey ? "Creating..." : "Create Master Key")) {
                    createMasterKeyForPendingFeature(feature)
                },
                secondaryButton: .cancel {
                    recordMasterKeyMetric(action: "cancel_prompt", source: feature.metricSource)
                }
            )
        }
        .sheet(item: $masterKeySetupSession) { session in
            masterKeySetupSheet(session)
                .interactiveDismissDisabled()
        }
        .overlay(alignment: .top) {
            if let message = settingsToastMessage {
                HStack(spacing: 10) {
                    Image(systemName: settingsToastIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(settingsToastIsError ? .orange : .green)
                    Text(message)
                        .font(.retraceCaption)
                        .foregroundColor(.retracePrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke((settingsToastIsError ? Color.orange : Color.green).opacity(0.35), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 10)
                .padding(.top, 16)
                .scaleEffect(settingsToastVisible ? 1.0 : 0.9)
                .opacity(settingsToastVisible ? 1.0 : 0.0)
            }
        }
        .background {
            // Hidden button for Cmd+K shortcut
            Button("") {
                openSettingsSearch(source: "keyboard_cmd_k")
            }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    func persistShortcutChange(_ kind: ManagedShortcutKind) {
        Task { await saveShortcut(kind) }
    }

    public var body: some View {
        settingsBodyBase
            .onChange(of: shellViewModel.selectedTab) { newTab in
                postSelectedTabNotification(newTab)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsPower)) { _ in
                shellViewModel.selectedTab = .power
                shellViewModel.pendingScrollTargetID = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsTags)) { _ in
                shellViewModel.selectedTab = .tags
                shellViewModel.pendingScrollTargetID = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsPauseReminderInterval)) { _ in
                requestNavigation(to: Self.pauseReminderIntervalTargetID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsTimelineScrollOrientation)) { _ in
                requestNavigation(to: Self.timelineScrollOrientationTargetID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsPowerOCRCard)) { _ in
                requestNavigation(to: Self.powerOCRCardTargetID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsPowerOCRPriority)) { _ in
                requestNavigation(to: Self.powerOCRPriorityTargetID)
            }
    }

    var privateWindowRedactionBinding: Binding<Bool> {
        Binding(
            get: { excludePrivateWindows },
            set: { enabled in
                setPrivateWindowRedactionEnabled(enabled)
            }
        )
    }

    var phraseLevelRedactionBinding: Binding<Bool> {
        Binding(
            get: { phraseLevelRedactionEnabled },
            set: { enabled in
                setPhraseLevelRedactionEnabled(enabled)
            }
        )
    }
}
