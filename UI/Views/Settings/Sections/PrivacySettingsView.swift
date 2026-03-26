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

struct QuickDeleteButton: View {
    let title: String
    let option: QuickDeleteOption
    let isDeleting: Bool
    let currentOption: QuickDeleteOption?
    let action: () -> Void

    var isThisDeleting: Bool {
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

extension SettingsView {
    var privacySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            appLevelRedactionCard
                .zIndex(excludedAppsPopoverShown ? 50 : 0)
            windowLevelRedactionCard
            phraseLevelRedactionCard
            quickDeleteCard
            permissionsCard
        }
    }

    // MARK: - Privacy Cards

    @ViewBuilder
    var appLevelRedactionCard: some View {
        ModernSettingsCard(title: "App Level Redaction", icon: "app.badge.checkmark") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Exclude entire apps from capture.")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Excluded Apps")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retracePrimary)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 200), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ExcludedAppsAddButton(isOpen: excludedAppsPopoverShown) {
                            excludedAppsPopoverShown.toggle()
                        }

                        ForEach(excludedApps) { app in
                            ExcludedAppChip(app: app) {
                                removeExcludedApp(app)
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if excludedAppsPopoverShown {
                            ZStack(alignment: .topLeading) {
                                Color.black.opacity(0.001)
                                    .ignoresSafeArea()
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        excludedAppsPopoverShown = false
                                    }

                                AppsFilterPopover(
                                    apps: installedAppsForExcludedRedaction,
                                    otherApps: otherAppsForExcludedRedaction,
                                    selectedApps: Set(excludedApps.map(\.bundleID)),
                                    filterMode: .include,
                                    allowMultiSelect: true,
                                    showAllOption: false,
                                    onSelectApp: { bundleID in
                                        toggleExcludedRedactionApp(bundleID)
                                    },
                                    onFilterModeChange: nil,
                                    onDismiss: {
                                        excludedAppsPopoverShown = false
                                    }
                                )
                                .fixedSize(horizontal: false, vertical: true)
                                .offset(y: 42)
                                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
                            }
                            .zIndex(120)
                        }
                    }
                    .onExitCommand {
                        if excludedAppsPopoverShown {
                            excludedAppsPopoverShown = false
                        }
                    }
                    .zIndex(excludedAppsPopoverShown ? 80 : 0)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
            }
        }
        .task {
            loadExcludedAppsForRedaction()
        }
    }

    @ViewBuilder
    var quickDeleteCard: some View {
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
    }

    @ViewBuilder
    var windowLevelRedactionCard: some View {
        ModernSettingsCard(title: "Window Level Redaction", icon: "eye.slash") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Mask matching window regions in captured frames (case-insensitive substring).")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)

                VStack(alignment: .leading, spacing: 12) {
                    ModernToggleRow(
                        title: "Automatic Private / Incognito Mode Redaction",
                        subtitle: "Redact private/incognito windows automatically",
                        isOn: privateWindowRedactionBinding
                    )
                    if excludePrivateWindows {
                        Divider()
                            .background(Color.white.opacity(0.08))

                        privateModeAutomationSetupSection
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )

                Divider()
                    .background(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 12) {
                    ModernToggleRow(
                        title: "Redact on Browser URL or Window Name",
                        subtitle: "Use custom window-name and browser-URL pattern rules",
                        isOn: $enableCustomPatternWindowRedaction
                    )
                    .onChange(of: enableCustomPatternWindowRedaction) { _ in
                        updateRedactionRulesConfig()
                    }

                    if enableCustomPatternWindowRedaction {
                        Divider()
                            .background(Color.white.opacity(0.08))

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Custom window title patterns (one per line)")
                                .font(.retraceCaptionBold)
                                .foregroundColor(.retraceSecondary)
                            redactionRuleEditor(
                                text: $redactWindowTitlePatternsRaw,
                                placeholder: "Examples:\nWells Fargo Bank - Home\nPassword Manager\nGusto - Payroll"
                            )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Custom browser URL patterns (one per line)")
                                .font(.retraceCaptionBold)
                                .foregroundColor(.retraceSecondary)
                            redactionRuleEditor(
                                text: $redactBrowserURLPatternsRaw,
                                placeholder: "Examples:\nx.com/home\nbankofamerica.com\ninstagram.com/profile"
                            )
                        }

                        Text("Note: Firefox Browser URL Redaction will not work because it is not possible to read the URL")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.85))
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
            }
            .onChange(of: redactWindowTitlePatternsRaw) { _ in
                updateRedactionRulesConfig()
            }
            .onChange(of: redactBrowserURLPatternsRaw) { _ in
                updateRedactionRulesConfig()
            }
        }
        .task(id: excludePrivateWindows) {
            guard excludePrivateWindows else { return }
            await refreshPrivateModeAutomationTargets()
        }
    }

    @ViewBuilder
    var permissionsCard: some View {
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

            ModernPermissionRow(
                label: "Input Monitoring",
                status: hasListenEventAccess ? .granted : .notDetermined,
                enableAction: hasListenEventAccess ? nil : {
                    Task {
                        _ = await requestListenEventAccessIfNeeded()
                    }
                },
                openSettingsAction: { openListenEventSettings() }
            )

            ModernPermissionRow(
                label: "Browser URL Extraction Permissions",
                status: browserExtractionPermissionStatus,
                enableAction: { openAutomationSettings() },
                openSettingsAction: { openAutomationSettings() }
            )
        }
        .task {
            await checkPermissions()
        }
    }
}
