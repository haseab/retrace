import SwiftUI
import Shared
import AppKit

/// Main settings view with sidebar navigation
/// Activated with Cmd+,
public struct SettingsView: View {

    // MARK: - Properties

    @State private var selectedTab: SettingsTab = .general
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("theme") private var theme: ThemePreference = .auto

    // Capture settings
    @AppStorage("captureRate") private var captureRate: Double = 0.5
    @AppStorage("captureResolution") private var captureResolution: CaptureResolution = .original
    @AppStorage("captureActiveDisplayOnly") private var captureActiveDisplayOnly = false
    @AppStorage("excludeCursor") private var excludeCursor = false

    // Storage settings
    @AppStorage("retentionDays") private var retentionDays: Int = 0 // 0 = forever
    @AppStorage("maxStorageGB") private var maxStorageGB: Double = 50.0
    @AppStorage("compressionQuality") private var compressionQuality: CompressionQuality = .high

    // Privacy settings
    @AppStorage("excludedApps") private var excludedAppsString = ""
    @AppStorage("excludePrivateWindows") private var excludePrivateWindows = true
    @AppStorage("excludeSafariPrivate") private var excludeSafariPrivate = true
    @AppStorage("excludeChromeIncognito") private var excludeChromeIncognito = true
    @AppStorage("encryptionEnabled") private var encryptionEnabled = true

    // MARK: - Body

    public var body: some View {
        HSplitView {
            // Sidebar
            sidebar
                .frame(minWidth: .sidebarWidth, maxWidth: .sidebarWidth)

            // Content
            content
                .frame(minWidth: 500, maxWidth: .infinity)
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color.retraceBackground)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back to Dashboard button
            Button(action: {
                NotificationCenter.default.post(name: .openDashboard, object: nil)
            }) {
                HStack(spacing: .spacingS) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))

                    Text("Dashboard")
                        .font(.retraceBody)
                }
                .foregroundColor(.retraceSecondary)
                .padding(.horizontal, .spacingM)
                .padding(.vertical, .spacingS)
            }
            .buttonStyle(.plain)
            .padding(.bottom, .spacingM)

            Divider()
                .padding(.horizontal, .spacingM)
                .padding(.bottom, .spacingM)

            ForEach(SettingsTab.allCases) { tab in
                sidebarButton(tab: tab)
            }

            Spacer()
        }
        .padding(.vertical, .spacingM)
        .background(Color.retraceSecondaryBackground)
    }

    private func sidebarButton(tab: SettingsTab) -> some View {
        Button(action: { selectedTab = tab }) {
            HStack(spacing: .spacingM) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16))
                    .frame(width: 20)

                Text(tab.rawValue)
                    .font(.retraceBody)

                Spacer()
            }
            .foregroundColor(selectedTab == tab ? .retracePrimary : .retraceSecondary)
            .padding(.horizontal, .spacingM)
            .padding(.vertical, .spacingS)
            .background(selectedTab == tab ? Color.retraceHover : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .spacingL) {
                switch selectedTab {
                case .general:
                    generalSettings
                case .capture:
                    captureSettings
                case .storage:
                    storageSettings
                case .privacy:
                    privacySettings
                case .search:
                    searchSettings
                case .advanced:
                    advancedSettings
                }
            }
            .padding(.spacingL)
        }
    }

    // MARK: - General Settings

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            settingsHeader(title: "General Settings")

            settingsGroup(title: "Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }
                Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { newValue in
                        setMenuBarIconVisibility(visible: newValue)
                    }
            }

            settingsGroup(title: "Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(ThemePreference.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: theme) { newValue in
                    applyTheme(newValue)
                }
            }

            settingsGroup(title: "Keyboard Shortcuts") {
                shortcutRow(label: "Open Timeline", shortcut: "⌘⇧T")
                shortcutRow(label: "Open Search", shortcut: "⌘F")
                shortcutRow(label: "Settings", shortcut: "⌘,")
            }
        }
    }

    // MARK: - Capture Settings

    private var captureSettings: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            settingsHeader(title: "Capture Settings")

            settingsGroup(title: "Capture Rate") {
                VStack(alignment: .leading, spacing: .spacingS) {
                    HStack {
                        Text("Frames per second:")
                        Spacer()
                        Text(String(format: "%.1f FPS", captureRate))
                            .foregroundColor(.retraceSecondary)
                    }

                    Slider(value: $captureRate, in: 0.5...2.0, step: 0.5)
                }
            }

            settingsGroup(title: "Resolution") {
                Picker("Capture Resolution", selection: $captureResolution) {
                    ForEach(CaptureResolution.allCases) { res in
                        Text(res.rawValue).tag(res)
                    }
                }
                .pickerStyle(.segmented)
            }

            settingsGroup(title: "Display Options") {
                Toggle("Active Display Only", isOn: $captureActiveDisplayOnly)
                Toggle("Exclude Cursor", isOn: $excludeCursor)
            }

            settingsGroup(title: "Pause When") {
                Toggle("Screen is locked", isOn: .constant(true))
                Toggle("On battery (< 20%)", isOn: .constant(false))
                Toggle("Idle for 10 minutes", isOn: .constant(false))
            }
        }
    }

    // MARK: - Storage Settings

    private var storageSettings: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            settingsHeader(title: "Storage Settings")

            settingsGroup(title: "Retention Policy") {
                VStack(alignment: .leading, spacing: .spacingS) {
                    Picker("Keep recordings for", selection: $retentionDays) {
                        Text("Forever").tag(0)
                        Text("Last 30 days").tag(30)
                        Text("Last 90 days").tag(90)
                        Text("Last 180 days").tag(180)
                        Text("Last year").tag(365)
                    }
                }
            }

            settingsGroup(title: "Storage Limit") {
                VStack(alignment: .leading, spacing: .spacingS) {
                    HStack {
                        Text("Maximum storage:")
                        Spacer()
                        Text(String(format: "%.0f GB", maxStorageGB))
                            .foregroundColor(.retraceSecondary)
                    }

                    Slider(value: $maxStorageGB, in: 10...500, step: 10)
                }
            }

            settingsGroup(title: "Compression") {
                Picker("Quality", selection: $compressionQuality) {
                    ForEach(CompressionQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
            }

            settingsGroup(title: "Auto-Cleanup") {
                Toggle("Delete frames with no text", isOn: .constant(false))
                Toggle("Delete duplicate frames", isOn: .constant(true))
            }
        }
    }

    // MARK: - Privacy Settings

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            settingsHeader(title: "Privacy Settings")

            settingsGroup(title: "Database Encryption") {
                Toggle("Encrypt database", isOn: $encryptionEnabled)
                    .help("Encrypts the SQLite database using SQLCipher (AES-256). Note: Video files are not encrypted.")

                if encryptionEnabled {
                    HStack(spacing: .spacingS) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.retraceSuccess)
                            .font(.system(size: 14))

                        Text("Database is encrypted with SQLCipher (AES-256)")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                    }
                    .padding(.spacingS)
                    .background(Color.retraceSuccess.opacity(0.1))
                    .cornerRadius(.cornerRadiusS)
                }
            }

            settingsGroup(title: "Excluded Apps") {
                Text("Apps that will not be recorded")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)

                // TODO: Implement app picker
                Text("1Password, Bitwarden, Keychain Access")
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)
                    .padding(.spacingS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.retraceCard)
                    .cornerRadius(.cornerRadiusS)

                Button("Add App...") {
                    // TODO: Show app picker
                }
                .buttonStyle(RetraceSecondaryButtonStyle())
            }

            settingsGroup(title: "Excluded Windows") {
                Toggle("Exclude Private/Incognito Windows", isOn: $excludePrivateWindows)
                    .help("Automatically exclude private browsing windows from all browsers")

                if excludePrivateWindows {
                    VStack(alignment: .leading, spacing: .spacingS) {
                        Toggle("Safari Private Browsing", isOn: $excludeSafariPrivate)
                            .disabled(true) // Always on when excludePrivateWindows is enabled
                        Toggle("Chrome/Edge Incognito", isOn: $excludeChromeIncognito)
                            .disabled(true) // Always on when excludePrivateWindows is enabled

                        Text("Detects: Safari (Private), Chrome (Incognito), Edge (InPrivate), Firefox (Private Browsing), Brave (Private Window)")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                            .padding(.leading, 24)
                    }
                }
            }

            settingsGroup(title: "Quick Delete") {
                HStack(spacing: .spacingM) {
                    Button("Delete Last 5 Minutes") {}
                        .buttonStyle(RetraceDangerButtonStyle())

                    Button("Delete Last Hour") {}
                        .buttonStyle(RetraceDangerButtonStyle())

                    Button("Delete Last Day") {}
                        .buttonStyle(RetraceDangerButtonStyle())
                }
            }

            settingsGroup(title: "Permissions") {
                permissionRow(
                    label: "Screen Recording",
                    status: .granted,
                    action: "Open System Settings"
                )

                permissionRow(
                    label: "Accessibility",
                    status: .granted,
                    action: "Open System Settings"
                )
            }
        }
    }

    // MARK: - Search Settings

    private var searchSettings: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            settingsHeader(title: "Search Settings")

            settingsGroup(title: "Search Behavior") {
                Toggle("Show suggestions as you type", isOn: .constant(true))
                Toggle("Include audio transcriptions", isOn: .constant(false))
                    .disabled(true)
                    .help("Coming soon")
            }

            settingsGroup(title: "Results") {
                VStack(alignment: .leading, spacing: .spacingS) {
                    HStack {
                        Text("Default result limit:")
                        Spacer()
                        Text("50")
                            .foregroundColor(.retraceSecondary)
                    }

                    Slider(value: .constant(50), in: 10...200, step: 10)
                }
            }

            settingsGroup(title: "Ranking") {
                HStack {
                    Text("Relevance")
                    Slider(value: .constant(0.7), in: 0...1)
                    Text("Recency")
                }
            }
        }
    }

    // MARK: - Advanced Settings

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            settingsHeader(title: "Advanced Settings")

            settingsGroup(title: "Database") {
                Button("Vacuum Database") {}
                    .buttonStyle(RetraceSecondaryButtonStyle())

                Button("Rebuild FTS Index") {}
                    .buttonStyle(RetraceSecondaryButtonStyle())
            }

            settingsGroup(title: "Encoding") {
                Toggle("Hardware Acceleration (VideoToolbox)", isOn: .constant(true))

                Picker("Encoder Preset", selection: .constant("balanced")) {
                    Text("Fast").tag("fast")
                    Text("Balanced").tag("balanced")
                    Text("Quality").tag("quality")
                }
            }

            settingsGroup(title: "Logging") {
                Picker("Log Level", selection: .constant("info")) {
                    Text("Error").tag("error")
                    Text("Warning").tag("warning")
                    Text("Info").tag("info")
                    Text("Debug").tag("debug")
                }

                Button("Open Logs Folder") {}
                    .buttonStyle(RetraceSecondaryButtonStyle())
            }

            settingsGroup(title: "Developer") {
                Toggle("Show frame IDs in UI", isOn: .constant(false))

                Button("Export Database Schema") {}
                    .buttonStyle(RetraceSecondaryButtonStyle())
            }

            settingsGroup(title: "Danger Zone") {
                Button("Reset All Settings") {}
                    .buttonStyle(RetraceDangerButtonStyle())

                Button("Delete All Data") {}
                    .buttonStyle(RetraceDangerButtonStyle())
            }
        }
    }

    // MARK: - Helper Views

    private func settingsHeader(title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.retraceTitle2)
                .foregroundColor(.retracePrimary)

            Divider()
        }
    }

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: .spacingM) {
            Text(title)
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            VStack(alignment: .leading, spacing: .spacingS) {
                content()
            }
        }
    }

    private func shortcutRow(label: String, shortcut: String) -> some View {
        HStack {
            Text(label)
                .font(.retraceBody)
                .foregroundColor(.retracePrimary)

            Spacer()

            Text(shortcut)
                .font(.retraceMono)
                .foregroundColor(.retraceSecondary)
                .padding(.horizontal, .spacingS)
                .padding(.vertical, 4)
                .background(Color.retraceCard)
                .cornerRadius(.cornerRadiusS)
        }
    }

    private func permissionRow(label: String, status: PermissionStatus, action: String) -> some View {
        HStack {
            Text(label)
                .font(.retraceBody)
                .foregroundColor(.retracePrimary)

            Spacer()

            HStack(spacing: .spacingS) {
                Image(systemName: status == .granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(status == .granted ? .retraceSuccess : .retraceDanger)

                Text(status.rawValue)
                    .font(.retraceBody)
                    .foregroundColor(status == .granted ? .retraceSuccess : .retraceDanger)

                if status != .granted {
                    Button(action) {}
                        .buttonStyle(RetraceSecondaryButtonStyle())
                }
            }
        }
    }
}

// MARK: - Supporting Types

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case capture = "Capture"
    case storage = "Storage"
    case privacy = "Privacy"
    case search = "Search"
    case advanced = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "video"
        case .storage: return "internaldrive"
        case .privacy: return "lock.shield"
        case .search: return "magnifyingglass"
        case .advanced: return "wrench.and.screwdriver"
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
    case uhd4k = "4K (2160p)"
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

// MARK: - Launch at Login Helper

import ServiceManagement

extension SettingsView {
    /// Enable or disable launch at login using SMAppService (macOS 13+)
    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    // Already enabled
                    return
                }
                try SMAppService.mainApp.register()
            } else {
                guard case SMAppService.Status.enabled = SMAppService.mainApp.status else {
                    // Already disabled
                    return
                }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[ERROR] Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
        }
    }

    /// Show or hide the menu bar icon
    private func setMenuBarIconVisibility(visible: Bool) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let menuBarManager = appDelegate.menuBarManager {
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
            NSApp.appearance = nil // Use system setting
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
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
