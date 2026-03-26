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

extension SettingsView {
    var storageSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            rewindDataCard
            databaseLocationsCard
            retentionPolicyCard
        }
    }

    // MARK: - Storage Cards (extracted for search)

    @ViewBuilder
    var rewindDataCard: some View {
        ModernSettingsCard(title: "Rewind Data", icon: "arrow.counterclockwise") {
            VStack(alignment: .leading, spacing: 16) {
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

                Divider()
                    .background(Color.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rewind cutoff date")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retracePrimary)
                            Text("Only Rewind frames before this date and time are shown. Default is \(defaultRewindCutoffDateDescription).")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.8))
                        }

                        Spacer()

                        DatePicker(
                            "",
                            selection: Binding(
                                get: { rewindCutoffDateSelection },
                                set: { newValue in
                                    applyRewindCutoffDate(newValue)
                                }
                            ),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .disabled(isRefreshingRewindCutoff)
                    }

                    if hasCustomRewindCutoffDate {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.retraceWarning)
                                .padding(.top, 1)

                            Text(customRewindCutoffWarningText)
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.retraceWarning.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.retraceWarning.opacity(0.25), lineWidth: 1)
                                )
                        )
                    }

                    HStack {
                        if hasCustomRewindCutoffDate {
                            Button(action: {
                                applyRewindCutoffDate(SettingsDefaults.rewindCutoffDate)
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
                            .disabled(isRefreshingRewindCutoff)
                        }

                        if isRefreshingRewindCutoff {
                            ProgressView()
                                .controlSize(.small)
                            Text("Updating...")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                        }

                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    var databaseLocationsCard: some View {
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

                    // Rewind Database Folder (only shown when Use Rewind data is enabled)
                    if useRewindData {
                        Divider()
                            .background(Color.white.opacity(0.1))

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("Rewind Database Folder")
                                            .font(.retraceCalloutMedium)
                                            .foregroundColor(.retracePrimary)
                                        PingDotView(
                                            color: rewindDBAccessible ? .green : .orange,
                                            size: 8,
                                            isAnimating: rewindDBAccessible
                                        )
                                    }
                                    HStack(spacing: 4) {
                                        Text(rewindFolderPath)
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
                                Button("Choose Folder...") {
                                    selectRewindDBLocation()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .help("Select the folder containing Rewind's db-enc.sqlite3 file")
                            }
                            Text("Select the folder containing db-enc.sqlite3 (chunks folder should be in the same directory)")
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
    }

    @ViewBuilder
    var retentionPolicyCard: some View {
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
    }

    // MARK: - Export & Data Settings
}
