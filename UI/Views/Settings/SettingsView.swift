import SwiftUI
import Shared
import AppKit
import App
import ScreenCaptureKit

/// Shared UserDefaults store for consistent settings across debug/release builds
private let settingsStore = UserDefaults(suiteName: "io.retrace.app")

/// Main settings view with sidebar navigation
/// Activated with Cmd+,
public struct SettingsView: View {

    // MARK: - Properties

    @State private var selectedTab: SettingsTab = .general
    @State private var hoveredTab: SettingsTab? = nil
    @AppStorage("launchAtLogin", store: settingsStore) private var launchAtLogin = false
    @AppStorage("showMenuBarIcon", store: settingsStore) private var showMenuBarIcon = true
    @AppStorage("theme", store: settingsStore) private var theme: ThemePreference = .auto
    @AppStorage("retraceColorThemePreference", store: settingsStore) private var colorThemePreference: String = "blue"
    @AppStorage("timelineColoredBorders", store: settingsStore) private var timelineColoredBorders: Bool = true

    // Keyboard shortcuts
    @State private var timelineShortcut = SettingsShortcutKey(from: .defaultTimeline)
    @State private var dashboardShortcut = SettingsShortcutKey(from: .defaultDashboard)
    @State private var isRecordingTimelineShortcut = false
    @State private var isRecordingDashboardShortcut = false
    @State private var shortcutError: String? = nil
    @State private var recordingTimeoutTask: Task<Void, Never>? = nil

    // Capture settings
    @AppStorage("captureIntervalSeconds", store: settingsStore) private var captureIntervalSeconds: Double = 2.0
    @AppStorage("captureResolution", store: settingsStore) private var captureResolution: CaptureResolution = .original
    @AppStorage("captureActiveDisplayOnly", store: settingsStore) private var captureActiveDisplayOnly = false
    @AppStorage("excludeCursor", store: settingsStore) private var excludeCursor = false

    // Storage settings
    @AppStorage("retentionDays", store: settingsStore) private var retentionDays: Int = 0 // 0 = forever
    @State private var retentionSettingChanged = false
    @State private var showRetentionConfirmation = false
    @State private var pendingRetentionDays: Int?
    @AppStorage("maxStorageGB", store: settingsStore) private var maxStorageGB: Double = 50.0
    @AppStorage("videoQuality", store: settingsStore) private var videoQuality: Double = 0.5 // 0.0 = max compression, 1.0 = max quality
    @AppStorage("deleteDuplicateFrames", store: settingsStore) private var deleteDuplicateFrames: Bool = true
    @AppStorage("useRewindData", store: settingsStore) private var useRewindData: Bool = false

    // Database location settings
    @AppStorage("customRetraceDBLocation", store: settingsStore) private var customRetraceDBLocation: String?
    @AppStorage("customRewindDBLocation", store: settingsStore) private var customRewindDBLocation: String?
    @State private var retraceDBLocationChanged = false
    @State private var rewindDBLocationChanged = false
    @State private var showRetraceDBWarning = false
    @State private var pendingRetraceDBPath: String?
    @State private var showRewindDBWarning = false
    @State private var pendingRewindDBPath: String?

    // Privacy settings
    @AppStorage("excludedApps", store: settingsStore) private var excludedAppsString = ""
    // TODO: Re-enable once private window detection is more reliable
    @AppStorage("excludePrivateWindows", store: settingsStore) private var excludePrivateWindows = false

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
    @AppStorage("excludeSafariPrivate", store: settingsStore) private var excludeSafariPrivate = true
    @AppStorage("excludeChromeIncognito", store: settingsStore) private var excludeChromeIncognito = true
    @AppStorage("encryptionEnabled", store: settingsStore) private var encryptionEnabled = true

    // Developer settings
    @AppStorage("showFrameIDs", store: settingsStore) private var showFrameIDs = false
    @AppStorage("enableFrameIDSearch", store: settingsStore) private var enableFrameIDSearch = false

    // Check if Rewind data folder exists
    private var rewindDataExists: Bool {
        let memoryVaultPath = NSHomeDirectory() + "/Library/Application Support/com.memoryvault.MemoryVault"
        return FileManager.default.fileExists(atPath: memoryVaultPath)
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

    // Cache clear feedback
    @State private var cacheClearMessage: String? = nil

    // App coordinator for deletion operations
    @EnvironmentObject private var coordinatorWrapper: AppCoordinatorWrapper

    // MARK: - Body

    public var body: some View {
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
        )
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
                Text("v\(UpdaterManager.shared.currentVersion)")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary.opacity(0.6))
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
                        otherShortcut: dashboardShortcut
                    )

                    Divider()
                        .background(Color.retraceBorder)

                    settingsShortcutRecorderRow(
                        label: "Open Dashboard",
                        shortcut: $dashboardShortcut,
                        isRecording: $isRecordingDashboardShortcut,
                        otherShortcut: timelineShortcut
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
                if isRecordingTimelineShortcut || isRecordingDashboardShortcut {
                    isRecordingTimelineShortcut = false
                    isRecordingDashboardShortcut = false
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
                    isOn: Binding(
                        get: { UpdaterManager.shared.automaticUpdatesEnabled },
                        set: { UpdaterManager.shared.automaticUpdatesEnabled = $0 }
                    )
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
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Font Style")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retracePrimary)

                            Text("Changes require restarting the app to fully apply")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                        }

                        FontStylePicker(selection: Binding(
                            get: { RetraceFont.currentStyle },
                            set: { RetraceFont.currentStyle = $0 }
                        ))
                    }

                    Divider()
                        .background(Color.retraceBorder)

                    // Tier Theme Section
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Accent Color")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retracePrimary)

                            Text("Choose your preferred color theme")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
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
                }
            }
        }
    }

    // MARK: - Shortcut Recorder Row

    private func settingsShortcutRecorderRow(
        label: String,
        shortcut: Binding<SettingsShortcutKey>,
        isRecording: Binding<Bool>,
        otherShortcut: SettingsShortcutKey
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
                    otherShortcut: otherShortcut,
                    onDuplicateAttempt: {
                        shortcutError = "This shortcut is already in use"
                    },
                    onShortcutCaptured: {
                        // Save the shortcut when captured
                        Task {
                            await saveShortcuts()
                        }
                    }
                )
                .frame(width: 0, height: 0)
            )
        }
    }

    // MARK: - Shortcut Persistence

    private static let timelineShortcutKey = "timelineShortcutConfig"
    private static let dashboardShortcutKey = "dashboardShortcutConfig"

    private func loadSavedShortcuts() async {
        // Load directly from UserDefaults (same as OnboardingManager)
        if let data = settingsStore?.data(forKey: Self.timelineShortcutKey),
           let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) {
            timelineShortcut = SettingsShortcutKey(from: config)
        }
        if let data = settingsStore?.data(forKey: Self.dashboardShortcutKey),
           let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) {
            dashboardShortcut = SettingsShortcutKey(from: config)
        }
    }

    private func saveShortcuts() async {
        // Save directly to UserDefaults (same as OnboardingManager)
        if let data = try? JSONEncoder().encode(timelineShortcut.toConfig) {
            settingsStore?.set(data, forKey: Self.timelineShortcutKey)
        }
        if let data = try? JSONEncoder().encode(dashboardShortcut.toConfig) {
            settingsStore?.set(data, forKey: Self.dashboardShortcutKey)
        }
        // Re-register hotkeys with MenuBarManager
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
            if rewindDataExists {
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
                                Text("Retrace Database")
                                    .font(.retraceCalloutMedium)
                                    .foregroundColor(.retracePrimary)
                                Text(customRetraceDBLocation ?? AppPaths.defaultStorageRoot)
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Choose...") {
                                selectRetraceDBLocation()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(coordinatorWrapper.isRunning)
                            .help(coordinatorWrapper.isRunning ? "Stop recording to change Retrace database location" : "")
                        }
                    }

                    Divider()
                        .background(Color.white.opacity(0.1))

                    // Rewind Database Location
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Rewind Database")
                                    .font(.retraceCalloutMedium)
                                    .foregroundColor(.retracePrimary)
                                Text(customRewindDBLocation ?? AppPaths.defaultRewindDBPath)
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Choose...") {
                                selectRewindDBLocation()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if customRetraceDBLocation != nil || customRewindDBLocation != nil {
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

                    // Restart prompt for Retrace database changes only
                    if retraceDBLocationChanged {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Restart the app to apply Retrace database changes")
                                .font(.retraceCaption)
                                .foregroundColor(.retraceSecondary)

                            HStack(spacing: 8) {
                                Button(action: restartApp) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 11))
                                        Text("Restart Now")
                                            .font(.retraceCalloutMedium)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.retraceAccent)
                                .controlSize(.small)

                                Button(action: restartAndResumeRecording) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "record.circle")
                                            .font(.system(size: 11))
                                        Text("Restart & Resume Recording")
                                            .font(.retraceCalloutMedium)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(12)
                        .background(Color.retraceAccent.opacity(0.1))
                        .cornerRadius(8)
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
                        Text(retentionDisplayText)
                            .font(.retraceCalloutBold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.retraceAccent.opacity(0.3))
                            .cornerRadius(8)
                    }

                    RetentionPolicyPicker(currentDays: retentionDays) { newDays in
                        if newDays != retentionDays {
                            pendingRetentionDays = newDays
                            showRetentionConfirmation = true
                        }
                    }

                    if retentionSettingChanged {
                        HStack {
                            Text("Changes will take effect within an hour or on next launch")
                                .font(.retraceCaption)
                                .foregroundColor(.retraceSecondary)
                            Spacer()
                            Button("Restart Now") {
                                restartApp()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.retraceAccent)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .alert("Change Retention Policy?", isPresented: $showRetentionConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingRetentionDays = nil
                }
                Button("Confirm", role: .destructive) {
                    if let newDays = pendingRetentionDays {
                        retentionDays = newDays
                        retentionSettingChanged = true
                    }
                    pendingRetentionDays = nil
                }
            } message: {
                if let pendingDays = pendingRetentionDays {
                    Text("Are you sure you want to change the retention policy to \(retentionDisplayTextFor(pendingDays))? Changes will take effect within an hour or on next launch.")
                }
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

                    VStack(spacing: 8) {
                        ModernSlider(value: $videoQuality, range: 0...1, step: 0.05)

                        HStack {
                            Text("Smaller files")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                            Spacer()
                            Text("Higher quality")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                        }
                    }
                }
            }

            ModernSettingsCard(title: "Auto-Cleanup", icon: "trash") {
                // TODO: Add "Delete frames with no text" setting later
//                ModernToggleRow(
//                    title: "Delete frames with no text",
//                    subtitle: "Remove frames that contain no detectable text",
//                    isOn: .constant(false)
//                )

                ModernToggleRow(
                    title: "Delete duplicate frames",
                    subtitle: "Automatically remove similar consecutive frames",
                    isOn: $deleteDuplicateFrames
                )
                .onChange(of: deleteDuplicateFrames) { newValue in
                    updateDeduplicationSetting(enabled: newValue)
                }
            }
        }
    }

    // MARK: - Export & Data Settings

    private var exportDataSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            // TODO: Add export and data management options
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

            ModernSettingsCard(title: "Excluded Apps", icon: "app.badge.checkmark") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Apps that will not be recorded")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)

                    if excludedApps.isEmpty {
                        Text("No apps excluded")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.6))
                            .padding(.vertical, 4)
                    } else {
                        // Wrap excluded apps in a flow layout
                        FlowLayout(spacing: 8) {
                            ForEach(excludedApps) { app in
                                ExcludedAppChip(app: app) {
                                    removeExcludedApp(app)
                                }
                            }
                        }
                    }

                    ModernButton(title: "Add App", icon: "plus", style: .secondary) {
                        showAppPicker { appInfo in
                            if let app = appInfo {
                                addExcludedApp(app)
                            }
                        }
                    }
                }
            }

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

            ModernSettingsCard(title: "Logging", icon: "doc.text") {
                // TODO: Add Log Level picker later
//                VStack(alignment: .leading, spacing: 12) {
//                    Text("Log Level")
//                        .font(.retraceCalloutMedium)
//                        .foregroundColor(.retracePrimary)
//
//                    ModernSegmentedPicker(
//                        selection: .constant("info"),
//                        options: ["error", "warning", "info", "debug"]
//                    ) { option in
//                        Text(option.capitalized)
//                    }
//                }

                ModernButton(title: "Open Logs Folder", icon: "folder", style: .secondary) {
                    openLogsFolder()
                }
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

                ModernButton(title: "Export Database Schema", icon: "square.and.arrow.up", style: .secondary) {
                    exportDatabaseSchema()
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
            .alert("Create New Retrace Database?", isPresented: $showRetraceDBWarning) {
                Button("Cancel", role: .cancel) {
                    pendingRetraceDBPath = nil
                }
                Button("Continue", role: .none) {
                    confirmRetraceDBLocation()
                }
            } message: {
                Text("No existing Retrace database found at this location. A new database will be created here when you restart the app. Your current recordings will remain in the old location.")
            }
            .alert("Missing Chunks Folder?", isPresented: $showRewindDBWarning) {
                Button("Cancel", role: .cancel) {
                    pendingRewindDBPath = nil
                }
                Button("Continue Anyway", role: .none) {
                    confirmRewindDBLocation()
                }
            } message: {
                Text("The selected Rewind database exists, but the 'chunks' folder (video storage) was not found in the same directory. Retrace may not be able to load video frames from this database.")
            }
        }
    }
}

// MARK: - Modern Components

private struct ModernSettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var dangerous: Bool = false
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
                Button(action: { selection = style }) {
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
                Button(action: { selectedInterval = interval }) {
                    Text(intervalLabel(interval))
                        .font(selectedInterval == interval ? .retraceCaption2Bold : .retraceCaption2Medium)
                        .foregroundColor(selectedInterval == interval ? .retracePrimary : .retraceSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedInterval == interval ? Color.white.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
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

// MARK: - Retention Policy Picker (Sliding Scale)

private struct RetentionPolicyPicker: View {
    var currentDays: Int
    var onSelectionChange: (Int) -> Void

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
        Double(options.firstIndex(where: { $0.days == currentDays }) ?? (options.count - 1))
    }

    @GestureState private var isDragging = false

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
                        .updating($isDragging) { _, state, _ in
                            state = true
                        }
                        .onChanged { value in
                            let x = value.location.x
                            // Adjust for inset
                            let adjustedX = x - horizontalInset
                            let index = Int(round(adjustedX / segmentWidth))
                            let clampedIndex = max(0, min(options.count - 1, index))
                            if options[clampedIndex].days != currentDays {
                                onSelectionChange(options[clampedIndex].days)
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

extension SettingsView {
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

    // MARK: - Advanced Settings Actions

    func openLogsFolder() {
        // macOS system logs are in ~/Library/Logs - open Console.app filtered to our app
        // Or open our app's container folder
        let logsPath = NSString(string: "~/Library/Logs").expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsPath)
    }

    func exportDatabaseSchema() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "retrace_schema.json"
        panel.title = "Export Database Schema"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            // Export a simple schema description
            let schema: [String: Any] = [
                "version": "1.0",
                "tables": [
                    "frames": ["id", "segment_id", "frame_index", "timestamp", "ocr_text", "app_name", "window_title"],
                    "segments": ["id", "start_time", "end_time", "frame_count", "file_path", "width", "height"],
                    "frames_fts": ["Full-text search virtual table for OCR text"]
                ],
                "exported_at": ISO8601DateFormatter().string(from: Date())
            ]

            if let data = try? JSONSerialization.data(withJSONObject: schema, options: .prettyPrinted) {
                try? data.write(to: url)
            }
        }
    }

    func restartApp() {
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]
        task.launch()
        NSApp.terminate(nil)
    }

    func restartAndResumeRecording() {
        // Set flag in UserDefaults to auto-start recording on next launch
        let defaults = UserDefaults(suiteName: "Retrace") ?? .standard
        defaults.set(true, forKey: "shouldAutoStartRecording")
        defaults.synchronize()
        Log.info("Set shouldAutoStartRecording flag for restart", category: .ui)

        // Restart the app
        restartApp()
    }

    func selectRetraceDBLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a location for the Retrace database"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            let selectedPath = url.path
            let dbPath = "\(selectedPath)/retrace.db"

            // Check if database already exists at this location
            if FileManager.default.fileExists(atPath: dbPath) {
                // Database exists, use it directly
                customRetraceDBLocation = selectedPath
                retraceDBLocationChanged = true
                Log.info("Retrace database location changed to existing database: \(selectedPath)", category: .ui)
            } else {
                // No database exists, show warning
                pendingRetraceDBPath = selectedPath
                showRetraceDBWarning = true
            }
        }
    }

    func confirmRetraceDBLocation() {
        guard let path = pendingRetraceDBPath else { return }
        customRetraceDBLocation = path
        retraceDBLocationChanged = true
        showRetraceDBWarning = false
        pendingRetraceDBPath = nil
        Log.info("Retrace database location changed to new location: \(path)", category: .ui)
    }

    func selectRewindDBLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.database, .data]
        panel.message = "Choose the Rewind database file (db-enc.sqlite3)"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            let selectedPath = url.path

            // Check if the selected file exists and has proper structure
            if FileManager.default.fileExists(atPath: selectedPath) {
                let parentDir = (selectedPath as NSString).deletingLastPathComponent
                let chunksPath = "\(parentDir)/chunks"

                // Check if chunks directory exists
                if FileManager.default.fileExists(atPath: chunksPath) {
                    // Valid Rewind database structure - apply immediately
                    applyRewindDBLocation(selectedPath)
                } else {
                    // Database exists but no chunks folder
                    pendingRewindDBPath = selectedPath
                    showRewindDBWarning = true
                }
            } else {
                // File doesn't exist
                Log.warning("Selected Rewind database file does not exist: \(selectedPath)", category: .ui)
            }
        }
    }

    func confirmRewindDBLocation() {
        guard let path = pendingRewindDBPath else { return }
        showRewindDBWarning = false
        pendingRewindDBPath = nil
        applyRewindDBLocation(path)
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
        let hadCustomRetrace = customRetraceDBLocation != nil
        let hadCustomRewind = customRewindDBLocation != nil

        customRetraceDBLocation = nil
        customRewindDBLocation = nil
        retraceDBLocationChanged = hadCustomRetrace
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
        settingsStore?.removePersistentDomain(forName: domain)
        settingsStore?.synchronize()

        // Reset local @AppStorage values to defaults
        captureIntervalSeconds = 2.0
        videoQuality = 0.5
        retentionDays = 0
        maxStorageGB = 50.0
        deleteDuplicateFrames = true
        launchAtLogin = false
        showMenuBarIcon = true
        excludePrivateWindows = true
        showFrameIDs = false
        enableFrameIDSearch = false
    }

    func deleteAllData() {
        Task {
            // Stop capture pipeline first
            try? await coordinatorWrapper.stopPipeline()

            // Delete the entire storage directory
            let storagePath = NSString(string: "~/Library/Application Support/Retrace").expandingTildeInPath
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
}

// MARK: - Supporting Types

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case capture = "Capture"
    case storage = "Storage"
    case exportData = "Export & Data"
    case privacy = "Privacy"
    // case search = "Search"  // TODO: Add Search settings later
    case advanced = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "video"
        case .storage: return "externaldrive"
        case .exportData: return "square.and.arrow.up"
        case .privacy: return "lock.shield"
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
        // case .search: return .retraceAccentGradient
        case .advanced: return .retracePurpleGradient
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
    /// Add an app to the exclusion list
    func addExcludedApp(_ app: ExcludedAppInfo) {
        guard !excludedAppsString.isEmpty else {
            // First app
            if let data = try? JSONEncoder().encode([app]),
               let string = String(data: data, encoding: .utf8) {
                excludedAppsString = string
            }
            return
        }

        // Parse existing apps
        guard let data = excludedAppsString.data(using: .utf8),
              var apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) else {
            return
        }

        // Don't add duplicates
        guard !apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        apps.append(app)

        // Save back
        if let newData = try? JSONEncoder().encode(apps),
           let string = String(data: newData, encoding: .utf8) {
            excludedAppsString = string
        }
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
    }

    /// Show the app picker panel
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
                deduplicationThreshold: currentConfig.deduplicationThreshold,
                maxResolution: currentConfig.maxResolution,
                excludedAppBundleIDs: currentConfig.excludedAppBundleIDs,
                excludePrivateWindows: currentConfig.excludePrivateWindows,
                customPrivateWindowPatterns: currentConfig.customPrivateWindowPatterns,
                showCursor: currentConfig.showCursor
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
}

// MARK: - Settings Shortcut Key Model

struct SettingsShortcutKey: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

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
    let otherShortcut: SettingsShortcutKey
    let onDuplicateAttempt: () -> Void
    let onShortcutCaptured: () -> Void

    func makeNSView(context: Context) -> SettingsShortcutCaptureNSView {
        let view = SettingsShortcutCaptureNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SettingsShortcutCaptureNSView, context: Context) {
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

            // Require at least one modifier key
            if modifiers.isEmpty {
                return
            }

            let newShortcut = SettingsShortcutKey(key: keyName, modifiers: modifiers)

            // Check for duplicate
            if newShortcut == parent.otherShortcut {
                parent.onDuplicateAttempt()
                parent.isRecording = false
                return
            }

            parent.capturedShortcut = newShortcut
            parent.isRecording = false
            parent.onShortcutCaptured()
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
