import SwiftUI
import Shared
import AppKit
import App
import ScreenCaptureKit
import SQLCipher
import ServiceManagement

/// Shared UserDefaults store for consistent settings across debug/release builds
private let settingsStore: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

// MARK: - Settings Defaults (Single Source of Truth)

/// All default values for settings in one place.
/// Reference these when declaring @AppStorage and in reset functions.
enum SettingsDefaults {
    // MARK: General
    static let launchAtLogin = false
    static let showMenuBarIcon = true
    static let theme: ThemePreference = .auto
    static let automaticUpdates = true

    // MARK: Appearance
    static let fontStyle: RetraceFontStyle = .default
    static let colorTheme = "blue"
    static let timelineColoredBorders = false
    static let scrubbingAnimationDuration: Double = 0.10  // 0 = no animation, max 0.20
    static let scrollSensitivity: Double = 0.50  // 0.0 = slowest, 1.0 = fastest

    // MARK: Capture
    static let pauseReminderDelayMinutes: Double = 30  // 0 = never remind again
    static let captureIntervalSeconds: Double = 2.0
    static let captureResolution: CaptureResolution = .original
    static let captureActiveDisplayOnly = false
    static let excludeCursor = false
    static let videoQuality: Double = 0.5
    static let deleteDuplicateFrames = true
    static let deduplicationThreshold: Double = CaptureConfig.defaultDeduplicationThreshold
    static let captureOnWindowChange = true

    // MARK: Storage
    static let retentionDays: Int = 0  // 0 = forever
    static let maxStorageGB: Double = 50.0
    static let useRewindData = false

    // MARK: Privacy
    static let excludedApps = ""
    static let excludePrivateWindows = false
    static let excludeSafariPrivate = true
    static let excludeChromeIncognito = true
    static let encryptionEnabled = true

    // MARK: Developer
    static let showFrameIDs = false
    static let enableFrameIDSearch = false
    static let showOCRDebugOverlay = false
    static let showVideoControls = false

    // MARK: OCR Power
    static let ocrEnabled = true
    static let ocrOnlyWhenPluggedIn = false
    static let ocrMaxFramesPerSecond: Double = 0  // 0 = unlimited
    static let ocrAppFilterMode: OCRAppFilterMode = .allApps
    static let ocrFilteredApps = ""  // JSON array of bundle IDs
}

// OCRAppFilterMode is defined in Shared/PowerStateMonitor.swift

/// Main settings view with sidebar navigation
/// Activated with Cmd+,
public struct SettingsView: View {

    // MARK: - Properties

    /// Optional initial tab to open (passed from parent when navigating to specific section)
    private let initialTab: SettingsTab?

    @State private var selectedTab: SettingsTab = .general
    @State private var hoveredTab: SettingsTab? = nil

    // MARK: - Initialization

    public init(initialTab: SettingsTab? = nil) {
        self.initialTab = initialTab
        // Set initial selected tab if provided
        if let tab = initialTab {
            _selectedTab = State(initialValue: tab)
        }
    }

    // MARK: General Settings
    @AppStorage("launchAtLogin", store: settingsStore) private var launchAtLogin = SettingsDefaults.launchAtLogin
    @AppStorage("showMenuBarIcon", store: settingsStore) private var showMenuBarIcon = SettingsDefaults.showMenuBarIcon
    @AppStorage("theme", store: settingsStore) private var theme: ThemePreference = SettingsDefaults.theme
    @AppStorage("retraceColorThemePreference", store: settingsStore) private var colorThemePreference: String = SettingsDefaults.colorTheme
    @AppStorage("timelineColoredBorders", store: settingsStore) private var timelineColoredBorders: Bool = SettingsDefaults.timelineColoredBorders
    @AppStorage("scrubbingAnimationDuration", store: settingsStore) private var scrubbingAnimationDuration: Double = SettingsDefaults.scrubbingAnimationDuration
    @AppStorage("scrollSensitivity", store: settingsStore) private var scrollSensitivity: Double = SettingsDefaults.scrollSensitivity

    // Font style - tracked as @State to trigger view refresh on change
    @State private var fontStyle: RetraceFontStyle = RetraceFont.currentStyle

    // Refresh ID to force view recreation when font or color theme changes
    @State private var appearanceRefreshID = UUID()

    // Keyboard shortcuts
    @State private var timelineShortcut = SettingsShortcutKey(from: .defaultTimeline)
    @State private var dashboardShortcut = SettingsShortcutKey(from: .defaultDashboard)
    @State private var recordingShortcut = SettingsShortcutKey(from: .defaultRecording)
    @State private var isRecordingTimelineShortcut = false
    @State private var isRecordingDashboardShortcut = false
    @State private var isRecordingRecordingShortcut = false
    @State private var shortcutError: String? = nil
    @State private var recordingTimeoutTask: Task<Void, Never>? = nil

    // MARK: Capture Settings
    @AppStorage("pauseReminderDelayMinutes", store: settingsStore) private var pauseReminderDelayMinutes: Double = SettingsDefaults.pauseReminderDelayMinutes
    @AppStorage("captureIntervalSeconds", store: settingsStore) private var captureIntervalSeconds: Double = SettingsDefaults.captureIntervalSeconds
    @AppStorage("captureResolution", store: settingsStore) private var captureResolution: CaptureResolution = SettingsDefaults.captureResolution
    @AppStorage("captureActiveDisplayOnly", store: settingsStore) private var captureActiveDisplayOnly = SettingsDefaults.captureActiveDisplayOnly
    @AppStorage("excludeCursor", store: settingsStore) private var excludeCursor = SettingsDefaults.excludeCursor
    @AppStorage("videoQuality", store: settingsStore) private var videoQuality: Double = SettingsDefaults.videoQuality
    @AppStorage("deleteDuplicateFrames", store: settingsStore) private var deleteDuplicateFrames: Bool = SettingsDefaults.deleteDuplicateFrames
    @AppStorage("deduplicationThreshold", store: settingsStore) private var deduplicationThreshold: Double = SettingsDefaults.deduplicationThreshold
    @AppStorage("captureOnWindowChange", store: settingsStore) private var captureOnWindowChange: Bool = SettingsDefaults.captureOnWindowChange

    // MARK: Storage Settings
    @AppStorage("retentionDays", store: settingsStore) private var retentionDays: Int = SettingsDefaults.retentionDays
    @State private var retentionSettingChanged = false
    @State private var retentionChangeProgress: CGFloat = 0  // Progress for auto-dismiss animation (0 to 1)
    @State private var retentionChangeTimer: Timer?
    @State private var showRetentionConfirmation = false
    @State private var pendingRetentionDays: Int?
    @State private var previewRetentionDays: Int?  // Visual preview while selecting
    @AppStorage("maxStorageGB", store: settingsStore) private var maxStorageGB: Double = SettingsDefaults.maxStorageGB
    @AppStorage("useRewindData", store: settingsStore) private var useRewindData: Bool = SettingsDefaults.useRewindData

    // Retention exclusion settings - data from these won't be deleted during cleanup
    @AppStorage("retentionExcludedApps", store: settingsStore) private var retentionExcludedAppsString = ""
    @AppStorage("retentionExcludedTagIds", store: settingsStore) private var retentionExcludedTagIdsString = ""
    @AppStorage("retentionExcludeHidden", store: settingsStore) private var retentionExcludeHidden: Bool = false
    @State private var retentionExcludedAppsPopoverShown = false
    @State private var retentionExcludedTagsPopoverShown = false
    @State private var installedAppsForRetention: [(bundleID: String, name: String)] = []
    @State private var otherAppsForRetention: [(bundleID: String, name: String)] = []
    @State private var availableTagsForRetention: [Tag] = []

    // Database location settings
    @AppStorage("customRetraceDBLocation", store: settingsStore) private var customRetraceDBLocation: String?
    @AppStorage("customRewindDBLocation", store: settingsStore) private var customRewindDBLocation: String?
    @State private var rewindDBLocationChanged = false

    // Track the Retrace DB path the app was launched with (to know if restart is needed)
    @State private var launchedWithRetraceDBPath: String?
    @State private var launchedPathInitialized = false

    // MARK: Privacy Settings
    @AppStorage("excludedApps", store: settingsStore) private var excludedAppsString = SettingsDefaults.excludedApps
    @AppStorage("excludePrivateWindows", store: settingsStore) private var excludePrivateWindows = SettingsDefaults.excludePrivateWindows

    // Computed property to manage excluded apps as array
    private var excludedApps: [ExcludedAppInfo] {
        get {
            guard !excludedAppsString.isEmpty else { return [] }
            guard let data = excludedAppsString.data(using: .utf8),
                  let apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) else {
                return []
            }
            return apps
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let string = String(data: data, encoding: .utf8) else {
                excludedAppsString = ""
                return
            }
            excludedAppsString = string
        }
    }
    @AppStorage("excludeSafariPrivate", store: settingsStore) private var excludeSafariPrivate = SettingsDefaults.excludeSafariPrivate
    @AppStorage("excludeChromeIncognito", store: settingsStore) private var excludeChromeIncognito = SettingsDefaults.excludeChromeIncognito
    @AppStorage("encryptionEnabled", store: settingsStore) private var encryptionEnabled = SettingsDefaults.encryptionEnabled

    // Computed property to manage retention-excluded apps as a Set
    private var retentionExcludedApps: Set<String> {
        get {
            guard !retentionExcludedAppsString.isEmpty else { return [] }
            return Set(retentionExcludedAppsString.split(separator: ",").map { String($0) })
        }
        set {
            retentionExcludedAppsString = newValue.sorted().joined(separator: ",")
        }
    }

    // Computed property to manage retention-excluded tag IDs as a Set
    private var retentionExcludedTagIds: Set<Int64> {
        get {
            guard !retentionExcludedTagIdsString.isEmpty else { return [] }
            return Set(retentionExcludedTagIdsString.split(separator: ",").compactMap { Int64($0) })
        }
        set {
            retentionExcludedTagIdsString = newValue.sorted().map { String($0) }.joined(separator: ",")
        }
    }

    // MARK: Developer Settings
    @AppStorage("showFrameIDs", store: settingsStore) private var showFrameIDs = SettingsDefaults.showFrameIDs
    @AppStorage("enableFrameIDSearch", store: settingsStore) private var enableFrameIDSearch = SettingsDefaults.enableFrameIDSearch
    @AppStorage("showOCRDebugOverlay", store: settingsStore) private var showOCRDebugOverlay = SettingsDefaults.showOCRDebugOverlay
    @AppStorage("showVideoControls", store: settingsStore) private var showVideoControls = SettingsDefaults.showVideoControls

    // MARK: OCR Power Settings
    @AppStorage("ocrEnabled", store: settingsStore) private var ocrEnabled = SettingsDefaults.ocrEnabled
    @AppStorage("ocrOnlyWhenPluggedIn", store: settingsStore) private var ocrOnlyWhenPluggedIn = SettingsDefaults.ocrOnlyWhenPluggedIn
    @AppStorage("ocrMaxFramesPerSecond", store: settingsStore) private var ocrMaxFramesPerSecond = SettingsDefaults.ocrMaxFramesPerSecond
    @AppStorage("ocrAppFilterMode", store: settingsStore) private var ocrAppFilterMode: OCRAppFilterMode = SettingsDefaults.ocrAppFilterMode
    @AppStorage("ocrFilteredApps", store: settingsStore) private var ocrFilteredAppsString = SettingsDefaults.ocrFilteredApps
    @State private var ocrFilteredAppsPopoverShown = false
    @State private var installedAppsForOCR: [(bundleID: String, name: String)] = []
    @State private var otherAppsForOCR: [(bundleID: String, name: String)] = []
    @State private var currentPowerSource: PowerStateMonitor.PowerSource = .unknown
    @State private var pendingOCRFrameCount: Int = 0

    // MARK: Tag Management
    @State private var tagsForSettings: [Tag] = []
    @State private var tagSegmentCounts: [TagID: Int] = [:]
    @State private var tagToDelete: Tag? = nil
    @State private var showTagDeleteConfirmation = false
    @State private var newTagName: String = ""
    @State private var isCreatingTag = false
    @State private var tagCreationError: String? = nil

    // Check if Rewind data folder exists
    private var rewindDataExists: Bool {
        return FileManager.default.fileExists(atPath: AppPaths.expandedRewindStorageRoot)
    }

    // Check if Retrace database location is accessible
    private var retraceDBAccessible: Bool {
        let path = customRetraceDBLocation ?? AppPaths.defaultStorageRoot
        return FileManager.default.fileExists(atPath: path)
    }

    // Check if Rewind database is accessible
    private var rewindDBAccessible: Bool {
        let path = customRewindDBLocation ?? AppPaths.defaultRewindDBPath
        return FileManager.default.fileExists(atPath: path)
    }

    // Permission states
    @State private var hasScreenRecordingPermission = false
    @State private var hasAccessibilityPermission = false

    // Quick delete state
    @State private var quickDeleteConfirmation: QuickDeleteOption? = nil
    @State private var deletingOption: QuickDeleteOption? = nil
    @State private var isDeleting = false
    @State private var deleteResult: DeleteResultInfo? = nil

    // Danger zone confirmation states
    @State private var showingResetConfirmation = false
    @State private var showingDeleteConfirmation = false

    // Database schema display
    @State private var showingDatabaseSchema = false
    @State private var databaseSchemaText: String = ""

    // Cache clear feedback
    @State private var cacheClearMessage: String? = nil

    // Compression settings feedback
    @State private var compressionUpdateMessage: String? = nil

    // Scrubbing animation settings feedback
    @State private var scrubbingAnimationUpdateMessage: String? = nil

    // Capture interval settings feedback
    @State private var captureUpdateMessage: String? = nil

    // Excluded apps feedback
    @State private var excludedAppsUpdateMessage: String? = nil

    // App coordinator for deletion operations
    @EnvironmentObject private var coordinatorWrapper: AppCoordinatorWrapper

    // Observe UpdaterManager for automatic updates toggle
    @ObservedObject private var updaterManager = UpdaterManager.shared

    // MARK: - Body

    /// Max width for the entire settings panel before it detaches and centers
    private let settingsMaxWidth: CGFloat = 1200

    public var body: some View {
        GeometryReader { geometry in
            let windowWidth = geometry.size.width
            let detached = windowWidth > settingsMaxWidth
            let _ = Self.logSettingsLayout(windowWidth: windowWidth)

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
        .frame(minWidth: 900, minHeight: 650)
        .background(
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
        )
        .onAppear {
            // Capture the Retrace DB path the app was launched with (only once)
            if !launchedPathInitialized {
                launchedWithRetraceDBPath = customRetraceDBLocation
                launchedPathInitialized = true
            }

            // Sync launch at login toggle with actual system state
            let systemLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            if launchAtLogin != systemLaunchAtLoginEnabled {
                launchAtLogin = systemLaunchAtLoginEnabled
            }
        }
        .onChange(of: timelineShortcut) { _ in
            Task { await saveShortcuts() }
        }
        .onChange(of: dashboardShortcut) { _ in
            Task { await saveShortcuts() }
        }
        .onChange(of: recordingShortcut) { _ in
            Task { await saveShortcuts() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsPower)) { _ in
            selectedTab = .power
        }
    }

    /// Returns true if the current Retrace DB setting differs from what the app launched with
    private var retraceDBLocationChanged: Bool {
        guard launchedPathInitialized else { return false }
        return customRetraceDBLocation != launchedWithRetraceDBPath
    }

    /// Confirmation message for retention policy change
    private var retentionConfirmationMessage: String {
        guard let pendingDays = pendingRetentionDays else {
            return ""
        }
        if pendingDays == 0 {
            return "Are you sure you want to change the retention policy to Forever? All data will be kept indefinitely."
        } else {
            let cutoffDate = Date().addingTimeInterval(-TimeInterval(pendingDays) * 86400)
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"

            // Build exclusions summary
            var exclusions: [String] = []
            if !retentionExcludedApps.isEmpty {
                let appNames = retentionExcludedApps.compactMap { bundleID in
                    installedAppsForRetention.first(where: { $0.bundleID == bundleID })?.name
                        ?? otherAppsForRetention.first(where: { $0.bundleID == bundleID })?.name
                        ?? bundleID
                }
                exclusions.append("Apps: \(appNames.joined(separator: ", "))")
            }
            if !retentionExcludedTagIds.isEmpty {
                let tagNames = retentionExcludedTagIds.compactMap { tagId in
                    availableTagsForRetention.first(where: { $0.id.value == tagId })?.name
                }
                if !tagNames.isEmpty {
                    exclusions.append("Tags: \(tagNames.joined(separator: ", "))")
                }
            }
            if retentionExcludeHidden {
                exclusions.append("Hidden items")
            }

            var message = "All data before \(formatter.string(from: cutoffDate))"
            if exclusions.isEmpty {
                message += " will be deleted."
            } else {
                message += " that is not in your exclusions will be deleted.\n\nExclusions:\n• \(exclusions.joined(separator: "\n• "))"
            }

            return message
        }
    }

    /// Theme-aware base background color
    /// Gold theme uses a warmer, darker tone that complements gold better than blue
    private var themeBaseBackground: Color {
        let theme = MilestoneCelebrationManager.getCurrentTheme()

        switch theme {
        case .gold:
            // Warm dark brown/slate that complements gold
            return Color(red: 15/255, green: 12/255, blue: 8/255)
        default:
            // Default deep blue for all other themes
            return Color.retraceBackground
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with separate back button
            HStack(spacing: 12) {
                // Back button - distinct and easy to click
                Button(action: {
                    NotificationCenter.default.post(name: .openDashboard, object: nil)
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .keyboardShortcut("[", modifiers: .command)

                Text("Settings")
                    .font(.retraceTitle3)
                    .foregroundColor(.retracePrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)

            // Navigation items
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarButton(tab: tab)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            // Version info
            VStack(spacing: 4) {
                Text("Retrace")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)
                #if DEBUG
                Text("Dev Version")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary.opacity(0.6))
                #else
                Text("v\(UpdaterManager.shared.currentVersion)")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary.opacity(0.6))
                #endif
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)
        }
        .background(Color.white.opacity(0.02))
    }

    private func sidebarButton(tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        let isHovered = hoveredTab == tab

        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 12) {
                // Icon with gradient for selected
                ZStack {
                    if isSelected {
                        Circle()
                            .fill(tab.gradient.opacity(0.2))
                            .frame(width: 32, height: 32)
                    }

                    Image(systemName: tab.icon)
                        .font(.retraceCalloutMedium)
                        .foregroundStyle(isSelected ? tab.gradient : LinearGradient(colors: [.retraceSecondary], startPoint: .top, endPoint: .bottom))
                }
                .frame(width: 32, height: 32)

                Text(tab.rawValue)
                    .font(isSelected ? .retraceCalloutBold : .retraceCalloutMedium)
                    .foregroundColor(isSelected ? .retracePrimary : .retraceSecondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.white.opacity(0.08) : (isHovered ? Color.white.opacity(0.04) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredTab = hovering ? tab : nil
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Content header
                contentHeader

                // Settings content
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedTab {
                    case .general:
                        generalSettings
                    case .capture:
                        captureSettings
                    case .storage:
                        storageSettings
                    case .exportData:
                        exportDataSettings
                    case .privacy:
                        privacySettings
                    case .power:
                        powerSettings
                    case .tags:
                        tagManagementSettings
                    case .advanced:
                        advancedSettings
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
    }

    private var contentHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(selectedTab.gradient.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: selectedTab.icon)
                        .font(.retraceHeadline)
                        .foregroundStyle(selectedTab.gradient)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTab.rawValue)
                        .font(.retraceMediumNumber)
                        .foregroundColor(.retracePrimary)

                    Text(selectedTab.description)
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer()

                // System Monitor button (only for Power tab)
                if selectedTab == .power {
                    Button(action: {
                        NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 12))
                            Text("System Monitor")
                                .font(.retraceCaption2)
                        }
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                // Reset section button (only for sections with resettable settings)
                if let resetAction = selectedTab.resetAction(for: self) {
                    Button(action: resetAction) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12))
                            Text("Reset to Defaults")
                                .font(.retraceCaption2)
                        }
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 28)
    }

    // MARK: - General Settings

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModernSettingsCard(title: "Keyboard Shortcuts", icon: "command") {
                VStack(spacing: 12) {
                    settingsShortcutRecorderRow(
                        label: "Open Timeline",
                        shortcut: $timelineShortcut,
                        isRecording: $isRecordingTimelineShortcut,
                        otherShortcuts: [dashboardShortcut, recordingShortcut]
                    )

                    Divider()
                        .background(Color.retraceBorder)

                    settingsShortcutRecorderRow(
                        label: "Open Dashboard",
                        shortcut: $dashboardShortcut,
                        isRecording: $isRecordingDashboardShortcut,
                        otherShortcuts: [timelineShortcut, recordingShortcut]
                    )

                    Divider()
                        .background(Color.retraceBorder)

                    settingsShortcutRecorderRow(
                        label: "Toggle Recording",
                        shortcut: $recordingShortcut,
                        isRecording: $isRecordingRecordingShortcut,
                        otherShortcuts: [timelineShortcut, dashboardShortcut]
                    )

                    if let error = shortcutError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.retraceTiny)
                                .foregroundColor(.retraceWarning)
                            Text(error)
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceWarning)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Cancel recording if user clicks outside
                if isRecordingTimelineShortcut || isRecordingDashboardShortcut || isRecordingRecordingShortcut {
                    isRecordingTimelineShortcut = false
                    isRecordingDashboardShortcut = false
                    isRecordingRecordingShortcut = false
                    recordingTimeoutTask?.cancel()
                }
            }
            .task {
                // Load saved shortcuts on appear
                await loadSavedShortcuts()
            }

            ModernSettingsCard(title: "Updates", icon: "arrow.down.circle") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Check for Updates")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)

                        if let lastCheck = UpdaterManager.shared.lastUpdateCheckDate {
                            Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                        } else {
                            Text("Automatically checks for updates")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                        }
                    }

                    Spacer()

                    ModernButton(
                        title: UpdaterManager.shared.isCheckingForUpdates ? "Checking..." : "Check Now",
                        icon: "arrow.clockwise",
                        style: .secondary
                    ) {
                        UpdaterManager.shared.checkForUpdates()
                    }
                    .disabled(UpdaterManager.shared.isCheckingForUpdates || !UpdaterManager.shared.canCheckForUpdates)
                }

                ModernToggleRow(
                    title: "Automatic Updates",
                    subtitle: "Automatically download and install updates",
                    isOn: $updaterManager.automaticUpdatesEnabled
                )
            }

            ModernSettingsCard(title: "Startup", icon: "power") {
                ModernToggleRow(
                    title: "Launch at Login",
                    subtitle: "Start Retrace automatically when you log in",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { newValue in
                    setLaunchAtLogin(enabled: newValue)
                }

                ModernToggleRow(
                    title: "Show Menu Bar Icon",
                    subtitle: "Quick access from your menu bar",
                    isOn: $showMenuBarIcon
                )
                .onChange(of: showMenuBarIcon) { newValue in
                    setMenuBarIconVisibility(visible: newValue)
                }
            }

            ModernSettingsCard(title: "Appearance", icon: "paintbrush") {
                VStack(alignment: .leading, spacing: 24) {
                    // Font Style Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Font Style")
                                    .font(.retraceCalloutMedium)
                                    .foregroundColor(.retracePrimary)

                                Text("Choose your preferred font style")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary)
                            }

                            Spacer()

                            // Reset to default button
                            if fontStyle != SettingsDefaults.fontStyle {
                                Button(action: {
                                    fontStyle = SettingsDefaults.fontStyle
                                    RetraceFont.currentStyle = SettingsDefaults.fontStyle
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 10))
                                        Text("Reset to Default")
                                            .font(.retraceCaption2)
                                    }
                                    .foregroundColor(.white.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        FontStylePicker(selection: $fontStyle)
                            .onChange(of: fontStyle) { newStyle in
                                RetraceFont.currentStyle = newStyle
                            }
                    }

                    Divider()
                        .background(Color.retraceBorder)

                    // Tier Theme Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Accent Color")
                                    .font(.retraceCalloutMedium)
                                    .foregroundColor(.retracePrimary)

                                Text("Choose your preferred color theme")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary)
                            }

                            Spacer()

                            // Reset to default button
                            if colorThemePreference != SettingsDefaults.colorTheme {
                                Button(action: {
                                    colorThemePreference = SettingsDefaults.colorTheme
                                    MilestoneCelebrationManager.setColorThemePreference(.blue)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 10))
                                        Text("Reset to Default")
                                            .font(.retraceCaption2)
                                    }
                                    .foregroundColor(.white.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        ColorThemePicker(
                            selection: Binding(
                                get: {
                                    MilestoneCelebrationManager.ColorTheme(rawValue: colorThemePreference) ?? .blue
                                },
                                set: { newValue in
                                    colorThemePreference = newValue.rawValue
                                    MilestoneCelebrationManager.setColorThemePreference(newValue)
                                }
                            )
                        )
                    }

                    ModernToggleRow(
                        title: "Timeline colored button borders",
                        subtitle: "Show accent-colored borders on timeline control buttons",
                        isOn: $timelineColoredBorders
                    )

                    Divider()
                        .background(Color.retraceBorder)

                    // Scrubbing Animation Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Scrubbing animation")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retracePrimary)
                            Spacer()
                            Text(scrubbingAnimationDisplayText)
                                .font(.retraceCalloutBold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.retraceAccent.opacity(0.3))
                                .cornerRadius(8)
                        }

                        ModernSlider(value: $scrubbingAnimationDuration, range: 0...0.20, step: 0.01)
                            .onChange(of: scrubbingAnimationDuration) { _ in
                                showScrubbingAnimationUpdateFeedback()
                            }

                        HStack {
                            Text(scrubbingAnimationDescriptionText)
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))

                            Spacer()

                            if scrubbingAnimationDuration != SettingsDefaults.scrubbingAnimationDuration {
                                Button(action: {
                                    scrubbingAnimationDuration = SettingsDefaults.scrubbingAnimationDuration
                                    showScrubbingAnimationUpdateFeedback()
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 10))
                                        Text("Reset to Default")
                                            .font(.retraceCaption2)
                                    }
                                    .foregroundColor(.white.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Update feedback message
                        if let message = scrubbingAnimationUpdateMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 12))
                                Text(message)
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: scrubbingAnimationUpdateMessage)

                    Divider()
                        .background(Color.retraceBorder)

                    // Scroll Sensitivity Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Scroll sensitivity")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retracePrimary)
                            Spacer()
                            Text(scrollSensitivityDisplayText)
                                .font(.retraceCalloutBold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.retraceAccent.opacity(0.3))
                                .cornerRadius(8)
                        }

                        ModernSlider(value: $scrollSensitivity, range: 0.1...1.0, step: 0.05)

                        HStack {
                            Text(scrollSensitivityDescriptionText)
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))

                            Spacer()

                            if scrollSensitivity != SettingsDefaults.scrollSensitivity {
                                Button(action: {
                                    scrollSensitivity = SettingsDefaults.scrollSensitivity
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 10))
                                        Text("Reset to Default")
                                            .font(.retraceCaption2)
                                    }
                                    .foregroundColor(.white.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shortcut Recorder Row

    private func settingsShortcutRecorderRow(
        label: String,
        shortcut: Binding<SettingsShortcutKey>,
        isRecording: Binding<Bool>,
        otherShortcuts: [SettingsShortcutKey]
    ) -> some View {
        HStack {
            Text(label)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retracePrimary)

            Spacer()

            // Shortcut display/recorder button
            Button(action: {
                // Cancel any other recording first
                isRecordingTimelineShortcut = false
                isRecordingDashboardShortcut = false
                isRecordingRecordingShortcut = false
                shortcutError = nil
                recordingTimeoutTask?.cancel()

                // Then start this one
                isRecording.wrappedValue = true

                // Start 10 second timeout
                recordingTimeoutTask = Task {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if !Task.isCancelled {
                        await MainActor.run {
                            isRecording.wrappedValue = false
                        }
                    }
                }
            }) {
                Group {
                    if isRecording.wrappedValue {
                        Text("Press keys...")
                            .font(.retraceCaption2)
                            .foregroundColor(.white)
                            .frame(minWidth: 100, minHeight: 24)
                    } else if shortcut.wrappedValue.isEmpty {
                        Text("None")
                            .font(.retraceCaption2)
                            .foregroundColor(.white.opacity(0.5))
                            .frame(minWidth: 60, minHeight: 24)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(shortcut.wrappedValue.modifierSymbols, id: \.self) { symbol in
                                Text(symbol)
                                    .font(.retraceCaptionMedium)
                                    .foregroundColor(.white.opacity(0.9))
                                    .frame(width: 22, height: 22)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(4)
                            }

                            if !shortcut.wrappedValue.modifierSymbols.isEmpty {
                                Text("+")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.white.opacity(0.7))
                            }

                            Text(shortcut.wrappedValue.key)
                                .font(.retraceCaption2Bold)
                                .foregroundColor(.white)
                                .frame(minWidth: 28, minHeight: 22)
                                .padding(.horizontal, 6)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isRecording.wrappedValue ? Color.white.opacity(0.1) : Color.white.opacity(0.05))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording.wrappedValue ? Color.white : Color.white.opacity(0.2), lineWidth: isRecording.wrappedValue ? 1.5 : 1)
                )
            }
            .buttonStyle(.plain)
            .background(
                SettingsShortcutCaptureField(
                    isRecording: isRecording,
                    capturedShortcut: shortcut,
                    otherShortcuts: otherShortcuts,
                    onDuplicateAttempt: {
                        shortcutError = "This shortcut is already in use"
                    },
                    onShortcutCaptured: {
                        // Saving is now handled by .onChange modifiers
                    }
                )
                .frame(width: 0, height: 0)
            )

            // Clear button (×)
            if !shortcut.wrappedValue.isEmpty && !isRecording.wrappedValue {
                Button(action: {
                    shortcut.wrappedValue = .empty
                    // Saving is now handled by .onChange modifiers
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
    }

    // MARK: - Shortcut Persistence

    private static let timelineShortcutKey = "timelineShortcutConfig"
    private static let dashboardShortcutKey = "dashboardShortcutConfig"
    private static let recordingShortcutKey = "recordingShortcutConfig"

    private func loadSavedShortcuts() async {
        // Load directly from UserDefaults (same as OnboardingManager)
        if let data = settingsStore.data(forKey: Self.timelineShortcutKey),
           let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) {
            timelineShortcut = SettingsShortcutKey(from: config)
        }
        if let data = settingsStore.data(forKey: Self.dashboardShortcutKey),
           let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) {
            dashboardShortcut = SettingsShortcutKey(from: config)
        }
        if let data = settingsStore.data(forKey: Self.recordingShortcutKey),
           let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) {
            recordingShortcut = SettingsShortcutKey(from: config)
        }
    }

    private func saveShortcuts() async {
        if let data = try? JSONEncoder().encode(timelineShortcut.toConfig) {
            settingsStore.set(data, forKey: Self.timelineShortcutKey)
        }
        if let data = try? JSONEncoder().encode(dashboardShortcut.toConfig) {
            settingsStore.set(data, forKey: Self.dashboardShortcutKey)
        }
        if let data = try? JSONEncoder().encode(recordingShortcut.toConfig) {
            settingsStore.set(data, forKey: Self.recordingShortcutKey)
        }
        settingsStore.synchronize()
        MenuBarManager.shared?.reloadShortcuts()
    }

    // MARK: - Capture Settings

    private var captureSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModernSettingsCard(title: "Capture Rate", icon: "gauge.with.dots.needle.50percent") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Capture interval")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        Text(captureIntervalDisplayText)
                            .font(.retraceCalloutBold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.retraceAccent.opacity(0.3))
                            .cornerRadius(8)
                    }

                    CaptureIntervalPicker(selectedInterval: $captureIntervalSeconds)
                        .onChange(of: captureIntervalSeconds) { _ in
                            showCaptureUpdateFeedback()
                        }

                    // Estimated storage description and reset button on same line
                    HStack {
                        Text(captureIntervalEstimateText)
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.7))

                        Spacer()

                        // Reset to default button
                        if captureIntervalSeconds != SettingsDefaults.captureIntervalSeconds {
                            Button(action: {
                                captureIntervalSeconds = SettingsDefaults.captureIntervalSeconds
                                showCaptureUpdateFeedback()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 10))
                                    Text("Reset to Default")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Update feedback message
                    if let message = captureUpdateMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                            Text(message)
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Divider()
                        .background(Color.white.opacity(0.1))

                    // Capture on window change toggle
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Capture on window change")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retracePrimary)
                            Text("Instantly capture when switching apps or windows")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))
                        }
                        Spacer()
                        Toggle("", isOn: $captureOnWindowChange)
                            .toggleStyle(SwitchToggleStyle(tint: .retraceAccent))
                            .labelsHidden()
                            .onChange(of: captureOnWindowChange) { _ in
                                updateCaptureOnWindowChangeSetting()
                            }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: captureUpdateMessage)
            }

            ModernSettingsCard(title: "Compression", icon: "archivebox") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Video quality")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        Text(videoQualityDisplayText)
                            .font(.retraceCalloutBold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.retraceAccent.opacity(0.3))
                            .cornerRadius(8)
                    }

                    ModernSlider(value: $videoQuality, range: 0...1, step: 0.05)
                        .onChange(of: videoQuality) { _ in
                            showCompressionUpdateFeedback()
                        }

                    // Estimated storage description and reset button on same line
                    HStack {
                        Text(videoQualityEstimateText)
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.7))

                        Spacer()

                        // Reset to default button
                        if videoQuality != SettingsDefaults.videoQuality {
                            Button(action: {
                                videoQuality = SettingsDefaults.videoQuality
                                showCompressionUpdateFeedback()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 10))
                                    Text("Reset to Default")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider()
                        .background(Color.white.opacity(0.1))

                    // Deduplication slider
                    HStack {
                        Text("Deduplication")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        Text(deduplicationThresholdDisplayText)
                            .font(.retraceCalloutBold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.retraceAccent.opacity(0.3))
                            .cornerRadius(8)
                    }

                    ModernSlider(value: $deduplicationThreshold, range: 0.98...1.0, step: 0.0001)
                        .onChange(of: deduplicationThreshold) { newValue in
                            updateDeduplicationThreshold()
                            // Sync the boolean flag for backwards compatibility
                            deleteDuplicateFrames = newValue < 1.0
                        }

                    // Sensitivity description and reset button on same line
                    HStack {
                        Text(deduplicationSensitivityText)
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.7))

                        Spacer()

                        // Reset to default button
                        if deduplicationThreshold != SettingsDefaults.deduplicationThreshold {
                            Button(action: {
                                deduplicationThreshold = SettingsDefaults.deduplicationThreshold
                                deleteDuplicateFrames = SettingsDefaults.deleteDuplicateFrames
                                updateDeduplicationThreshold()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 10))
                                    Text("Reset to Default")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Update feedback message
                    if let message = compressionUpdateMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                            Text(message)
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: compressionUpdateMessage)
            }

            ModernSettingsCard(title: "Pause Reminder", icon: "bell.badge") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("\"Remind Me Later\" interval")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        Text(pauseReminderDisplayText)
                            .font(.retraceCalloutBold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.retraceAccent.opacity(0.3))
                            .cornerRadius(8)
                    }

                    PauseReminderDelayPicker(selectedMinutes: $pauseReminderDelayMinutes)

                    HStack {
                        Text("How long to wait before reminding you again when capture is paused")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.7))

                        Spacer()

                        if pauseReminderDelayMinutes != SettingsDefaults.pauseReminderDelayMinutes {
                            Button(action: {
                                pauseReminderDelayMinutes = SettingsDefaults.pauseReminderDelayMinutes
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 10))
                                    Text("Reset to Default")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // TODO: Re-enable when using ScreenCaptureKit (CGWindowList doesn't support cursor capture)
//            ModernSettingsCard(title: "Display Options", icon: "display") {
//                ModernToggleRow(
//                    title: "Exclude Cursor",
//                    subtitle: "Hide the mouse cursor in captures",
//                    isOn: $excludeCursor
//                )
//            }

            // TODO: Add Auto-Pause settings later
//            ModernSettingsCard(title: "Auto-Pause", icon: "pause.circle") {
//                ModernToggleRow(
//                    title: "Screen is locked",
//                    subtitle: "Pause recording when your Mac is locked",
//                    isOn: .constant(true)
//                )
//
//                ModernToggleRow(
//                    title: "On battery (< 20%)",
//                    subtitle: "Pause when battery is critically low",
//                    isOn: .constant(false)
//                )
//
//                ModernToggleRow(
//                    title: "Idle for 10 minutes",
//                    subtitle: "Pause after extended inactivity",
//                    isOn: .constant(false)
//                )
//            }
        }
    }

    // MARK: - Storage Settings

    private var storageSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Rewind Data Source
            ModernSettingsCard(title: "Rewind Data", icon: "arrow.counterclockwise") {
                ModernToggleRow(
                    title: "Use Rewind data",
                    subtitle: "Show your old Rewind recordings in the timeline",
                    isOn: Binding(
                        get: { useRewindData },
                        set: { newValue in
                            Log.debug("[SettingsView] Rewind data toggle changed to: \(newValue)", category: .ui)
                            useRewindData = newValue
                            Task {
                                Log.debug("[SettingsView] Calling setRewindSourceEnabled(\(newValue))", category: .ui)
                                await coordinatorWrapper.coordinator.setRewindSourceEnabled(newValue)
                                Log.debug("[SettingsView] setRewindSourceEnabled completed", category: .ui)
                                // Increment data source version to invalidate timeline cache
                                // This ensures any cached frames are discarded when timeline reopens
                                await MainActor.run {
                                    // Clear persisted search cache so search results are cleared
                                    SearchViewModel.clearPersistedSearchCache()
                                    // Notify any live timeline instances to reload
                                    NotificationCenter.default.post(name: .dataSourceDidChange, object: nil)
                                    Log.debug("[SettingsView] dataSourceDidChange notification posted", category: .ui)
                                }
                            }
                        }
                    )
                )
            }

            ModernSettingsCard(title: "Database Locations", icon: "externaldrive") {
                VStack(alignment: .leading, spacing: 16) {
                    // Warning when recording is active (only for Retrace)
                    if coordinatorWrapper.isRunning {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 12))
                            Text("Stop recording to change Retrace database location")
                                .font(.retraceCaption)
                                .foregroundColor(.retraceSecondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }

                    // Retrace Database Location
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("Retrace Database Folder")
                                        .font(.retraceCalloutMedium)
                                        .foregroundColor(.retracePrimary)
                                    PingDotView(
                                        color: retraceDBAccessible ? .green : .orange,
                                        size: 8,
                                        isAnimating: retraceDBAccessible
                                    )
                                }
                                HStack(spacing: 4) {
                                    Text(customRetraceDBLocation ?? AppPaths.defaultStorageRoot)
                                        .font(.retraceCaption2)
                                        .foregroundColor(retraceDBAccessible ? .retraceSecondary : .orange)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if !retraceDBAccessible {
                                        Text("(not found)")
                                            .font(.retraceCaption2)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                            Spacer()
                            Button("Choose Folder...") {
                                selectRetraceDBLocation()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .disabled(coordinatorWrapper.isRunning)
                            .help(coordinatorWrapper.isRunning ? "Stop recording to change Retrace database location" : "Select a folder to store the Retrace database")
                        }
                        Text("Select a folder where retrace.db will be stored")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.7))

                        // Restart prompt directly under Retrace Database if it changed
                        if retraceDBLocationChanged {
                            HStack(spacing: 8) {
                                Text("Restart the app to apply Retrace database changes")
                                    .font(.retraceCaption)
                                    .foregroundColor(.retraceSecondary)
                                Spacer()
                                Button(action: restartApp) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 10))
                                        Text("Restart")
                                            .font(.retraceCaption)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.retraceAccent)
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(Color.retraceAccent.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }

                    // Rewind Database Location (only shown when Use Rewind data is enabled)
                    if useRewindData {
                        Divider()
                            .background(Color.white.opacity(0.1))

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("Rewind Database")
                                            .font(.retraceCalloutMedium)
                                            .foregroundColor(.retracePrimary)
                                        PingDotView(
                                            color: rewindDBAccessible ? .green : .orange,
                                            size: 8,
                                            isAnimating: rewindDBAccessible
                                        )
                                    }
                                    HStack(spacing: 4) {
                                        Text(customRewindDBLocation ?? AppPaths.defaultRewindDBPath)
                                            .font(.retraceCaption2)
                                            .foregroundColor(rewindDBAccessible ? .retraceSecondary : .orange)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if !rewindDBAccessible {
                                            Text("(not found)")
                                                .font(.retraceCaption2)
                                                .foregroundColor(.orange)
                                        }
                                    }
                                }
                                Spacer()
                                Button("Choose File...") {
                                    selectRewindDBLocation()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .help("Select the db-enc.sqlite3 file from your Rewind installation")
                            }
                            Text("Select db-enc.sqlite3 file (chunks folder must be in same directory)")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))
                        }
                    }

                    if customRetraceDBLocation != nil || (useRewindData && customRewindDBLocation != nil) {
                        Divider()
                            .background(Color.white.opacity(0.1))

                        Button(action: resetDatabaseLocations) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12))
                                Text("Reset to Defaults")
                                    .font(.retraceCalloutMedium)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(coordinatorWrapper.isRunning && customRetraceDBLocation != nil)
                        .help(coordinatorWrapper.isRunning && customRetraceDBLocation != nil ? "Stop recording to reset Retrace database location" : "")
                    }
                }
            }

            ModernSettingsCard(title: "Retention Policy", icon: "calendar.badge.clock") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Keep recordings for")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retracePrimary)
                            if useRewindData {
                                (Text("Only applies to Retrace data, not Rewind data. To remove Rewind data, go to ")
                                    .foregroundColor(.retraceSecondary) +
                                Text("Export & Data")
                                    .foregroundColor(.retraceAccent)
                                    .underline())
                                    .font(.retraceCaption)
                            }
                        }
                        Spacer()
                        Text(retentionDisplayTextFor(previewRetentionDays ?? retentionDays))
                            .font(.retraceCalloutBold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.retraceAccent.opacity(0.3))
                            .cornerRadius(8)
                    }

                    RetentionPolicyPicker(
                        displayDays: previewRetentionDays ?? retentionDays,
                        onPreviewChange: { newDays in
                            previewRetentionDays = newDays
                        },
                        onSelectionEnd: { newDays in
                            if newDays != retentionDays {
                                // Check if new policy is MORE restrictive (would delete data)
                                // More restrictive = shorter retention period
                                // Note: 0 means "Forever" (least restrictive)
                                let isMoreRestrictive: Bool
                                if retentionDays == 0 {
                                    // Going from Forever to any limit is more restrictive
                                    isMoreRestrictive = true
                                } else if newDays == 0 {
                                    // Going to Forever is less restrictive
                                    isMoreRestrictive = false
                                } else {
                                    // Both are limited: smaller number = more restrictive
                                    isMoreRestrictive = newDays < retentionDays
                                }

                                if isMoreRestrictive {
                                    // Show confirmation before deleting data
                                    pendingRetentionDays = newDays
                                    showRetentionConfirmation = true
                                } else {
                                    // Less restrictive (keeping more data) - apply directly without confirmation
                                    retentionDays = newDays
                                    previewRetentionDays = nil
                                }
                            } else {
                                // User dragged back to original value, just reset preview
                                previewRetentionDays = nil
                            }
                        }
                    )

                    // Reset to default button (default is Forever = 0)
                    if retentionDays != SettingsDefaults.retentionDays {
                        HStack {
                            Spacer()
                            Button(action: {
                                retentionDays = SettingsDefaults.retentionDays
                                previewRetentionDays = nil
                                retentionSettingChanged = true
                                startRetentionChangeTimer()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 10))
                                    Text("Reset to Default")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if retentionSettingChanged {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Changes will take effect within an hour or on next launch")
                                    .font(.retraceCaption)
                                    .foregroundColor(.retraceSecondary)
                                Spacer()
                                Button("Restart Now") {
                                    dismissRetentionChangeNotification()
                                    restartApp()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.retraceAccent)
                                .controlSize(.small)
                            }

                            // Auto-dismiss progress bar (Cloudflare-style)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    // Background track
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.1))
                                        .frame(height: 3)

                                    // Progress fill
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.retraceAccent.opacity(0.6))
                                        .frame(width: geometry.size.width * retentionChangeProgress, height: 3)
                                }
                            }
                            .frame(height: 3)
                        }
                        .onAppear {
                            startRetentionChangeTimer()
                        }
                        .onDisappear {
                            retentionChangeTimer?.invalidate()
                            retentionChangeTimer = nil
                        }
                        .onChange(of: retentionDays) { _ in
                            // Restart the timer if retention value changes while notification is showing
                            startRetentionChangeTimer()
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // TODO: Re-enable retention exclusions in a future version
                    // Retention Exclusions - data from these won't be auto-deleted
                    // VStack(alignment: .leading, spacing: 12) {
                    //     HStack(spacing: 8) {
                    //         Text("Retention Exclusions")
                    //             .font(.retraceCalloutMedium)
                    //             .foregroundColor(.retracePrimary)
                    //     }
                    //
                    //     Text(retentionDays == 0
                    //         ? "When a retention period is set, data from these apps and tags will be kept forever."
                    //         : "Data from these apps and tags will be kept forever, even when older data is deleted.")
                    //         .font(.retraceCaption)
                    //         .foregroundColor(.retraceSecondary)
                    //
                    //     // Apps and Tags in horizontal layout
                    //     HStack(spacing: 12) {
                    //         // Apps exclusion
                    //         VStack(alignment: .leading, spacing: 6) {
                    //             Text("Excluded Apps")
                    //                 .font(.retraceCaption)
                    //                 .foregroundColor(.retraceSecondary)
                    //
                    //             RetentionAppsChip(
                    //                 selectedApps: retentionExcludedApps,
                    //                 isPopoverShown: $retentionExcludedAppsPopoverShown
                    //             ) {
                    //                 AppsFilterPopover(
                    //                     apps: installedAppsForRetention,
                    //                     otherApps: otherAppsForRetention,
                    //                     selectedApps: retentionExcludedApps.isEmpty ? nil : retentionExcludedApps,
                    //                     filterMode: .include,
                    //                     allowMultiSelect: true,
                    //                     showAllOption: false,
                    //                     onSelectApp: { bundleID in
                    //                         toggleRetentionExcludedApp(bundleID)
                    //                     },
                    //                     onFilterModeChange: nil,
                    //                     onDismiss: { retentionExcludedAppsPopoverShown = false }
                    //                 )
                    //             }
                    //         }
                    //
                    //         // Tags exclusion
                    //         VStack(alignment: .leading, spacing: 6) {
                    //             Text("Excluded Tags")
                    //                 .font(.retraceCaption)
                    //                 .foregroundColor(.retraceSecondary)
                    //
                    //             RetentionTagsChip(
                    //                 selectedTagIds: retentionExcludedTagIds,
                    //                 availableTags: availableTagsForRetention,
                    //                 isPopoverShown: $retentionExcludedTagsPopoverShown
                    //             ) {
                    //                 TagsFilterPopover(
                    //                     tags: availableTagsForRetention,
                    //                     selectedTags: retentionExcludedTagIds.isEmpty ? nil : retentionExcludedTagIds,
                    //                     filterMode: .include,
                    //                     allowMultiSelect: true,
                    //                     showAllOption: false,
                    //                     onSelectTag: { tagID in
                    //                         toggleRetentionExcludedTag(tagID)
                    //                     },
                    //                     onFilterModeChange: nil,
                    //                     onDismiss: { retentionExcludedTagsPopoverShown = false }
                    //                 )
                    //             }
                    //         }
                    //
                    //         // Hidden items chip
                    //         VStack(alignment: .leading, spacing: 6) {
                    //             Text("Hidden")
                    //                 .font(.retraceCaption)
                    //                 .foregroundColor(.retraceSecondary)
                    //
                    //             Button(action: {
                    //                 retentionExcludeHidden.toggle()
                    //             }) {
                    //                 HStack(spacing: 8) {
                    //                     Image(systemName: "eye.slash.fill")
                    //                         .font(.system(size: 12))
                    //                     Text(retentionExcludeHidden ? "Excluded" : "Not excluded")
                    //                         .font(.retraceCaptionMedium)
                    //                     Image(systemName: retentionExcludeHidden ? "checkmark" : "plus")
                    //                         .font(.system(size: 10, weight: .bold))
                    //                 }
                    //                 .padding(.horizontal, 12)
                    //                 .padding(.vertical, 8)
                    //                 .background(
                    //                     RoundedRectangle(cornerRadius: 8)
                    //                         .fill(retentionExcludeHidden ? Color.retraceAccent.opacity(0.3) : Color.white.opacity(0.08))
                    //                 )
                    //                 .overlay(
                    //                     RoundedRectangle(cornerRadius: 8)
                    //                         .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    //                 )
                    //             }
                    //             .buttonStyle(.plain)
                    //         }
                    //
                    //         Spacer()
                    //
                    //         if !retentionExcludedApps.isEmpty || !retentionExcludedTagIds.isEmpty || retentionExcludeHidden {
                    //             Button(action: {
                    //                 clearRetentionExclusions()
                    //                 retentionExcludeHidden = false
                    //             }) {
                    //                 Image(systemName: "xmark.circle")
                    //                     .font(.system(size: 14, weight: .medium))
                    //                     .foregroundColor(.retraceSecondary)
                    //             }
                    //             .buttonStyle(.plain)
                    //             .help("Clear all exclusions")
                    //         }
                    //     }
                    // }
                }
            }
            // .onAppear {
            //     loadRetentionExclusionData()
            // }
            .alert("Change Retention Policy?", isPresented: $showRetentionConfirmation) {
                Button("Cancel", role: .cancel) {
                    // Reset preview to original value
                    previewRetentionDays = nil
                    pendingRetentionDays = nil
                }
                Button("Confirm", role: .destructive) {
                    if let newDays = pendingRetentionDays {
                        retentionDays = newDays
                        retentionSettingChanged = true
                    }
                    previewRetentionDays = nil
                    pendingRetentionDays = nil
                }
            } message: {
                Text(retentionConfirmationMessage)
            }

            // TODO: Add Storage Limit settings later
//            ModernSettingsCard(title: "Storage Limit", icon: "externaldrive") {
//                VStack(alignment: .leading, spacing: 16) {
//                    HStack {
//                        Text("Maximum storage")
//                            .font(.retraceCalloutMedium)
//                            .foregroundColor(.retracePrimary)
//                        Spacer()
//                        Text(String(format: "%.0f GB", maxStorageGB))
//                            .font(.retraceCalloutBold)
//                            .foregroundColor(.white)
//                            .padding(.horizontal, 12)
//                            .padding(.vertical, 6)
//                            .background(Color.retraceAccent.opacity(0.3))
//                            .cornerRadius(8)
//                    }
//
//                    ModernSlider(value: $maxStorageGB, range: 10...500, step: 10)
//                }
//            }
        }
    }

    // MARK: - Export & Data Settings

    private var exportDataSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModernSettingsCard(title: "Coming Soon", icon: "clock") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("These settings will be provided in the next update!")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retracePrimary)

                    Text("Major exporting and importing flexibility")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary.opacity(0.7))
                }
            }
        }
    }

    // MARK: - Privacy Settings

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            // COMMENTED OUT - Database Encryption setting removed (no reliable encrypt/decrypt migration)
            // ModernSettingsCard(title: "Database Encryption", icon: "lock.shield") {
            //     ModernToggleRow(
            //         title: "Encrypt database",
            //         subtitle: "Secure your data with AES-256 encryption",
            //         isOn: $encryptionEnabled
            //     )
            //
            //     if encryptionEnabled {
            //         HStack(spacing: 10) {
            //             Image(systemName: "checkmark.shield.fill")
            //                 .foregroundColor(.retraceSuccess)
            //                 .font(.system(size: 14))
            //
            //             Text("Database encrypted with SQLCipher (AES-256)")
            //                 .font(.retraceCaption2Medium)
            //                 .foregroundColor(.retraceSuccess)
            //         }
            //         .padding(12)
            //         .frame(maxWidth: .infinity, alignment: .leading)
            //         .background(Color.retraceSuccess.opacity(0.1))
            //         .cornerRadius(10)
            //     }
            // }

            // TODO: Re-enable excluded apps in a future version
            // ModernSettingsCard(title: "Excluded Apps", icon: "app.badge.checkmark") {
            //     VStack(alignment: .leading, spacing: 12) {
            //         Text("Apps that will not be recorded")
            //             .font(.retraceCaption)
            //             .foregroundColor(.retraceSecondary)
            //
            //         if excludedApps.isEmpty {
            //             Text("No apps excluded")
            //                 .font(.retraceCaption2)
            //                 .foregroundColor(.retraceSecondary.opacity(0.6))
            //                 .padding(.vertical, 4)
            //         } else {
            //             // Wrap excluded apps in a flow layout
            //             FlowLayout(spacing: 8) {
            //                 ForEach(excludedApps) { app in
            //                     ExcludedAppChip(app: app) {
            //                         removeExcludedApp(app)
            //                     }
            //                 }
            //             }
            //         }
            //
            //         // Update feedback message
            //         if let message = excludedAppsUpdateMessage {
            //             HStack(spacing: 6) {
            //                 Image(systemName: "checkmark.circle.fill")
            //                     .foregroundColor(.green)
            //                     .font(.system(size: 12))
            //                 Text(message)
            //                     .font(.retraceCaption2)
            //                     .foregroundColor(.retraceSecondary)
            //             }
            //             .transition(.opacity.combined(with: .move(edge: .top)))
            //         }
            //
            //         ModernButton(title: "Add App", icon: "plus", style: .secondary) {
            //             showAppPickerMultiple { apps in
            //                 addExcludedApps(apps)
            //             }
            //         }
            //     }
            //     .animation(.easeInOut(duration: 0.2), value: excludedAppsUpdateMessage)
            // }

            // TODO: Re-enable once private window detection is more reliable
            // Currently disabled because title-based detection has false positives
            // (e.g., pages with "private" in the title) and AX-based detection
            // doesn't reliably detect Chrome/Safari incognito windows
            // ModernSettingsCard(title: "Excluded Windows", icon: "eye.slash") {
            //     ModernToggleRow(
            //         title: "Exclude Private/Incognito Windows",
            //         subtitle: "Automatically skip private browsing windows",
            //         isOn: $excludePrivateWindows
            //     )
            //
            //     if excludePrivateWindows {
            //         VStack(alignment: .leading, spacing: 8) {
            //             Text("Detects private windows from:")
            //                 .font(.retraceCaption2Medium)
            //                 .foregroundColor(.retraceSecondary)
            //
            //             Text("Safari, Chrome, Edge, Firefox, Brave")
            //                 .font(.retraceCaption2)
            //                 .foregroundColor(.retraceSecondary.opacity(0.8))
            //         }
            //         .padding(12)
            //         .frame(maxWidth: .infinity, alignment: .leading)
            //         .background(Color.white.opacity(0.03))
            //         .cornerRadius(10)
            //     }
            // }

            ModernSettingsCard(title: "Quick Delete", icon: "clock.arrow.circlepath") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Permanently delete recent recordings")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)

                    HStack(spacing: 12) {
                        QuickDeleteButton(
                            title: "Last 5 min",
                            option: .fiveMinutes,
                            isDeleting: isDeleting,
                            currentOption: deletingOption
                        ) {
                            quickDeleteConfirmation = .fiveMinutes
                        }

                        QuickDeleteButton(
                            title: "Last hour",
                            option: .oneHour,
                            isDeleting: isDeleting,
                            currentOption: deletingOption
                        ) {
                            quickDeleteConfirmation = .oneHour
                        }

                        QuickDeleteButton(
                            title: "Last 24h",
                            option: .oneDay,
                            isDeleting: isDeleting,
                            currentOption: deletingOption
                        ) {
                            quickDeleteConfirmation = .oneDay
                        }
                    }

                    // Show result message after deletion
                    if let result = deleteResult {
                        HStack(spacing: 8) {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.retraceCaption2)
                                .foregroundColor(result.success ? .retraceSuccess : .retraceWarning)
                            Text(result.message)
                                .font(.retraceCaption2Medium)
                                .foregroundColor(result.success ? .retraceSuccess : .retraceWarning)
                        }
                        .padding(.top, 4)
                        .transition(.opacity)
                    }
                }
            }
            .alert(item: $quickDeleteConfirmation) { option in
                Alert(
                    title: Text("Delete \(option.displayName)?"),
                    message: Text("This will permanently delete all recordings from the \(option.displayName.lowercased()). This action cannot be undone."),
                    primaryButton: .destructive(Text("Delete")) {
                        performQuickDelete(option: option)
                    },
                    secondaryButton: .cancel()
                )
            }

            ModernSettingsCard(title: "Permissions", icon: "hand.raised") {
                ModernPermissionRow(
                    label: "Screen Recording",
                    status: hasScreenRecordingPermission ? .granted : .notDetermined,
                    enableAction: hasScreenRecordingPermission ? nil : { requestScreenRecordingPermission() },
                    openSettingsAction: { openScreenRecordingSettings() }
                )

                ModernPermissionRow(
                    label: "Accessibility",
                    status: hasAccessibilityPermission ? .granted : .notDetermined,
                    enableAction: hasAccessibilityPermission ? nil : { requestAccessibilityPermission() },
                    openSettingsAction: { openAccessibilitySettings() }
                )
            }
            .task {
                await checkPermissions()
            }
        }
    }

    // MARK: - Power Settings

    private var powerSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Prominent energy usage banner
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("OCR is the main source of energy usage")
                        .font(.retraceCalloutBold)
                        .foregroundColor(.retracePrimary)
                    Text("Screen recording uses minimal power. Text extraction (OCR) uses most CPU. Adjust settings below to reduce energy consumption.")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )

            ModernSettingsCard(title: "OCR Processing", icon: "text.viewfinder") {
                VStack(spacing: 16) {
                    ModernToggleRow(
                        title: "Enable OCR",
                        subtitle: "Extract text from screen captures for search",
                        isOn: $ocrEnabled
                    )
                    .onChange(of: ocrEnabled) { _ in
                        notifyPowerSettingsChanged()
                    }

                    if ocrEnabled {
                        Divider()
                            .background(Color.retraceBorder)

                        ModernToggleRow(
                            title: "Process only when plugged in",
                            subtitle: "Queue OCR on battery, process when connected to power",
                            isOn: $ocrOnlyWhenPluggedIn
                        )
                        .onChange(of: ocrOnlyWhenPluggedIn) { _ in
                            notifyPowerSettingsChanged()
                        }

                        // Show power status when plugged-in mode is enabled
                        if ocrOnlyWhenPluggedIn {
                            HStack(spacing: 8) {
                                Image(systemName: currentPowerSource == .ac ? "bolt.fill" : "battery.50")
                                    .foregroundColor(currentPowerSource == .ac ? .green : .orange)
                                    .font(.system(size: 14))
                                Text(currentPowerSource == .ac ? "On AC power - processing OCR" : "On battery - OCR queued")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.retraceCard)
                            .cornerRadius(8)
                        }
                    }
                }
            }

            if ocrEnabled {
                ModernSettingsCard(title: "Power Efficiency", icon: "leaf.fill") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Max OCR rate")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retracePrimary)
                            Spacer()
                            Text(ocrRateDisplayText)
                                .font(.retraceCalloutBold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.retraceAccent.opacity(0.3))
                                .cornerRadius(8)
                        }

                        // Slider: left = slow (0.1 FPS), right = fast (unlimited/0)
                        // We display inverted: slider 0.1 = slow, slider 2 = unlimited
                        // But storage: 0 = unlimited, 0.1-2 = FPS limit
                        Slider(value: Binding(
                            get: { ocrMaxFramesPerSecond == 0 ? 2.0 : (2.1 - ocrMaxFramesPerSecond) },
                            set: { newValue in
                                if newValue >= 1.9 {
                                    ocrMaxFramesPerSecond = 0  // Unlimited
                                } else {
                                    ocrMaxFramesPerSecond = max(0.1, 2.1 - newValue)
                                }
                            }
                        ), in: 0.1...2, step: 0.1)
                            .tint(.retraceAccent)
                            .onChange(of: ocrMaxFramesPerSecond) { _ in
                                notifyPowerSettingsChanged()
                            }

                        HStack {
                            Text(ocrRateDescriptionText)
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))

                            Spacer()

                            if ocrMaxFramesPerSecond != SettingsDefaults.ocrMaxFramesPerSecond {
                                Button(action: {
                                    ocrMaxFramesPerSecond = SettingsDefaults.ocrMaxFramesPerSecond
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 10))
                                        Text("Reset")
                                            .font(.retraceCaption2)
                                    }
                                    .foregroundColor(.white.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                ModernSettingsCard(title: "App Filter", icon: "app.badge") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Skip OCR for specific apps to save power")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)

                        // Show selected apps as chips
                        if !ocrFilteredApps.isEmpty {
                            FlowLayout(spacing: 8) {
                                ForEach(ocrFilteredApps, id: \.bundleID) { app in
                                    HStack(spacing: 6) {
                                        // App icon
                                        if let icon = AppIconProvider.shared.icon(for: app.bundleID) {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .frame(width: 16, height: 16)
                                        } else {
                                            Image(systemName: "app.fill")
                                                .font(.system(size: 12))
                                                .foregroundColor(.retraceSecondary)
                                        }
                                        Text(app.name)
                                            .font(.retraceCaption2Medium)
                                            .foregroundColor(.retracePrimary)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                        // Include/Exclude indicator
                                        Text(ocrAppFilterMode == .onlyTheseApps ? "only" : "skip")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(ocrAppFilterMode == .onlyTheseApps ? .green : .orange)
                                        Button(action: {
                                            removeOCRFilteredApp(app)
                                        }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundColor(.retraceSecondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.retraceCard)
                                    .cornerRadius(6)
                                    .fixedSize()
                                }
                            }
                        }

                        // Add app button with popover
                        Button(action: {
                            ocrFilteredAppsPopoverShown = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 14))
                                Text(ocrFilteredApps.isEmpty ? "Add apps to filter" : "Add more apps")
                                    .font(.retraceCaption2Medium)
                            }
                            .foregroundColor(.retraceAccent)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $ocrFilteredAppsPopoverShown) {
                            AppsFilterPopover(
                                apps: installedAppsForOCR,
                                otherApps: [],
                                selectedApps: Set(ocrFilteredApps.map(\.bundleID)),
                                filterMode: ocrAppFilterMode == .onlyTheseApps ? .include : .exclude,
                                allowMultiSelect: true,
                                showAllOption: false,
                                onSelectApp: { bundleID in
                                    guard let bundleID = bundleID else { return }
                                    toggleOCRFilteredApp(bundleID)
                                },
                                onFilterModeChange: { mode in
                                    ocrAppFilterMode = mode == .include ? .onlyTheseApps : .allExceptTheseApps
                                    notifyPowerSettingsChanged()
                                },
                                onDismiss: {
                                    ocrFilteredAppsPopoverShown = false
                                }
                            )
                        }

                        // Explanation of current mode
                        if !ocrFilteredApps.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: ocrAppFilterMode == .onlyTheseApps ? "checkmark.circle" : "minus.circle")
                                    .font(.system(size: 11))
                                    .foregroundColor(ocrAppFilterMode == .onlyTheseApps ? .green : .orange)
                                Text(ocrAppFilterMode == .onlyTheseApps
                                     ? "OCR runs only for these apps"
                                     : "OCR skipped for these apps")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary.opacity(0.8))
                            }
                        }
                    }
                }
            }

            // Tips card
            HStack(spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Tips for reducing energy usage")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retracePrimary)
                    Text("• Lower the OCR rate to reduce fan noise\n• Use \"Process only when plugged in\" for laptops\n• Exclude apps where text search isn't needed")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.08))
            .cornerRadius(10)
        }
        .onAppear {
            updatePowerSourceStatus()
            loadOCRFilteredApps()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PowerSourceDidChange"))) { _ in
            updatePowerSourceStatus()
        }
    }

    private var ocrRateDisplayText: String {
        if ocrMaxFramesPerSecond == 0 {
            return "Unlimited"
        } else if ocrMaxFramesPerSecond < 1 {
            return String(format: "%.1f FPS", ocrMaxFramesPerSecond)
        } else {
            return String(format: "%.0f FPS", ocrMaxFramesPerSecond)
        }
    }

    private var ocrRateDescriptionText: String {
        if ocrMaxFramesPerSecond == 0 {
            return "Process frames as fast as possible (may cause fan noise)"
        } else if ocrMaxFramesPerSecond <= 0.5 {
            return "Quietest mode - minimal CPU and fan activity"
        } else if ocrMaxFramesPerSecond <= 1.0 {
            return "Balanced - good performance with low fan noise"
        } else {
            return "Higher performance - may increase fan activity"
        }
    }

    private var ocrFilteredApps: [ExcludedAppInfo] {
        guard !ocrFilteredAppsString.isEmpty,
              let data = ocrFilteredAppsString.data(using: .utf8),
              let apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) else {
            return []
        }
        return apps
    }

    private func loadOCRFilteredApps() {
        // Load apps from capture history (database) - these have the actual bundle IDs
        // that match what's recorded during screen capture
        Task {
            do {
                let bundleIDs = try await coordinatorWrapper.coordinator.getDistinctAppBundleIDs()
                let apps: [(bundleID: String, name: String)] = bundleIDs.map { bundleID in
                    let name = AppNameResolver.shared.displayName(for: bundleID)
                    return (bundleID: bundleID, name: name)
                }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                await MainActor.run {
                    installedAppsForOCR = apps
                }
            } catch {
                Log.error("[SettingsView] Failed to load apps for OCR filter: \(error)", category: .ui)
                // Fallback to installed apps if database query fails
                let installed = AppNameResolver.shared.getInstalledApps()
                installedAppsForOCR = installed.map { (bundleID: $0.bundleID, name: $0.name) }
            }
        }
    }

    private func addOCRFilteredApp(_ app: ExcludedAppInfo) {
        var apps = ocrFilteredApps
        if !apps.contains(where: { $0.bundleID == app.bundleID }) {
            apps.append(app)
            saveOCRFilteredApps(apps)
            notifyPowerSettingsChanged()
        }
    }

    private func removeOCRFilteredApp(_ app: ExcludedAppInfo) {
        var apps = ocrFilteredApps
        apps.removeAll { $0.bundleID == app.bundleID }
        saveOCRFilteredApps(apps)
        // If no apps left, reset to "all apps" mode
        if apps.isEmpty {
            ocrAppFilterMode = .allApps
        }
        notifyPowerSettingsChanged()
    }

    private func toggleOCRFilteredApp(_ bundleID: String) {
        var apps = ocrFilteredApps
        if let index = apps.firstIndex(where: { $0.bundleID == bundleID }) {
            // Remove if already selected
            apps.remove(at: index)
            // If no apps left, reset to "all apps" mode
            if apps.isEmpty {
                ocrAppFilterMode = .allApps
            }
        } else {
            // Add the app
            let name = installedAppsForOCR.first(where: { $0.bundleID == bundleID })?.name ?? bundleID
            apps.append(ExcludedAppInfo(bundleID: bundleID, name: name, iconPath: nil))
            // If mode is "allApps", switch to exclude mode when first app is added
            if ocrAppFilterMode == .allApps {
                ocrAppFilterMode = .allExceptTheseApps
            }
        }
        saveOCRFilteredApps(apps)
        notifyPowerSettingsChanged()
    }

    private func saveOCRFilteredApps(_ apps: [ExcludedAppInfo]) {
        if let data = try? JSONEncoder().encode(apps),
           let string = String(data: data, encoding: .utf8) {
            ocrFilteredAppsString = string
        } else {
            ocrFilteredAppsString = ""
        }
    }


    private func updatePowerSourceStatus() {
        currentPowerSource = PowerStateMonitor.shared.getCurrentPowerSource()
    }

    private func notifyPowerSettingsChanged() {
        // Post notification to trigger applyPowerSettings in coordinator
        NotificationCenter.default.post(name: NSNotification.Name("PowerSettingsDidChange"), object: nil)
    }

    func resetPowerSettings() {
        ocrEnabled = SettingsDefaults.ocrEnabled
        ocrOnlyWhenPluggedIn = SettingsDefaults.ocrOnlyWhenPluggedIn
        ocrMaxFramesPerSecond = SettingsDefaults.ocrMaxFramesPerSecond
        ocrAppFilterMode = SettingsDefaults.ocrAppFilterMode
        ocrFilteredAppsString = SettingsDefaults.ocrFilteredApps
        notifyPowerSettingsChanged()
    }

    // MARK: - Tag Management Settings
    private var tagManagementSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModernSettingsCard(title: "Manage Tags", icon: "tag") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Create and manage tags for organizing your recordings.")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)

                    // Create tag section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("Tag name", text: $newTagName)
                                .textFieldStyle(.plain)
                                .font(.retraceCallout)
                                .foregroundColor(.retracePrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.retraceSecondary.opacity(0.05))
                                .cornerRadius(8)
                                .disabled(isCreatingTag)
                                .onSubmit {
                                    Task {
                                        await createTag()
                                    }
                                }

                            ModernButton(
                                title: isCreatingTag ? "Creating..." : "Create Tag",
                                icon: "plus",
                                style: .secondary
                            ) {
                                Task {
                                    await createTag()
                                }
                            }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty || isCreatingTag)
                        }

                        if let error = tagCreationError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.retraceWarning)
                                    .font(.system(size: 12))
                                Text(error)
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceWarning)
                            }
                            .transition(.opacity)
                        }
                    }

                    if !tagsForSettings.isEmpty {
                        Divider()
                            .background(Color.retraceBorder)
                            .padding(.vertical, 4)

                        VStack(spacing: 0) {
                            ForEach(tagsForSettings, id: \.id) { tag in
                                tagRow(for: tag)

                                if tag.id != tagsForSettings.last?.id {
                                    Divider()
                                        .background(Color.retraceBorder)
                                }
                            }
                        }
                    } else {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "tag.slash")
                                    .font(.system(size: 24))
                                    .foregroundColor(.retraceSecondary.opacity(0.5))
                                Text("No tags created yet")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary.opacity(0.6))
                            }
                            .padding(.vertical, 20)
                            Spacer()
                        }
                    }
                }
            }
        }
        .task {
            await loadTagsForSettings()
        }
        .alert("Delete Tag", isPresented: $showTagDeleteConfirmation, presenting: tagToDelete) { tag in
            Button("Cancel", role: .cancel) {
                tagToDelete = nil
            }
            Button("Delete", role: .destructive) {
                Task {
                    await deleteTag(tag)
                }
            }
        } message: { tag in
            let count = tagSegmentCounts[tag.id] ?? 0
            if count == 0 {
                Text("This tag is not applied to any segments.")
            } else {
                Text("This tag is applied to \(count) segment\(count == 1 ? "" : "s"). The segments will remain, but the tag will be removed from them.")
            }
        }
    }

    private func tagRow(for tag: Tag) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.name)
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                let count = tagSegmentCounts[tag.id] ?? 0
                Text("\(count) segment\(count == 1 ? "" : "s")")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            Button {
                tagToDelete = tag
                showTagDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(.retraceSecondary)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.vertical, 8)
    }

    private func loadTagsForSettings() async {
        let coordinator = coordinatorWrapper.coordinator

        do {
            let allTags = try await coordinator.getAllTags()
            // Filter out the hidden system tag
            let userTags = allTags.filter { !$0.isHidden }

            // Get segment counts for each tag
            var counts: [TagID: Int] = [:]
            for tag in userTags {
                counts[tag.id] = try await coordinator.getSegmentCountForTag(tagId: tag.id)
            }

            await MainActor.run {
                self.tagsForSettings = userTags
                self.tagSegmentCounts = counts
            }
        } catch {
            Log.error("[Settings] Failed to load tags: \(error)", category: .ui)
        }
    }

    private func deleteTag(_ tag: Tag) async {
        let coordinator = coordinatorWrapper.coordinator

        do {
            try await coordinator.deleteTag(tagId: tag.id)
            await loadTagsForSettings()
        } catch {
            Log.error("[Settings] Failed to delete tag: \(error)", category: .ui)
        }
    }

    private func createTag() async {
        let trimmedName = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        await MainActor.run {
            isCreatingTag = true
            tagCreationError = nil
        }

        let coordinator = coordinatorWrapper.coordinator

        do {
            // Check if tag already exists
            if try await coordinator.getTag(name: trimmedName) != nil {
                await MainActor.run {
                    tagCreationError = "Tag '\(trimmedName)' already exists"
                    isCreatingTag = false
                }
                return
            }

            // Create the tag
            _ = try await coordinator.createTag(name: trimmedName)

            await MainActor.run {
                newTagName = ""
                isCreatingTag = false
            }

            // Reload the tags list
            await loadTagsForSettings()

            // Clear error after success (with delay)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                tagCreationError = nil
            }
        } catch {
            await MainActor.run {
                tagCreationError = "Failed to create tag: \(error.localizedDescription)"
                isCreatingTag = false
            }
            Log.error("[Settings] Failed to create tag: \(error)", category: .ui)
        }
    }

    // MARK: - Search Settings
    // TODO: Add Search settings later
//    private var searchSettings: some View {
//        VStack(alignment: .leading, spacing: 20) {
//            ModernSettingsCard(title: "Search Behavior", icon: "magnifyingglass") {
//                ModernToggleRow(
//                    title: "Show suggestions as you type",
//                    subtitle: "Display search suggestions in real-time",
//                    isOn: .constant(true)
//                )
//
//                ModernToggleRow(
//                    title: "Include audio transcriptions",
//                    subtitle: "Search through transcribed audio content",
//                    isOn: .constant(false),
//                    disabled: true,
//                    badge: "Coming Soon"
//                )
//            }
//
//            ModernSettingsCard(title: "Results", icon: "list.bullet.rectangle") {
//                VStack(alignment: .leading, spacing: 16) {
//                    HStack {
//                        Text("Default result limit")
//                            .font(.retraceCalloutMedium)
//                            .foregroundColor(.retracePrimary)
//                        Spacer()
//                        Text("50")
//                            .font(.retraceCalloutBold)
//                            .foregroundColor(.white)
//                            .padding(.horizontal, 12)
//                            .padding(.vertical, 6)
//                            .background(Color.retraceAccent.opacity(0.3))
//                            .cornerRadius(8)
//                    }
//
//                    ModernSlider(value: .constant(50), range: 10...200, step: 10)
//                }
//            }
//
//            ModernSettingsCard(title: "Ranking", icon: "chart.bar") {
//                VStack(alignment: .leading, spacing: 12) {
//                    HStack {
//                        Text("Relevance")
//                            .font(.retraceCaptionMedium)
//                            .foregroundColor(.retraceSecondary)
//                        Spacer()
//                        Text("Recency")
//                            .font(.retraceCaptionMedium)
//                            .foregroundColor(.retraceSecondary)
//                    }
//
//                    ModernSlider(value: .constant(0.7), range: 0...1, step: 0.1)
//                }
//            }
//        }
//    }

    // MARK: - Advanced Settings

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            // TODO: Add Database settings later
//            ModernSettingsCard(title: "Database", icon: "cylinder") {
//                HStack(spacing: 12) {
//                    ModernButton(title: "Vacuum Database", icon: "arrow.triangle.2.circlepath", style: .secondary) {}
//                    ModernButton(title: "Rebuild FTS Index", icon: "magnifyingglass", style: .secondary) {}
//                }
//            }

            // TODO: Add Encoding settings later
//            ModernSettingsCard(title: "Encoding", icon: "cpu") {
//                ModernToggleRow(
//                    title: "Hardware Acceleration",
//                    subtitle: "Use VideoToolbox for faster encoding",
//                    isOn: .constant(true)
//                )
//
//                VStack(alignment: .leading, spacing: 12) {
//                    Text("Encoder Preset")
//                        .font(.retraceCalloutMedium)
//                        .foregroundColor(.retracePrimary)
//
//                    ModernSegmentedPicker(
//                        selection: .constant("balanced"),
//                        options: ["fast", "balanced", "quality"]
//                    ) { option in
//                        Text(option.capitalized)
//                    }
//                }
//            }

            ModernSettingsCard(title: "Cache", icon: "externaldrive") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Clear App Name Cache")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retracePrimary)

                            Text("Refresh cached app names if they appear incorrect or outdated")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                        }

                        Spacer()

                        ModernButton(title: "Clear Cache", icon: "arrow.clockwise", style: .secondary) {
                            clearAppNameCache()
                        }
                    }

                    if let message = cacheClearMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                            Text(message)
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: cacheClearMessage)
            }

            ModernSettingsCard(title: "Timeline", icon: "play.rectangle") {
                ModernToggleRow(
                    title: "Show video controls",
                    subtitle: "Display play/pause button in the timeline to auto-advance frames",
                    isOn: $showVideoControls
                )
            }

            ModernSettingsCard(title: "Developer", icon: "hammer") {
                ModernToggleRow(
                    title: "Show frame IDs in UI",
                    subtitle: "Display frame IDs in the timeline for debugging",
                    isOn: $showFrameIDs
                )

                ModernToggleRow(
                    title: "Enable frame ID search",
                    subtitle: "Allow jumping to frames by ID in the Go to panel",
                    isOn: $enableFrameIDSearch
                )

                ModernToggleRow(
                    title: "Show OCR debug overlay",
                    subtitle: "Display OCR bounding boxes and tile grid in timeline",
                    isOn: $showOCRDebugOverlay
                )

                Divider()
                    .padding(.vertical, 8)

                ModernButton(title: "Show Database Schema", icon: "doc.text", style: .secondary) {
                    loadDatabaseSchema()
                    showingDatabaseSchema = true
                }
                .sheet(isPresented: $showingDatabaseSchema) {
                    DatabaseSchemaView(schemaText: databaseSchemaText, isPresented: $showingDatabaseSchema)
                }
            }

            ModernSettingsCard(title: "Danger Zone", icon: "exclamationmark.triangle", dangerous: true) {
                HStack(spacing: 12) {
                    ModernButton(title: "Reset All Settings", icon: "arrow.counterclockwise", style: .danger) {
                        showingResetConfirmation = true
                    }
                    ModernButton(title: "Delete All Data", icon: "trash", style: .danger) {
                        showingDeleteConfirmation = true
                    }
                }
            }
            .alert("Reset All Settings?", isPresented: $showingResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    resetAllSettings()
                }
            } message: {
                Text("This will reset all settings to their defaults. Your recordings will not be deleted.")
            }
            .alert("Delete All Data?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    deleteAllData()
                }
            } message: {
                Text("This will permanently delete all your recordings and data. This action cannot be undone.")
            }
        }
    }
}

// MARK: - Modern Components

private struct ModernSettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var dangerous: Bool = false
    var trailingAction: (() -> Void)? = nil
    var trailingActionIcon: String? = nil
    var trailingActionTooltip: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.retraceCalloutMedium)
                    .foregroundColor(dangerous ? .retraceDanger : .retraceSecondary)

                Text(title)
                    .font(.retraceBodyBold)
                    .foregroundColor(dangerous ? .retraceDanger : .retracePrimary)

                Spacer()

                if let action = trailingAction, let actionIcon = trailingActionIcon {
                    Button(action: action) {
                        Image(systemName: actionIcon)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(trailingActionTooltip ?? "")
                }
            }

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(dangerous ? Color.retraceDanger.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ModernToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.retraceCalloutMedium)
                        .foregroundColor(disabled ? .retraceSecondary : .retracePrimary)

                    if let badge = badge {
                        Text(badge)
                            .font(.retraceTinyBold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.retraceAccent.opacity(0.3))
                            .cornerRadius(4)
                    }
                }

                Text(subtitle)
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .retraceAccent))
                .scaleEffect(0.85)
                .disabled(disabled)
        }
        .padding(.vertical, 4)
    }
}

private struct ModernShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            Spacer()

            Text(shortcut)
                .font(.retraceMono)
                .foregroundColor(.retraceSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.05))
                .cornerRadius(6)
        }
    }
}

private struct ModernPermissionRow: View {
    let label: String
    let status: PermissionStatus
    var enableAction: (() -> Void)? = nil
    var openSettingsAction: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            Spacer()

            if status == .granted {
                // Show granted status
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.retraceSuccess)
                        .frame(width: 8, height: 8)

                    Text(status.rawValue)
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSuccess)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.retraceSuccess.opacity(0.1))
                .cornerRadius(8)
            } else {
                // Show enable button when not granted
                HStack(spacing: 12) {
                    // Status indicator
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.retraceWarning)
                            .frame(width: 8, height: 8)

                        Text("Not Enabled")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retraceWarning)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.retraceWarning.opacity(0.1))
                    .cornerRadius(8)

                    // Enable button
                    if let action = enableAction {
                        Button(action: action) {
                            Text("Enable")
                                .font(.retraceCaption2Bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.retraceAccent)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }

                    // Open Settings button (alternative action)
                    if let settingsAction = openSettingsAction {
                        Button(action: settingsAction) {
                            Image(systemName: "gear")
                                .font(.retraceCaption2Medium)
                                .foregroundColor(.retraceSecondary)
                                .padding(6)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help("Open System Settings")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ModernSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    @GestureState private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let thumbPosition = trackWidth * progress

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 6)

                // Track fill
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient.retraceAccentGradient)
                    .frame(width: max(0, thumbPosition), height: 6)

                // Thumb/handle
                Circle()
                    .fill(Color.retraceAccent)
                    .frame(width: isDragging ? 16 : 14, height: isDragging ? 16 : 14)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 2)
                    )
                    .shadow(color: Color.retraceAccent.opacity(0.5), radius: isDragging ? 6 : 4)
                    .offset(x: max(0, min(thumbPosition - 7, trackWidth - 14)))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { gestureValue in
                        let x = gestureValue.location.x
                        let percentage = max(0, min(1, x / trackWidth))
                        let rawValue = range.lowerBound + (range.upperBound - range.lowerBound) * Double(percentage)
                        // Snap to step
                        let steppedValue = round(rawValue / step) * step
                        let clampedValue = max(range.lowerBound, min(range.upperBound, steppedValue))
                        if clampedValue != value {
                            value = clampedValue
                        }
                    }
            )
        }
        .frame(height: 20)
    }

    private var progress: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

private struct ModernSegmentedPicker<T: Hashable, Content: View>: View {
    @Binding var selection: T
    let options: [T]
    @ViewBuilder let label: (T) -> Content

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button(action: { selection = option }) {
                    label(option)
                        .font(selection == option ? .retraceCaptionBold : .retraceCaptionMedium)
                        .foregroundColor(selection == option ? .retracePrimary : .retraceSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selection == option ? Color.white.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

private struct ModernDropdown: View {
    @Binding var selection: Int
    let options: [(Int, String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(action: { selection = option.0 }) {
                    if selection == option.0 {
                        Label(option.1, systemImage: "checkmark")
                    } else {
                        Text(option.1)
                    }
                }
            }
        } label: {
            HStack {
                Text(options.first(where: { $0.0 == selection })?.1 ?? "")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
    }
}

private struct ModernButton: View {
    let title: String
    let icon: String?
    let style: ButtonStyleType
    let action: () -> Void

    enum ButtonStyleType {
        case primary, secondary, danger
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.retraceCaptionMedium)
                }
                Text(title)
                    .font(.retraceCaptionMedium)
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .retracePrimary
        case .danger: return .retraceDanger
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary: return .retraceAccent
        case .secondary: return Color.white.opacity(0.05)
        case .danger: return Color.retraceDanger.opacity(0.1)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary: return Color.clear
        case .secondary: return Color.white.opacity(0.08)
        case .danger: return Color.retraceDanger.opacity(0.3)
        }
    }
}

// MARK: - Excluded App Chip

private struct ExcludedAppChip: View {
    let app: ExcludedAppInfo
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // App icon
            if let iconPath = app.iconPath {
                let icon = NSWorkspace.shared.icon(forFile: iconPath)
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.fill")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }

            Text(app.name)
                .font(.retraceCaption2Medium)
                .foregroundColor(.retracePrimary)

            // Remove button (visible on hover)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.retraceTinyBold)
                    .foregroundColor(isHovered ? .retracePrimary : .retraceSecondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(isHovered ? 0.08 : 0.05))
        .cornerRadius(6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Flow Layout for App Chips

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Use LazyVGrid with adaptive columns for wrapping
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: spacing)],
            alignment: .leading,
            spacing: spacing
        ) {
            content()
        }
    }
}

// MARK: - Font Style Picker

private struct FontStylePicker: View {
    @Binding var selection: RetraceFontStyle

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RetraceFontStyle.allCases) { style in
                Button(action: {
                    selection = style
                }) {
                    VStack(spacing: 8) {
                        // Preview text in the actual font style
                        Text("Aa")
                            .font(.system(size: 24, weight: .semibold, design: style.design))
                            .foregroundColor(selection == style ? .retracePrimary : .retraceSecondary)

                        VStack(spacing: 2) {
                            Text(style.displayName)
                                .font(.retraceCaptionBold)
                                .foregroundColor(selection == style ? .retracePrimary : .retraceSecondary)

                            Text(style.description)
                                .font(.retraceTiny)
                                .foregroundColor(.retraceSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selection == style ? Color.white.opacity(0.08) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selection == style ? Color.retraceAccent.opacity(0.5) : Color.clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
    }
}

// MARK: - Color Theme Picker

private struct ColorThemePicker: View {
    @Binding var selection: MilestoneCelebrationManager.ColorTheme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MilestoneCelebrationManager.ColorTheme.allCases) { theme in
                themeOptionButton(for: theme)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func themeOptionButton(for theme: MilestoneCelebrationManager.ColorTheme) -> some View {
        let isSelected = selection == theme

        Button(action: {
            selection = theme
        }) {
            VStack(spacing: 8) {
                // Color swatch preview
                Circle()
                    .fill(theme.glowColor)
                    .frame(width: 32, height: 32)

                Text(theme.displayName)
                    .font(.retraceCaptionBold)
                    .foregroundColor(isSelected ? .retracePrimary : .retraceSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? theme.glowColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Capture Interval Picker

private struct CaptureIntervalPicker: View {
    @Binding var selectedInterval: Double

    // Discrete interval options: 2s, 5s, 10s, 15s, 30s, 60s
    private let intervals: [Double] = [2, 5, 10, 15, 30, 60]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(intervals, id: \.self) { interval in
                Text(intervalLabel(interval))
                    .font(selectedInterval == interval ? .retraceCalloutBold : .retraceCalloutMedium)
                    .foregroundColor(selectedInterval == interval ? .retracePrimary : .retraceSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedInterval == interval ? Color.white.opacity(0.1) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedInterval = interval
                    }
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }

    private func intervalLabel(_ interval: Double) -> String {
        if interval >= 60 {
            return "\(Int(interval / 60))m"
        } else {
            return "\(Int(interval))s"
        }
    }
}

// MARK: - Pause Reminder Delay Picker

private struct PauseReminderDelayPicker: View {
    @Binding var selectedMinutes: Double

    // Options: 5m, 15m, 30m, 1h, 2h, 4h, 8h, Never (0)
    private let options: [(minutes: Double, label: String)] = [
        (5, "5m"),
        (15, "15m"),
        (30, "30m"),
        (60, "1h"),
        (120, "2h"),
        (240, "4h"),
        (480, "8h"),
        (0, "Never"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.minutes) { option in
                Text(option.label)
                    .font(selectedMinutes == option.minutes ? .retraceCalloutBold : .retraceCalloutMedium)
                    .foregroundColor(selectedMinutes == option.minutes ? .retracePrimary : .retraceSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedMinutes == option.minutes ? Color.white.opacity(0.1) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedMinutes = option.minutes
                    }
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

// MARK: - Retention Policy Picker (Sliding Scale)

private struct RetentionPolicyPicker: View {
    var displayDays: Int  // What to visually show (may differ from persisted value during preview)
    var onPreviewChange: (Int) -> Void  // Called during drag to update visual preview
    var onSelectionEnd: (Int) -> Void   // Called when drag ends to trigger confirmation

    // Retention options: 3 days through 1 year, then Forever (0) at the end
    private let options: [(days: Int, label: String)] = [
        (3, "3D"),
        (7, "1W"),
        (14, "2W"),
        (30, "1M"),
        (60, "2M"),
        (90, "3M"),
        (180, "6M"),
        (365, "1Y"),
        (0, "Forever")
    ]

    // Map days to slider index (default to last index = Forever)
    private var sliderIndex: Double {
        Double(options.firstIndex(where: { $0.days == displayDays }) ?? (options.count - 1))
    }

    @State private var lastSelectedDays: Int?

    var body: some View {
        VStack(spacing: 12) {
            // Custom slider track with markers
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                // Inset from edges so dots are centered under labels
                let horizontalInset: CGFloat = totalWidth / CGFloat(options.count) / 2
                let trackWidth = totalWidth - (horizontalInset * 2)
                let segmentWidth = trackWidth / CGFloat(options.count - 1)

                ZStack(alignment: .leading) {
                    // Track background - only between first and last dot
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: trackWidth, height: 4)
                        .offset(x: horizontalInset)

                    // Track fill (from first dot to current position)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient.retraceAccentGradient)
                        .frame(width: max(0, CGFloat(sliderIndex) * segmentWidth), height: 4)
                        .offset(x: horizontalInset)

                    // Marker dots (non-interactive, just visual)
                    HStack(spacing: 0) {
                        ForEach(0..<options.count, id: \.self) { index in
                            Circle()
                                .fill(index <= Int(sliderIndex) ? Color.retraceAccent : Color.white.opacity(0.3))
                                .frame(width: index == Int(sliderIndex) ? 14 : 8, height: index == Int(sliderIndex) ? 14 : 8)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.2), lineWidth: index == Int(sliderIndex) ? 2 : 0)
                                )
                                .shadow(color: index == Int(sliderIndex) ? Color.retraceAccent.opacity(0.5) : .clear, radius: 4)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = value.location.x
                            // Adjust for inset
                            let adjustedX = x - horizontalInset
                            let index = Int(round(adjustedX / segmentWidth))
                            let clampedIndex = max(0, min(options.count - 1, index))
                            let newDays = options[clampedIndex].days
                            if newDays != displayDays {
                                lastSelectedDays = newDays
                                onPreviewChange(newDays)
                            }
                        }
                        .onEnded { _ in
                            if let selectedDays = lastSelectedDays {
                                onSelectionEnd(selectedDays)
                                lastSelectedDays = nil
                            }
                        }
                )
            }
            .frame(height: 30)

            // Labels below the slider
            HStack(spacing: 0) {
                ForEach(0..<options.count, id: \.self) { index in
                    Text(options[index].label)
                        .font(index == Int(sliderIndex) ? .retraceTinyBold : .retraceTiny)
                        .foregroundColor(index == Int(sliderIndex) ? .retracePrimary : .retraceSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Retention Exclusion Chips

/// Chip for selecting apps to exclude from retention policy (mirrors AppsFilterChip design)
private struct RetentionAppsChip<PopoverContent: View>: View {
    let selectedApps: Set<String>
    @Binding var isPopoverShown: Bool
    @ViewBuilder var popoverContent: () -> PopoverContent

    @State private var isHovered = false

    private let maxVisibleIcons = 5
    private let iconSize: CGFloat = 18

    private var sortedApps: [String] {
        selectedApps.sorted()
    }

    private var isActive: Bool {
        !selectedApps.isEmpty
    }

    var body: some View {
        Button(action: {
            isPopoverShown.toggle()
        }) {
            HStack(spacing: 6) {
                if sortedApps.count == 1 {
                    // Single app: show icon + name
                    let bundleID = sortedApps[0]
                    appIcon(for: bundleID)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text(appName(for: bundleID))
                        .font(.retraceCaptionMedium)
                        .lineLimit(1)
                } else if sortedApps.count > 1 {
                    // Multiple apps: show overlapping icons
                    HStack(spacing: -4) {
                        ForEach(Array(sortedApps.prefix(maxVisibleIcons)), id: \.self) { bundleID in
                            appIcon(for: bundleID)
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }

                    // Show "+X" if more than maxVisibleIcons
                    if sortedApps.count > maxVisibleIcons {
                        Text("+\(sortedApps.count - maxVisibleIcons)")
                            .font(.retraceTinyBold)
                            .foregroundColor(.white.opacity(0.8))
                    }
                } else {
                    // Default state - no apps selected
                    Image(systemName: "app.fill")
                        .font(.system(size: 12))
                    Text("None")
                        .font(.retraceCaptionMedium)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isPopoverShown ? 180 : 0))
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: sortedApps)
            .foregroundColor(isActive ? .white : .retraceSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.retraceAccent.opacity(0.2) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isActive ? Color.retraceAccent.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            popoverContent()
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private func appName(for bundleID: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: appURL.path)
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

/// Chip for selecting tags to exclude from retention policy
private struct RetentionTagsChip<PopoverContent: View>: View {
    let selectedTagIds: Set<Int64>
    let availableTags: [Tag]
    @Binding var isPopoverShown: Bool
    @ViewBuilder var popoverContent: () -> PopoverContent

    @State private var isHovered = false

    private var selectedTags: [Tag] {
        availableTags.filter { selectedTagIds.contains($0.id.value) }
    }

    private var isActive: Bool {
        !selectedTagIds.isEmpty
    }

    var body: some View {
        Button(action: {
            isPopoverShown.toggle()
        }) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 12))

                if selectedTags.count == 1 {
                    // Single tag: show tag name
                    Text(selectedTags[0].name)
                        .font(.retraceCaptionMedium)
                        .lineLimit(1)
                } else if selectedTags.count > 1 {
                    // Multiple tags: show count
                    Text("\(selectedTags.count) tags")
                        .font(.retraceCaptionMedium)
                } else {
                    // Default state - no tags selected
                    Text("None")
                        .font(.retraceCaptionMedium)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isPopoverShown ? 180 : 0))
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedTagIds)
            .foregroundColor(isActive ? .white : .retraceSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.retraceAccent.opacity(0.2) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isActive ? Color.retraceAccent.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            popoverContent()
        }
    }
}

extension SettingsView {
    private static func logSettingsLayout(windowWidth: CGFloat) {
        let sidebarWidth: CGFloat = 220
        let dividerWidth: CGFloat = 1
        let contentWidth = windowWidth - sidebarWidth - dividerWidth
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [SETTINGS-LAYOUT] windowWidth: \(windowWidth), sidebarWidth: \(sidebarWidth), contentWidth: \(contentWidth)\n"
        let path = URL(fileURLWithPath: "/tmp/retrace_debug.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path.path) {
                if let handle = try? FileHandle(forWritingTo: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: path)
            }
        }
    }
}

extension SettingsView {
    var pauseReminderDisplayText: String {
        if pauseReminderDelayMinutes == 0 {
            return "Never"
        } else if pauseReminderDelayMinutes < 60 {
            return "\(Int(pauseReminderDelayMinutes)) min"
        } else {
            let hours = Int(pauseReminderDelayMinutes / 60)
            return "\(hours) hr"
        }
    }

    var captureIntervalDisplayText: String {
        if captureIntervalSeconds >= 60 {
            let minutes = Int(captureIntervalSeconds / 60)
            return "Every \(minutes) min"
        } else {
            return "Every \(Int(captureIntervalSeconds))s"
        }
    }

    var videoQualityDisplayText: String {
        let percentage = Int(videoQuality * 100)
        return "\(percentage)%"
    }

    var scrubbingAnimationDisplayText: String {
        if scrubbingAnimationDuration == 0 {
            return "None"
        } else {
            let ms = Int(scrubbingAnimationDuration * 1000)
            return "\(ms)ms"
        }
    }

    var scrubbingAnimationDescriptionText: String {
        if scrubbingAnimationDuration == 0 {
            return "Instant scrubbing with no animation"
        } else if scrubbingAnimationDuration <= 0.05 {
            return "Minimal animation for quick scrubbing"
        } else if scrubbingAnimationDuration <= 0.10 {
            return "Smooth animation for comfortable navigation"
        } else if scrubbingAnimationDuration <= 0.15 {
            return "Moderate animation for visual feedback"
        } else {
            return "Maximum animation for cinematic feel"
        }
    }

    var scrollSensitivityDisplayText: String {
        return "\(Int(scrollSensitivity * 100))%"
    }

    var scrollSensitivityDescriptionText: String {
        if scrollSensitivity <= 0.25 {
            return "Slow, precise frame-by-frame navigation"
        } else if scrollSensitivity <= 0.50 {
            return "Moderate scroll speed for careful browsing"
        } else if scrollSensitivity <= 0.75 {
            return "Balanced scroll speed for general use"
        } else {
            return "Fast scrolling for quick navigation"
        }
    }

    /// Calculate storage multiplier based on video quality setting
    /// Reference: 50% quality = 1.0x multiplier
    private func videoQualityMultiplier() -> Double {
        // Interpolation based on quality percentage
        // At 50% (0.5): baseline multiplier = 1.0
        // Multipliers relative to 50%:
        // 5% → 0.22x, 15% → 0.48x, 30% → 0.76x, 50% → 1.0x, 85% → 3.65x
        if videoQuality <= 0.05 {
            return 0.22
        } else if videoQuality <= 0.15 {
            // Interpolate between 0.05 (0.22) and 0.15 (0.48)
            let t = (videoQuality - 0.05) / 0.10
            return 0.22 + t * (0.48 - 0.22)
        } else if videoQuality <= 0.30 {
            // Interpolate between 0.15 (0.48) and 0.30 (0.76)
            let t = (videoQuality - 0.15) / 0.15
            return 0.48 + t * (0.76 - 0.48)
        } else if videoQuality <= 0.50 {
            // Interpolate between 0.30 (0.76) and 0.50 (1.0)
            let t = (videoQuality - 0.30) / 0.20
            return 0.76 + t * (1.0 - 0.76)
        } else if videoQuality <= 0.85 {
            // Interpolate between 0.50 (1.0) and 0.85 (3.65)
            let t = (videoQuality - 0.50) / 0.35
            return 1.0 + t * (3.65 - 1.0)
        } else {
            // Interpolate between 0.85 (3.65) and 1.0 (estimated ~5.0)
            let t = (videoQuality - 0.85) / 0.15
            return 3.65 + t * (5.0 - 3.65)
        }
    }

    /// Calculate storage multiplier based on capture interval
    /// Reference: 2 seconds = 1.0x multiplier (baseline)
    /// Longer intervals = less storage (linear relationship)
    private func captureIntervalMultiplier() -> Double {
        // At 2s interval: 1.0x (baseline)
        // At 5s interval: 0.4x (2/5)
        // At 10s interval: 0.2x (2/10)
        // etc.
        return 2.0 / captureIntervalSeconds
    }

    /// Estimated storage per month based on video quality and capture interval settings
    /// Reference: 50% quality at 2s interval ≈ 6-14 GB/month
    var videoQualityEstimateText: String {
        let qualityMultiplier = videoQualityMultiplier()
        let intervalMultiplier = captureIntervalMultiplier()
        let combinedMultiplier = qualityMultiplier * intervalMultiplier

        let lowGB = 6.0 * combinedMultiplier
        let highGB = 14.0 * combinedMultiplier

        // Format with 1 decimal place
        let lowStr = String(format: "%.1f", lowGB)
        let highStr = String(format: "%.1f", highGB)

        // Handle case where estimate is very small
        if highGB < 0.1 {
            return "Estimated: <0.1 GB per month"
        } else if lowStr == highStr {
            return "Estimated: ~\(lowStr) GB per month"
        }

        return "Estimated: ~\(lowStr)-\(highStr) GB per month"
    }

    /// Estimated storage for capture interval section (same calculation)
    var captureIntervalEstimateText: String {
        videoQualityEstimateText
    }

    var deduplicationThresholdDisplayText: String {
        let percentage = deduplicationThreshold * 100
        return String(format: "%.2f%%", percentage)
    }

    /// Sensitivity description based on deduplication threshold
    var deduplicationSensitivityText: String {
        let threshold = deduplicationThreshold
        if threshold >= 1.0 {
            return "Records every frame (no deduplication)"
        } else if threshold >= 0.9998 {
            return "New frame on: a single word changing"
        } else if threshold >= 0.999 {
            return "New frame on: a few words changing"
        } else if threshold >= 0.9985 {
            return "New frame on: several words changing"
        } else if threshold >= 0.995 {
            return "New frame on: line changes"
        } else if threshold >= 0.99 {
            return "New frame on: multiple line changes"
        } else {
            return "New frame on: paragraph changes"
        }
    }

    var retentionDisplayText: String {
        retentionDisplayTextFor(retentionDays)
    }

    func retentionDisplayTextFor(_ days: Int) -> String {
        switch days {
        case 0: return "Forever"
        case 3: return "3 days"
        case 7: return "1 week"
        case 14: return "2 weeks"
        case 30: return "1 month"
        case 60: return "2 months"
        case 90: return "3 months"
        case 180: return "6 months"
        case 365: return "1 year"
        default: return "\(days) days"
        }
    }

    // MARK: - Retention Change Notification Timer

    func startRetentionChangeTimer() {
        // Reset progress
        retentionChangeProgress = 0

        // Cancel any existing timer
        retentionChangeTimer?.invalidate()

        let duration: Double = 10.0  // 10 seconds
        let updateInterval: Double = 0.05  // 50ms updates for smooth animation
        let totalSteps = duration / updateInterval

        retentionChangeTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [self] timer in
            withAnimation(.linear(duration: updateInterval)) {
                retentionChangeProgress += 1.0 / totalSteps
            }

            if retentionChangeProgress >= 1.0 {
                timer.invalidate()
                dismissRetentionChangeNotification()
            }
        }
    }

    func dismissRetentionChangeNotification() {
        withAnimation(.easeOut(duration: 0.3)) {
            retentionSettingChanged = false
        }
        retentionChangeProgress = 0
        retentionChangeTimer?.invalidate()
        retentionChangeTimer = nil
    }

    // MARK: - Retention Exclusion Data Loading

    func loadRetentionExclusionData() {
        // Load installed apps
        let installed = AppNameResolver.shared.getInstalledApps()
        let installedBundleIDs = Set(installed.map { $0.bundleID })
        installedAppsForRetention = installed.map { (bundleID: $0.bundleID, name: $0.name) }

        // Load other apps from database (apps that were recorded but aren't currently installed)
        Task {
            do {
                let historyBundleIDs = try await coordinatorWrapper.coordinator.getDistinctAppBundleIDs()
                let otherBundleIDs = historyBundleIDs.filter { !installedBundleIDs.contains($0) }
                let resolvedApps = AppNameResolver.shared.resolveAll(bundleIDs: otherBundleIDs)
                let other = resolvedApps.map { appInfo in
                    (bundleID: appInfo.bundleID, name: appInfo.name)
                }

                await MainActor.run {
                    otherAppsForRetention = other
                }
            } catch {
                Log.error("[Settings] Failed to load history apps for retention: \(error)", category: .ui)
            }

            // Load tags
            do {
                let tags = try await coordinatorWrapper.coordinator.getAllTags()
                await MainActor.run {
                    availableTagsForRetention = tags
                }
            } catch {
                Log.error("[Settings] Failed to load tags for retention: \(error)", category: .ui)
            }
        }
    }

    /// Toggle an app in/out of retention exclusions
    func toggleRetentionExcludedApp(_ bundleID: String?) {
        if let bundleID = bundleID {
            var current = retentionExcludedApps
            if current.contains(bundleID) {
                current.remove(bundleID)
            } else {
                current.insert(bundleID)
            }
            retentionExcludedAppsString = current.sorted().joined(separator: ",")
        } else {
            // nil passed - clear exclusions
            retentionExcludedAppsString = ""
        }
    }

    /// Toggle a tag in/out of retention exclusions
    func toggleRetentionExcludedTag(_ tagID: TagID?) {
        if let tagID = tagID {
            var current = retentionExcludedTagIds
            if current.contains(tagID.value) {
                current.remove(tagID.value)
            } else {
                current.insert(tagID.value)
            }
            retentionExcludedTagIdsString = current.sorted().map { String($0) }.joined(separator: ",")
        } else {
            // nil passed - clear exclusions
            retentionExcludedTagIdsString = ""
        }
    }

    /// Clear all retention exclusions
    func clearRetentionExclusions() {
        retentionExcludedAppsString = ""
        retentionExcludedTagIdsString = ""
    }

    // MARK: - Advanced Settings Actions

    func loadDatabaseSchema() {
        Task {
            do {
                let schema = try await coordinatorWrapper.coordinator.getDatabaseSchemaDescription()
                await MainActor.run {
                    databaseSchemaText = schema
                }
            } catch {
                await MainActor.run {
                    databaseSchemaText = "Error loading schema: \(error.localizedDescription)"
                }
            }
        }
    }

    func restartApp() {
        AppRelaunch.relaunch()
    }

    func restartAndResumeRecording() {
        // Set flag in UserDefaults to auto-start recording on next launch
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        defaults.set(true, forKey: "shouldAutoStartRecording")
        defaults.synchronize()
        Log.info("Set shouldAutoStartRecording flag for restart", category: .ui)

        // Restart the app
        AppRelaunch.relaunch()
    }

    func selectRetraceDBLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a location for the Retrace database"
        panel.prompt = "Select"

        // Open to current location if set, otherwise default storage root
        if let currentPath = customRetraceDBLocation {
            panel.directoryURL = URL(fileURLWithPath: (currentPath as NSString).deletingLastPathComponent)
        } else {
            panel.directoryURL = URL(fileURLWithPath: AppPaths.expandedStorageRoot)
        }

        if panel.runModal() == .OK, let url = panel.url {
            let selectedPath = url.path
            let defaultPath = NSString(string: AppPaths.defaultStorageRoot).expandingTildeInPath
            let currentPath = customRetraceDBLocation ?? defaultPath

            // Check if selecting the same location that's currently active
            if selectedPath == currentPath {
                Log.info("Retrace database location unchanged (same as current): \(selectedPath)", category: .ui)
                return
            }

            // Validate the selected folder
            let fm = FileManager.default
            let dbPath = "\(selectedPath)/retrace.db"
            let chunksPath = "\(selectedPath)/chunks"
            let hasDatabase = fm.fileExists(atPath: dbPath)
            let hasChunks = fm.fileExists(atPath: chunksPath)

            // If has database, verify it's a valid Retrace database
            if hasDatabase {
                let verification = verifyRetraceDatabase(at: dbPath)
                if !verification.isValid {
                    showDatabaseAlert(
                        type: .error,
                        title: "Invalid Retrace Database",
                        message: verification.error ?? "The selected folder contains a retrace.db file that is not a valid Retrace database."
                    )
                    return
                }

                // Valid database but no chunks - ask if they want to continue
                if !hasChunks {
                    let shouldContinue = showDatabaseConfirmation(
                        title: "Missing Chunks Folder",
                        message: "The selected folder has retrace.db but is missing the 'chunks' folder with video files.\n\nRetrace may not be able to load existing video frames.\n\nDo you want to continue anyway?",
                        primaryButton: "Continue Anyway"
                    )
                    if !shouldContinue {
                        return
                    }
                }
            }

            // If no database, check if directory is empty or has other files
            if !hasDatabase {
                let contents = (try? fm.contentsOfDirectory(atPath: selectedPath)) ?? []
                // Filter out hidden files like .DS_Store
                let visibleContents = contents.filter { !$0.hasPrefix(".") }

                if !visibleContents.isEmpty {
                    // Folder has other files - show error dialog
                    showDatabaseAlert(
                        type: .error,
                        title: "Invalid Folder Selection",
                        message: "The selected folder contains other files but is not a valid Retrace database folder.\n\nPlease select either:\n• An existing Retrace folder (with retrace.db)\n• An empty folder for a new database"
                    )
                    return
                }
            }

            // If selecting the default location, clear custom path
            if selectedPath == defaultPath {
                customRetraceDBLocation = nil
                Log.info("Retrace database location reset to default: \(selectedPath)", category: .ui)
            } else {
                customRetraceDBLocation = selectedPath
                Log.info("Retrace database location changed to: \(selectedPath)", category: .ui)
            }
        }
    }

    func selectRewindDBLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.database, .data]
        panel.message = "Choose the Rewind database file (db-enc.sqlite3)"
        panel.prompt = "Select"

        // Open to current location if set, otherwise default Rewind storage root
        if let currentPath = customRewindDBLocation {
            panel.directoryURL = URL(fileURLWithPath: (currentPath as NSString).deletingLastPathComponent)
        } else {
            panel.directoryURL = URL(fileURLWithPath: AppPaths.expandedRewindStorageRoot)
        }

        if panel.runModal() == .OK, let url = panel.url {
            let selectedPath = url.path

            // Check if the selected file exists
            guard FileManager.default.fileExists(atPath: selectedPath) else {
                Log.warning("Selected Rewind database file does not exist: \(selectedPath)", category: .ui)
                return
            }

            // Verify it's a valid Rewind database using SQLCipher
            let verificationResult = verifyRewindDatabase(at: selectedPath)
            guard verificationResult.isValid else {
                showDatabaseAlert(
                    type: .error,
                    title: "Invalid Rewind Database",
                    message: verificationResult.error ?? "The selected file is not a valid Rewind database."
                )
                return
            }

            let parentDir = (selectedPath as NSString).deletingLastPathComponent
            let chunksPath = "\(parentDir)/chunks"

            // Check if chunks directory exists
            if FileManager.default.fileExists(atPath: chunksPath) {
                // Valid Rewind database structure - apply immediately
                applyRewindDBLocation(selectedPath)
            } else {
                // Database exists but no chunks folder - ask user if they want to continue
                let shouldContinue = showDatabaseConfirmation(
                    title: "Missing Chunks Folder",
                    message: "The selected Rewind database exists, but the 'chunks' folder (video storage) was not found in the same directory.\n\nRetrace may not be able to load video frames from this database.",
                    primaryButton: "Continue Anyway"
                )
                if shouldContinue {
                    applyRewindDBLocation(selectedPath)
                }
            }
        }
    }

    /// Verifies that a file is a valid Retrace database (unencrypted SQLite with expected tables)
    private func verifyRetraceDatabase(at path: String) -> (isValid: Bool, error: String?) {
        var db: OpaquePointer?

        // Try to open the database
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            return (false, "Failed to open database: \(errorMsg)")
        }

        // Verify we can read from sqlite_master (confirms it's a valid SQLite database)
        var testStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &testStmt, nil) == SQLITE_OK,
              sqlite3_step(testStmt) == SQLITE_ROW else {
            sqlite3_finalize(testStmt)
            sqlite3_close(db)
            return (false, "File is not a valid SQLite database.")
        }
        sqlite3_finalize(testStmt)

        // Check for Retrace-specific tables (frame, segment, video)
        let requiredTables = ["frame", "segment", "video"]
        for table in requiredTables {
            var stmt: OpaquePointer?
            let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='\(table)'"
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else {
                sqlite3_finalize(stmt)
                sqlite3_close(db)
                return (false, "Database is missing required '\(table)' table. This may not be a Retrace database.")
            }
            sqlite3_finalize(stmt)
        }

        sqlite3_close(db)
        return (true, nil)
    }

    /// Verifies that a file is a valid Rewind database by attempting to open it with SQLCipher (encrypted)
    private func verifyRewindDatabase(at path: String) -> (isValid: Bool, error: String?) {
        var db: OpaquePointer?

        // Try to open the database
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            return (false, "Failed to open database: \(errorMsg)")
        }

        // Set the Rewind encryption key
        let rewindPassword = "soiZ58XZJhdka55hLUp18yOtTUTDXz7Diu7Z4JzuwhRwGG13N6Z9RTVU1fGiKkuF"
        let keySQL = "PRAGMA key = '\(rewindPassword)'"
        var keyError: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, keySQL, nil, nil, &keyError) != SQLITE_OK {
            let error = keyError.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(keyError)
            sqlite3_close(db)
            return (false, "Failed to set encryption key: \(error)")
        }

        // Set cipher compatibility (Rewind uses SQLCipher 4)
        var compatError: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, "PRAGMA cipher_compatibility = 4", nil, nil, &compatError) != SQLITE_OK {
            let error = compatError.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(compatError)
            sqlite3_close(db)
            return (false, "Failed to set cipher compatibility: \(error)")
        }

        // Verify connection by querying sqlite_master
        var testStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &testStmt, nil) == SQLITE_OK,
              sqlite3_step(testStmt) == SQLITE_ROW else {
            sqlite3_finalize(testStmt)
            sqlite3_close(db)
            return (false, "Database encryption verification failed. This may not be a Rewind database.")
        }
        sqlite3_finalize(testStmt)

        // Check for Rewind-specific table (frame table)
        var frameStmt: OpaquePointer?
        let frameQuery = "SELECT name FROM sqlite_master WHERE type='table' AND name='frame'"
        guard sqlite3_prepare_v2(db, frameQuery, -1, &frameStmt, nil) == SQLITE_OK,
              sqlite3_step(frameStmt) == SQLITE_ROW else {
            sqlite3_finalize(frameStmt)
            sqlite3_close(db)
            return (false, "Database does not contain expected Rewind tables (missing 'frame' table).")
        }
        sqlite3_finalize(frameStmt)

        sqlite3_close(db)
        return (true, nil)
    }

    func applyRewindDBLocation(_ path: String) {
        customRewindDBLocation = path
        Log.info("Rewind database location changed to: \(path)", category: .ui)

        // Apply changes immediately by reconnecting Rewind source
        Task {
            let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
            let useRewindData = defaults.bool(forKey: "useRewindData")

            if useRewindData {
                Log.info("Reconnecting Rewind source with new location", category: .ui)
                // Disconnect old source
                await coordinatorWrapper.coordinator.setRewindSourceEnabled(false)
                // Reconnect with new location
                await coordinatorWrapper.coordinator.setRewindSourceEnabled(true)
                Log.info("✓ Rewind source reconnected", category: .ui)

                // Notify timeline to reload
                await MainActor.run {
                    SearchViewModel.clearPersistedSearchCache()
                    NotificationCenter.default.post(name: .dataSourceDidChange, object: nil)
                    Log.info("✓ Timeline notified of Rewind database change", category: .ui)
                }
            } else {
                Log.info("Rewind data not enabled, skipping reconnection", category: .ui)
            }
        }
    }

    func resetDatabaseLocations() {
        let hadCustomRewind = customRewindDBLocation != nil

        customRetraceDBLocation = nil
        customRewindDBLocation = nil
        Log.info("Database locations reset to defaults", category: .ui)

        // If Rewind was customized, apply the default location immediately
        if hadCustomRewind {
            Task {
                let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
                let useRewindData = defaults.bool(forKey: "useRewindData")

                if useRewindData {
                    Log.info("Reconnecting Rewind source with default location", category: .ui)
                    // Disconnect and reconnect to pick up default path
                    await coordinatorWrapper.coordinator.setRewindSourceEnabled(false)
                    await coordinatorWrapper.coordinator.setRewindSourceEnabled(true)
                    Log.info("✓ Rewind source reconnected to default location", category: .ui)

                    await MainActor.run {
                        SearchViewModel.clearPersistedSearchCache()
                        NotificationCenter.default.post(name: .dataSourceDidChange, object: nil)
                    }
                }
            }
        }
    }

    func resetAllSettings() {
        // Reset all UserDefaults to their default values
        let domain = "io.retrace.app"
        settingsStore.removePersistentDomain(forName: domain)
        settingsStore.synchronize()

        // Reset all pages using SettingsDefaults as source of truth
        resetGeneralSettings()
        resetCaptureSettings()
        resetStorageSettings()
        resetPrivacySettings()
        resetAdvancedSettings()
    }

    func deleteAllData() {
        Task {
            // Stop capture pipeline first
            try? await coordinatorWrapper.stopPipeline()

            // Delete the entire storage directory (respects custom location)
            let storagePath = AppPaths.expandedStorageRoot
            try? FileManager.default.removeItem(atPath: storagePath)

            // Quit the app - user will need to restart
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func clearAppNameCache() {
        let entriesCleared = AppNameResolver.shared.clearCache()
        if entriesCleared > 0 {
            cacheClearMessage = "Cleared \(entriesCleared) cached app names. Changes take effect immediately."
        } else {
            cacheClearMessage = "Cache was already empty. No restart needed."
        }

        // Auto-hide the message after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            cacheClearMessage = nil
        }
    }

    // MARK: - Alert Helpers

    enum AlertType {
        case error
        case warning
        case info

        var style: NSAlert.Style {
            switch self {
            case .error: return .critical
            case .warning: return .warning
            case .info: return .informational
            }
        }
    }

    /// Shows a simple alert dialog with an OK button
    func showDatabaseAlert(type: AlertType, title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = type.style
        alert.addButton(withTitle: "OK")
        alert.runModal()

        switch type {
        case .error:
            Log.error("\(title): \(message)", category: .ui)
        case .warning:
            Log.warning("\(title): \(message)", category: .ui)
        case .info:
            Log.info("\(title): \(message)", category: .ui)
        }
    }

    /// Shows a confirmation dialog with Continue/Cancel buttons
    /// Returns true if the user clicked the primary button
    func showDatabaseConfirmation(title: String, message: String, primaryButton: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: primaryButton)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Supporting Types

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case capture = "Capture"
    case storage = "Storage"
    case exportData = "Export & Data"
    case privacy = "Privacy"
    case power = "Power"
    case tags = "Tags"
    // case search = "Search"  // TODO: Add Search settings later
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
        // case .search: return "magnifyingglass"
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
        // case .search: return "Search behavior and ranking"
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
        // case .search: return .retraceAccentGradient
        case .advanced: return .retracePurpleGradient
        }
    }

    /// Returns a reset action for this tab if it has resettable settings
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
            return nil  // No resettable settings
        }
    }
}

enum ThemePreference: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
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

// MARK: - Excluded App Types

/// Information about an excluded app
struct ExcludedAppInfo: Codable, Identifiable, Equatable {
    let bundleID: String
    let name: String
    let iconPath: String?

    var id: String { bundleID }

    /// Create from an app bundle URL
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

// MARK: - Quick Delete Types

/// Options for quick delete time ranges
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

/// Result info for delete operation feedback
struct DeleteResultInfo {
    let success: Bool
    let message: String
}

/// Custom button for quick delete with loading state
private struct QuickDeleteButton: View {
    let title: String
    let option: QuickDeleteOption
    let isDeleting: Bool
    let currentOption: QuickDeleteOption?
    let action: () -> Void

    private var isThisDeleting: Bool {
        isDeleting && currentOption == option
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isThisDeleting {
                    SpinnerView(size: 14, lineWidth: 2, color: .retraceDanger)
                } else {
                    Text(title)
                        .font(.retraceCaptionMedium)
                }
            }
            .frame(minWidth: 70)
            .foregroundColor(isDeleting ? .retraceSecondary : .retraceDanger)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.retraceDanger.opacity(isDeleting ? 0.05 : 0.1))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.retraceDanger.opacity(isDeleting ? 0.15 : 0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
    }
}

// MARK: - Quick Delete Implementation

extension SettingsView {
    /// Perform quick delete for the specified time range
    func performQuickDelete(option: QuickDeleteOption) {
        isDeleting = true
        deletingOption = option
        deleteResult = nil

        Task {
            do {
                // Use deleteRecentData to delete frames NEWER than the cutoff date
                let result = try await coordinatorWrapper.coordinator.deleteRecentData(newerThan: option.cutoffDate)

                await MainActor.run {
                    isDeleting = false
                    deletingOption = nil
                    if result.deletedFrames > 0 {
                        deleteResult = DeleteResultInfo(
                            success: true,
                            message: "Deleted \(result.deletedFrames) frames from the \(option.displayName)"
                        )
                        // Notify timeline to reload so deleted frames don't appear
                        NotificationCenter.default.post(name: .dataSourceDidChange, object: nil)
                    } else {
                        deleteResult = DeleteResultInfo(
                            success: true,
                            message: "No recordings found in the \(option.displayName)"
                        )
                    }

                    // Auto-hide result after 5 seconds
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        await MainActor.run {
                            withAnimation {
                                deleteResult = nil
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    deletingOption = nil
                    deleteResult = DeleteResultInfo(
                        success: false,
                        message: "Delete failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
}

// MARK: - Excluded Apps Management

extension SettingsView {
    /// Add multiple apps to the exclusion list
    func addExcludedApps(_ newApps: [ExcludedAppInfo]) {
        guard !newApps.isEmpty else { return }

        var currentApps: [ExcludedAppInfo] = []
        if !excludedAppsString.isEmpty,
           let data = excludedAppsString.data(using: .utf8),
           let apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) {
            currentApps = apps
        }

        // Filter out duplicates
        var addedCount = 0
        for app in newApps {
            if !currentApps.contains(where: { $0.bundleID == app.bundleID }) {
                currentApps.append(app)
                addedCount += 1
            }
        }

        guard addedCount > 0 else { return }

        // Save back
        if let newData = try? JSONEncoder().encode(currentApps),
           let string = String(data: newData, encoding: .utf8) {
            excludedAppsString = string
        }

        // Update capture config in real-time
        updateExcludedAppsConfig()

        // Show feedback
        showExcludedAppsUpdateFeedback(added: addedCount)
    }

    /// Add an app to the exclusion list (single app - kept for compatibility)
    func addExcludedApp(_ app: ExcludedAppInfo) {
        addExcludedApps([app])
    }

    /// Remove an app from the exclusion list
    func removeExcludedApp(_ app: ExcludedAppInfo) {
        guard let data = excludedAppsString.data(using: .utf8),
              var apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) else {
            return
        }

        apps.removeAll { $0.bundleID == app.bundleID }

        // Save back
        if let newData = try? JSONEncoder().encode(apps),
           let string = String(data: newData, encoding: .utf8) {
            excludedAppsString = string
        } else {
            excludedAppsString = ""
        }

        // Update capture config in real-time
        updateExcludedAppsConfig()

        // Show feedback
        showExcludedAppsUpdateFeedback(removed: app.name)
    }

    /// Update the capture config with current excluded apps
    private func updateExcludedAppsConfig() {
        Task {
            let coordinator = coordinatorWrapper.coordinator
            let currentConfig = await coordinator.getCaptureConfig()

            // Build new excluded bundle IDs set
            var excludedBundleIDs: Set<String> = ["com.apple.loginwindow"] // Always exclude login screen
            for app in excludedApps {
                excludedBundleIDs.insert(app.bundleID)
            }

            let newConfig = CaptureConfig(
                captureIntervalSeconds: currentConfig.captureIntervalSeconds,
                adaptiveCaptureEnabled: currentConfig.adaptiveCaptureEnabled,
                deduplicationThreshold: currentConfig.deduplicationThreshold,
                maxResolution: currentConfig.maxResolution,
                excludedAppBundleIDs: excludedBundleIDs,
                excludePrivateWindows: currentConfig.excludePrivateWindows,
                customPrivateWindowPatterns: currentConfig.customPrivateWindowPatterns,
                showCursor: currentConfig.showCursor,
                captureOnWindowChange: currentConfig.captureOnWindowChange
            )

            do {
                try await coordinator.updateCaptureConfig(newConfig)
                Log.info("[SettingsView] Excluded apps updated: \(excludedBundleIDs.count - 1) apps excluded", category: .ui)
            } catch {
                Log.error("[SettingsView] Failed to update excluded apps config: \(error)", category: .ui)
            }
        }
    }

    /// Show brief feedback for excluded apps changes
    private func showExcludedAppsUpdateFeedback(added: Int) {
        let message = added == 1 ? "App excluded" : "\(added) apps excluded"
        excludedAppsUpdateMessage = message

        // Auto-dismiss after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                excludedAppsUpdateMessage = nil
            }
        }
    }

    /// Show brief feedback for app removal
    private func showExcludedAppsUpdateFeedback(removed appName: String) {
        excludedAppsUpdateMessage = "\(appName) removed"

        // Auto-dismiss after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                excludedAppsUpdateMessage = nil
            }
        }
    }

    /// Show the app picker panel with multiple selection support
    func showAppPickerMultiple(completion: @escaping ([ExcludedAppInfo]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Apps to Exclude"
        panel.message = "Choose applications that should not be recorded (Cmd+Click to select multiple)"
        panel.prompt = "Exclude Apps"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.begin { response in
            guard response == .OK else {
                completion([])
                return
            }

            let apps = panel.urls.compactMap { ExcludedAppInfo.from(appURL: $0) }
            completion(apps)
        }
    }

    /// Show the app picker panel (single selection - kept for compatibility)
    func showAppPicker(completion: @escaping (ExcludedAppInfo?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select an App to Exclude"
        panel.message = "Choose an application that should not be recorded"
        panel.prompt = "Exclude App"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }

            let appInfo = ExcludedAppInfo.from(appURL: url)
            completion(appInfo)
        }
    }
}

// MARK: - Permission Checking

extension SettingsView {
    /// Check all permissions on appear
    func checkPermissions() async {
        hasScreenRecordingPermission = checkScreenRecordingPermission()
        hasAccessibilityPermission = checkAccessibilityPermission()
    }

    /// Check screen recording permission without prompting
    func checkScreenRecordingPermission() -> Bool {
        // CGPreflightScreenCaptureAccess checks without triggering a prompt
        return CGPreflightScreenCaptureAccess()
    }

    /// Check accessibility permission without prompting
    func checkAccessibilityPermission() -> Bool {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ]
        return AXIsProcessTrustedWithOptions(options) as Bool
    }

    /// Request screen recording permission (triggers system dialog)
    func requestScreenRecordingPermission() {
        Task {
            do {
                // This triggers the system permission dialog
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                // Re-check permission status after request
                await MainActor.run {
                    hasScreenRecordingPermission = checkScreenRecordingPermission()
                }
            } catch {
                Log.warning("[SettingsView] Screen recording permission request error: \(error)", category: .ui)
            }
        }
    }

    /// Request accessibility permission (opens system prompt)
    func requestAccessibilityPermission() {
        // Request with prompt
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)

        // Poll for permission change
        Task {
            for _ in 0..<30 { // Check for up to 30 seconds
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let granted = checkAccessibilityPermission()
                if granted {
                    await MainActor.run {
                        hasAccessibilityPermission = true
                    }
                    break
                }
            }
        }
    }

    /// Open System Settings to Screen Recording privacy pane
    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Open System Settings to Accessibility privacy pane
    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Launch at Login Helper

import ServiceManagement

extension SettingsView {
    /// Enable or disable launch at login using SMAppService (macOS 13+)
    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    return
                }
                try SMAppService.mainApp.register()
            } else {
                guard case SMAppService.Status.enabled = SMAppService.mainApp.status else {
                    return
                }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("[SettingsView] Failed to \(enabled ? "enable" : "disable") launch at login: \(error)", category: .ui)
        }
    }

    /// Show or hide the menu bar icon
    private func setMenuBarIconVisibility(visible: Bool) {
        if let menuBarManager = MenuBarManager.shared {
            if visible {
                menuBarManager.show()
            } else {
                menuBarManager.hide()
            }
        }
    }

    /// Apply theme preference
    private func applyTheme(_ theme: ThemePreference) {
        switch theme {
        case .auto:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Update deduplication setting in capture config
    private func updateDeduplicationSetting(enabled: Bool) {
        Task {
            let coordinator = coordinatorWrapper.coordinator

            // Get current config from capture manager
            let currentConfig = await coordinator.getCaptureConfig()

            // Create new config with updated deduplication setting
            let newConfig = CaptureConfig(
                captureIntervalSeconds: currentConfig.captureIntervalSeconds,
                adaptiveCaptureEnabled: enabled,
                deduplicationThreshold: deduplicationThreshold,
                maxResolution: currentConfig.maxResolution,
                excludedAppBundleIDs: currentConfig.excludedAppBundleIDs,
                excludePrivateWindows: currentConfig.excludePrivateWindows,
                customPrivateWindowPatterns: currentConfig.customPrivateWindowPatterns,
                showCursor: currentConfig.showCursor,
                captureOnWindowChange: currentConfig.captureOnWindowChange
            )

            // Update the capture manager config
            do {
                try await coordinator.updateCaptureConfig(newConfig)
                Log.info("[SettingsView] Deduplication setting updated to: \(enabled)", category: .ui)
            } catch {
                Log.error("[SettingsView] Failed to update deduplication setting: \(error)", category: .ui)
            }
        }
    }

    /// Update deduplication threshold in capture config
    private func updateDeduplicationThreshold() {
        Task {
            let coordinator = coordinatorWrapper.coordinator

            // Get current config from capture manager
            let currentConfig = await coordinator.getCaptureConfig()

            // Create new config with updated threshold
            let newConfig = CaptureConfig(
                captureIntervalSeconds: currentConfig.captureIntervalSeconds,
                adaptiveCaptureEnabled: currentConfig.adaptiveCaptureEnabled,
                deduplicationThreshold: deduplicationThreshold,
                maxResolution: currentConfig.maxResolution,
                excludedAppBundleIDs: currentConfig.excludedAppBundleIDs,
                excludePrivateWindows: currentConfig.excludePrivateWindows,
                customPrivateWindowPatterns: currentConfig.customPrivateWindowPatterns,
                showCursor: currentConfig.showCursor,
                captureOnWindowChange: currentConfig.captureOnWindowChange
            )

            // Update the capture manager config
            do {
                try await coordinator.updateCaptureConfig(newConfig)
                Log.info("[SettingsView] Deduplication threshold updated to: \(deduplicationThreshold)", category: .ui)
                showCompressionUpdateFeedback()
            } catch {
                Log.error("[SettingsView] Failed to update deduplication threshold: \(error)", category: .ui)
            }
        }
    }

    /// Update capture on window change setting in capture config
    private func updateCaptureOnWindowChangeSetting() {
        Task {
            let coordinator = coordinatorWrapper.coordinator

            // Get current config from capture manager
            let currentConfig = await coordinator.getCaptureConfig()

            // Create new config with updated setting
            let newConfig = CaptureConfig(
                captureIntervalSeconds: currentConfig.captureIntervalSeconds,
                adaptiveCaptureEnabled: currentConfig.adaptiveCaptureEnabled,
                deduplicationThreshold: currentConfig.deduplicationThreshold,
                maxResolution: currentConfig.maxResolution,
                excludedAppBundleIDs: currentConfig.excludedAppBundleIDs,
                excludePrivateWindows: currentConfig.excludePrivateWindows,
                customPrivateWindowPatterns: currentConfig.customPrivateWindowPatterns,
                showCursor: currentConfig.showCursor,
                captureOnWindowChange: captureOnWindowChange
            )

            // Update the capture manager config
            do {
                try await coordinator.updateCaptureConfig(newConfig)
                Log.info("[SettingsView] Capture on window change updated to: \(captureOnWindowChange)", category: .ui)
                showCaptureUpdateFeedback()
            } catch {
                Log.error("[SettingsView] Failed to update capture on window change: \(error)", category: .ui)
            }
        }
    }

    /// Show brief "Updated" feedback for compression settings
    private func showCompressionUpdateFeedback() {
        compressionUpdateMessage = "Updated"

        // Auto-dismiss after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                compressionUpdateMessage = nil
            }
        }
    }

    /// Show brief "Updated" feedback for capture interval settings
    private func showCaptureUpdateFeedback() {
        captureUpdateMessage = "Updated"

        // Auto-dismiss after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                captureUpdateMessage = nil
            }
        }
    }

    /// Show brief "Updated" feedback for scrubbing animation settings
    private func showScrubbingAnimationUpdateFeedback() {
        scrubbingAnimationUpdateMessage = "Updated"

        // Auto-dismiss after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                scrubbingAnimationUpdateMessage = nil
            }
        }
    }

    // MARK: - Section Reset Functions

    /// Reset all General settings to defaults
    func resetGeneralSettings() {
        // Keyboard shortcuts
        timelineShortcut = SettingsShortcutKey(from: .defaultTimeline)
        dashboardShortcut = SettingsShortcutKey(from: .defaultDashboard)
        recordingShortcut = SettingsShortcutKey(from: .defaultRecording)
        Task { await saveShortcuts() }

        // Startup
        launchAtLogin = SettingsDefaults.launchAtLogin
        setLaunchAtLogin(enabled: SettingsDefaults.launchAtLogin)
        showMenuBarIcon = SettingsDefaults.showMenuBarIcon

        // Updates
        UpdaterManager.shared.automaticUpdatesEnabled = SettingsDefaults.automaticUpdates

        // Appearance
        theme = SettingsDefaults.theme
        fontStyle = SettingsDefaults.fontStyle
        RetraceFont.currentStyle = SettingsDefaults.fontStyle
        colorThemePreference = SettingsDefaults.colorTheme
        MilestoneCelebrationManager.setColorThemePreference(.blue)
        timelineColoredBorders = SettingsDefaults.timelineColoredBorders
        scrubbingAnimationDuration = SettingsDefaults.scrubbingAnimationDuration
        scrollSensitivity = SettingsDefaults.scrollSensitivity
    }

    /// Reset all Capture settings to defaults
    func resetCaptureSettings() {
        pauseReminderDelayMinutes = SettingsDefaults.pauseReminderDelayMinutes
        captureIntervalSeconds = SettingsDefaults.captureIntervalSeconds
        videoQuality = SettingsDefaults.videoQuality
        deduplicationThreshold = SettingsDefaults.deduplicationThreshold
        deleteDuplicateFrames = SettingsDefaults.deleteDuplicateFrames
        captureOnWindowChange = SettingsDefaults.captureOnWindowChange

        // Apply capture config changes immediately
        Task {
            let coordinator = coordinatorWrapper.coordinator
            let currentConfig = await coordinator.getCaptureConfig()

            let newConfig = CaptureConfig(
                captureIntervalSeconds: SettingsDefaults.captureIntervalSeconds,
                adaptiveCaptureEnabled: true,
                deduplicationThreshold: SettingsDefaults.deduplicationThreshold,
                maxResolution: currentConfig.maxResolution,
                excludedAppBundleIDs: currentConfig.excludedAppBundleIDs,
                excludePrivateWindows: currentConfig.excludePrivateWindows,
                customPrivateWindowPatterns: currentConfig.customPrivateWindowPatterns,
                showCursor: currentConfig.showCursor,
                captureOnWindowChange: SettingsDefaults.captureOnWindowChange
            )

            do {
                try await coordinator.updateCaptureConfig(newConfig)
                Log.info("[SettingsView] Capture settings reset to defaults", category: .ui)
            } catch {
                Log.error("[SettingsView] Failed to reset capture settings: \(error)", category: .ui)
            }
        }

        showCaptureUpdateFeedback()
    }

    /// Reset all Storage settings to defaults
    func resetStorageSettings() {
        retentionDays = SettingsDefaults.retentionDays
        maxStorageGB = SettingsDefaults.maxStorageGB
        retentionSettingChanged = true
        startRetentionChangeTimer()
    }

    /// Reset all Privacy settings to defaults
    func resetPrivacySettings() {
        excludedAppsString = SettingsDefaults.excludedApps
        excludePrivateWindows = SettingsDefaults.excludePrivateWindows
        excludeSafariPrivate = SettingsDefaults.excludeSafariPrivate
        excludeChromeIncognito = SettingsDefaults.excludeChromeIncognito

        // Apply to capture config immediately
        Task {
            let coordinator = coordinatorWrapper.coordinator
            let currentConfig = await coordinator.getCaptureConfig()

            let newConfig = CaptureConfig(
                captureIntervalSeconds: currentConfig.captureIntervalSeconds,
                adaptiveCaptureEnabled: currentConfig.adaptiveCaptureEnabled,
                deduplicationThreshold: currentConfig.deduplicationThreshold,
                maxResolution: currentConfig.maxResolution,
                excludedAppBundleIDs: [],
                excludePrivateWindows: SettingsDefaults.excludePrivateWindows,
                customPrivateWindowPatterns: currentConfig.customPrivateWindowPatterns,
                showCursor: currentConfig.showCursor,
                captureOnWindowChange: currentConfig.captureOnWindowChange
            )

            do {
                try await coordinator.updateCaptureConfig(newConfig)
                Log.info("[SettingsView] Privacy settings reset to defaults", category: .ui)
            } catch {
                Log.error("[SettingsView] Failed to reset privacy settings: \(error)", category: .ui)
            }
        }
    }

    /// Reset all Advanced settings to defaults
    func resetAdvancedSettings() {
        showFrameIDs = SettingsDefaults.showFrameIDs
        enableFrameIDSearch = SettingsDefaults.enableFrameIDSearch
        showVideoControls = SettingsDefaults.showVideoControls
    }
}

// MARK: - Settings Shortcut Key Model

struct SettingsShortcutKey: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    /// An empty shortcut (no key assigned)
    static let empty = SettingsShortcutKey(key: "", modifiers: [])

    /// Whether this shortcut is empty (cleared)
    var isEmpty: Bool {
        key.isEmpty
    }

    /// Create from ShortcutConfig (source of truth)
    init(from config: ShortcutConfig) {
        self.key = config.key
        self.modifiers = config.modifiers.nsModifiers
    }

    /// Create directly with key and modifiers
    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    var displayString: String {
        if isEmpty { return "None" }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key)
        return parts.joined(separator: " ")
    }

    var modifierSymbols: [String] {
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        return symbols
    }

    /// Convert to ShortcutConfig for storage
    var toConfig: ShortcutConfig {
        ShortcutConfig(key: key, modifiers: ShortcutModifiers(from: modifiers))
    }

    static func == (lhs: SettingsShortcutKey, rhs: SettingsShortcutKey) -> Bool {
        lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
    }
}

// MARK: - Settings Shortcut Capture Field

struct SettingsShortcutCaptureField: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var capturedShortcut: SettingsShortcutKey
    let otherShortcuts: [SettingsShortcutKey]
    let onDuplicateAttempt: () -> Void
    let onShortcutCaptured: () -> Void

    func makeNSView(context: Context) -> SettingsShortcutCaptureNSView {
        let view = SettingsShortcutCaptureNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SettingsShortcutCaptureNSView, context: Context) {
        // Update coordinator's parent to get latest otherShortcuts values
        context.coordinator.parent = self
        nsView.isRecordingEnabled = isRecording
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator {
        var parent: SettingsShortcutCaptureField

        init(_ parent: SettingsShortcutCaptureField) {
            self.parent = parent
        }

        func handleKeyPress(event: NSEvent) {
            guard parent.isRecording else { return }

            let keyName = mapKeyCodeToString(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // Escape key cancels recording
            if event.keyCode == 53 {
                parent.isRecording = false
                return
            }

            // Delete/Backspace key (without modifiers) clears the shortcut
            if event.keyCode == 51 && modifiers.isEmpty {
                parent.capturedShortcut = .empty
                parent.isRecording = false
                // Delay callback to allow SwiftUI binding to propagate
                DispatchQueue.main.async { [self] in
                    self.parent.onShortcutCaptured()
                }
                return
            }

            // Require at least one modifier key for setting a shortcut
            if modifiers.isEmpty {
                return
            }

            let newShortcut = SettingsShortcutKey(key: keyName, modifiers: modifiers)

            // Check for duplicate against all other shortcuts
            if parent.otherShortcuts.contains(newShortcut) {
                parent.onDuplicateAttempt()
                parent.isRecording = false
                return
            }

            parent.capturedShortcut = newShortcut
            parent.isRecording = false
            DispatchQueue.main.async { [self] in
                self.parent.onShortcutCaptured()
            }
        }

        private func mapKeyCodeToString(keyCode: UInt16, characters: String?) -> String {
            switch keyCode {
            case 49: return "Space"
            case 36: return "Return"
            case 53: return "Escape"
            case 51: return "Delete"
            case 48: return "Tab"
            case 123: return "←"
            case 124: return "→"
            case 125: return "↓"
            case 126: return "↑"
            case 18: return "1"
            case 19: return "2"
            case 20: return "3"
            case 21: return "4"
            case 23: return "5"
            case 22: return "6"
            case 26: return "7"
            case 28: return "8"
            case 25: return "9"
            case 29: return "0"
            default:
                if let chars = characters, !chars.isEmpty {
                    return chars.uppercased()
                }
                return "Key\(keyCode)"
            }
        }
    }
}

class SettingsShortcutCaptureNSView: NSView {
    weak var coordinator: SettingsShortcutCaptureField.Coordinator?
    var isRecordingEnabled = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if isRecordingEnabled {
            coordinator?.handleKeyPress(event: event)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Database Schema View

private struct DatabaseSchemaView: View {
    let schemaText: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Database Schema")
                    .font(.retraceTitle3)
                    .foregroundColor(.retracePrimary)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.retraceBackground)

            Divider()

            // Schema content
            ScrollView {
                Text(schemaText.isEmpty ? "Loading..." : schemaText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(.retracePrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.black.opacity(0.3))

            Divider()

            // Footer with copy button
            HStack {
                Spacer()

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(schemaText, forType: .string)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy to Clipboard")
                    }
                    .font(.retraceCalloutMedium)
                }
                .buttonStyle(.plain)
                .foregroundColor(.retraceAccent)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.retraceAccent.opacity(0.1))
                .cornerRadius(8)
            }
            .padding()
            .background(Color.retraceBackground)
        }
        .frame(width: 600, height: 500)
        .background(Color.retraceBackground)
        .cornerRadius(12)
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .frame(width: 900, height: 700)
            .preferredColorScheme(.dark)
    }
}
#endif
