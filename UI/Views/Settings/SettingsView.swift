import SwiftUI
import Shared
import AppKit

/// Main settings view with sidebar navigation
/// Activated with Cmd+,
public struct SettingsView: View {

    // MARK: - Properties

    @State private var selectedTab: SettingsTab = .general
    @State private var hoveredTab: SettingsTab? = nil
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

    // Developer settings
    @AppStorage("showFrameIDs") private var showFrameIDs = false

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
                Color.retraceBackground

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

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with back button
            Button(action: {
                NotificationCenter.default.post(name: .openDashboard, object: nil)
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.retraceSecondary)

                    Text("Settings")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.retracePrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .buttonStyle(.plain)

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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.retraceSecondary)
                Text("v0.1.0")
                    .font(.system(size: 11, weight: .medium))
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? tab.gradient : LinearGradient(colors: [.retraceSecondary], startPoint: .top, endPoint: .bottom))
                }
                .frame(width: 32, height: 32)

                Text(tab.rawValue)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
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
                    case .privacy:
                        privacySettings
                    case .search:
                        searchSettings
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
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selectedTab.gradient)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTab.rawValue)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.retracePrimary)

                    Text(selectedTab.description)
                        .font(.system(size: 13, weight: .medium))
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Theme")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.retracePrimary)

                    ModernSegmentedPicker(
                        selection: $theme,
                        options: ThemePreference.allCases
                    ) { option in
                        Text(option.rawValue)
                    }
                    .onChange(of: theme) { newValue in
                        applyTheme(newValue)
                    }
                }
            }

            ModernSettingsCard(title: "Keyboard Shortcuts", icon: "command") {
                VStack(spacing: 12) {
                    ModernShortcutRow(label: "Open Timeline", shortcut: "⌘⇧T")
                    ModernShortcutRow(label: "Open Search", shortcut: "⌘F")
                    ModernShortcutRow(label: "Settings", shortcut: "⌘,")
                }
            }
        }
    }

    // MARK: - Capture Settings

    private var captureSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModernSettingsCard(title: "Capture Rate", icon: "gauge.with.dots.needle.50percent") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Frames per second")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        Text(String(format: "%.1f FPS", captureRate))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.retraceAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.retraceAccent.opacity(0.1))
                            .cornerRadius(8)
                    }

                    ModernSlider(value: $captureRate, range: 0.5...2.0, step: 0.5)
                }
            }

            ModernSettingsCard(title: "Resolution", icon: "aspectratio") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Capture Resolution")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.retracePrimary)

                    ModernSegmentedPicker(
                        selection: $captureResolution,
                        options: CaptureResolution.allCases
                    ) { option in
                        Text(option.rawValue)
                    }
                }
            }

            ModernSettingsCard(title: "Display Options", icon: "display") {
                ModernToggleRow(
                    title: "Active Display Only",
                    subtitle: "Only capture the currently active display",
                    isOn: $captureActiveDisplayOnly
                )

                ModernToggleRow(
                    title: "Exclude Cursor",
                    subtitle: "Hide the mouse cursor in captures",
                    isOn: $excludeCursor
                )
            }

            ModernSettingsCard(title: "Auto-Pause", icon: "pause.circle") {
                ModernToggleRow(
                    title: "Screen is locked",
                    subtitle: "Pause recording when your Mac is locked",
                    isOn: .constant(true)
                )

                ModernToggleRow(
                    title: "On battery (< 20%)",
                    subtitle: "Pause when battery is critically low",
                    isOn: .constant(false)
                )

                ModernToggleRow(
                    title: "Idle for 10 minutes",
                    subtitle: "Pause after extended inactivity",
                    isOn: .constant(false)
                )
            }
        }
    }

    // MARK: - Storage Settings

    private var storageSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModernSettingsCard(title: "Retention Policy", icon: "calendar.badge.clock") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keep recordings for")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.retracePrimary)

                    ModernDropdown(selection: $retentionDays, options: [
                        (0, "Forever"),
                        (30, "Last 30 days"),
                        (90, "Last 90 days"),
                        (180, "Last 180 days"),
                        (365, "Last year")
                    ])
                }
            }

            ModernSettingsCard(title: "Storage Limit", icon: "externaldrive") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Maximum storage")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        Text(String(format: "%.0f GB", maxStorageGB))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.retraceAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.retraceAccent.opacity(0.1))
                            .cornerRadius(8)
                    }

                    ModernSlider(value: $maxStorageGB, range: 10...500, step: 10)
                }
            }

            ModernSettingsCard(title: "Compression", icon: "archivebox") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quality")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.retracePrimary)

                    ModernSegmentedPicker(
                        selection: $compressionQuality,
                        options: CompressionQuality.allCases
                    ) { option in
                        Text(option.rawValue)
                    }
                }
            }

            ModernSettingsCard(title: "Auto-Cleanup", icon: "trash") {
                ModernToggleRow(
                    title: "Delete frames with no text",
                    subtitle: "Remove frames that contain no detectable text",
                    isOn: .constant(false)
                )

                ModernToggleRow(
                    title: "Delete duplicate frames",
                    subtitle: "Automatically remove similar consecutive frames",
                    isOn: .constant(true)
                )
            }
        }
    }

    // MARK: - Privacy Settings

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModernSettingsCard(title: "Database Encryption", icon: "lock.shield") {
                ModernToggleRow(
                    title: "Encrypt database",
                    subtitle: "Secure your data with AES-256 encryption",
                    isOn: $encryptionEnabled
                )

                if encryptionEnabled {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.retraceSuccess)
                            .font(.system(size: 14))

                        Text("Database encrypted with SQLCipher (AES-256)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.retraceSuccess)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.retraceSuccess.opacity(0.1))
                    .cornerRadius(10)
                }
            }

            ModernSettingsCard(title: "Excluded Apps", icon: "app.badge.checkmark") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Apps that will not be recorded")
                        .font(.system(size: 13))
                        .foregroundColor(.retraceSecondary)

                    HStack(spacing: 8) {
                        ForEach(["1Password", "Bitwarden", "Keychain"], id: \.self) { app in
                            Text(app)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.retracePrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(6)
                        }
                    }

                    ModernButton(title: "Add App", icon: "plus", style: .secondary) {
                        // TODO: Show app picker
                    }
                }
            }

            ModernSettingsCard(title: "Excluded Windows", icon: "eye.slash") {
                ModernToggleRow(
                    title: "Exclude Private/Incognito Windows",
                    subtitle: "Automatically skip private browsing windows",
                    isOn: $excludePrivateWindows
                )

                if excludePrivateWindows {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detects private windows from:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.retraceSecondary)

                        Text("Safari, Chrome, Edge, Firefox, Brave")
                            .font(.system(size: 12))
                            .foregroundColor(.retraceSecondary.opacity(0.8))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(10)
                }
            }

            ModernSettingsCard(title: "Quick Delete", icon: "clock.arrow.circlepath") {
                HStack(spacing: 12) {
                    ModernButton(title: "Last 5 min", icon: nil, style: .danger) {}
                    ModernButton(title: "Last hour", icon: nil, style: .danger) {}
                    ModernButton(title: "Last day", icon: nil, style: .danger) {}
                }
            }

            ModernSettingsCard(title: "Permissions", icon: "hand.raised") {
                ModernPermissionRow(
                    label: "Screen Recording",
                    status: .granted
                )

                ModernPermissionRow(
                    label: "Accessibility",
                    status: .granted
                )
            }
        }
    }

    // MARK: - Search Settings

    private var searchSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModernSettingsCard(title: "Search Behavior", icon: "magnifyingglass") {
                ModernToggleRow(
                    title: "Show suggestions as you type",
                    subtitle: "Display search suggestions in real-time",
                    isOn: .constant(true)
                )

                ModernToggleRow(
                    title: "Include audio transcriptions",
                    subtitle: "Search through transcribed audio content",
                    isOn: .constant(false),
                    disabled: true,
                    badge: "Coming Soon"
                )
            }

            ModernSettingsCard(title: "Results", icon: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Default result limit")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        Text("50")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.retraceAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.retraceAccent.opacity(0.1))
                            .cornerRadius(8)
                    }

                    ModernSlider(value: .constant(50), range: 10...200, step: 10)
                }
            }

            ModernSettingsCard(title: "Ranking", icon: "chart.bar") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Relevance")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.retraceSecondary)
                        Spacer()
                        Text("Recency")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.retraceSecondary)
                    }

                    ModernSlider(value: .constant(0.7), range: 0...1, step: 0.1)
                }
            }
        }
    }

    // MARK: - Advanced Settings

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModernSettingsCard(title: "Database", icon: "cylinder") {
                HStack(spacing: 12) {
                    ModernButton(title: "Vacuum Database", icon: "arrow.triangle.2.circlepath", style: .secondary) {}
                    ModernButton(title: "Rebuild FTS Index", icon: "magnifyingglass", style: .secondary) {}
                }
            }

            ModernSettingsCard(title: "Encoding", icon: "cpu") {
                ModernToggleRow(
                    title: "Hardware Acceleration",
                    subtitle: "Use VideoToolbox for faster encoding",
                    isOn: .constant(true)
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Encoder Preset")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.retracePrimary)

                    ModernSegmentedPicker(
                        selection: .constant("balanced"),
                        options: ["fast", "balanced", "quality"]
                    ) { option in
                        Text(option.capitalized)
                    }
                }
            }

            ModernSettingsCard(title: "Logging", icon: "doc.text") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Log Level")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.retracePrimary)

                    ModernSegmentedPicker(
                        selection: .constant("info"),
                        options: ["error", "warning", "info", "debug"]
                    ) { option in
                        Text(option.capitalized)
                    }
                }

                ModernButton(title: "Open Logs Folder", icon: "folder", style: .secondary) {}
            }

            ModernSettingsCard(title: "Developer", icon: "hammer") {
                ModernToggleRow(
                    title: "Show frame IDs in UI",
                    subtitle: "Display frame IDs in the timeline for debugging",
                    isOn: $showFrameIDs
                )

                ModernButton(title: "Export Database Schema", icon: "square.and.arrow.up", style: .secondary) {}
            }

            ModernSettingsCard(title: "Danger Zone", icon: "exclamationmark.triangle", dangerous: true) {
                HStack(spacing: 12) {
                    ModernButton(title: "Reset All Settings", icon: "arrow.counterclockwise", style: .danger) {}
                    ModernButton(title: "Delete All Data", icon: "trash", style: .danger) {}
                }
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(dangerous ? .retraceDanger : .retraceSecondary)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(disabled ? .retraceSecondary : .retracePrimary)

                    if let badge = badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.retraceAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.retraceAccent.opacity(0.15))
                            .cornerRadius(4)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 12))
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
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.retracePrimary)

            Spacer()

            Text(shortcut)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
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

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.retracePrimary)

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(status == .granted ? Color.retraceSuccess : Color.retraceDanger)
                    .frame(width: 8, height: 8)

                Text(status.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(status == .granted ? .retraceSuccess : .retraceDanger)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background((status == .granted ? Color.retraceSuccess : Color.retraceDanger).opacity(0.1))
            .cornerRadius(8)
        }
        .padding(.vertical, 4)
    }
}

private struct ModernSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 6)

                // Track fill
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient.retraceAccentGradient)
                    .frame(width: geometry.size.width * progress, height: 6)
            }
        }
        .frame(height: 6)
        .overlay(
            Slider(value: $value, in: range, step: step)
                .accentColor(.clear)
                .opacity(0.01)
        )
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
                        .font(.system(size: 13, weight: selection == option ? .semibold : .medium))
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.retracePrimary)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 13, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
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
        case .storage: return "externaldrive"
        case .privacy: return "lock.shield"
        case .search: return "magnifyingglass"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    var description: String {
        switch self {
        case .general: return "Startup, appearance, and shortcuts"
        case .capture: return "Frame rate, resolution, and display options"
        case .storage: return "Retention, limits, and compression"
        case .privacy: return "Encryption, exclusions, and permissions"
        case .search: return "Search behavior and ranking"
        case .advanced: return "Database, encoding, and developer tools"
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .general: return .retraceAccentGradient
        case .capture: return .retracePurpleGradient
        case .storage: return .retraceOrangeGradient
        case .privacy: return .retraceGreenGradient
        case .search: return .retraceAccentGradient
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
            NSApp.appearance = nil
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
