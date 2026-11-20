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
        ModernSettingsCard(title: "Rewind Data") {
            RewindSettingsLogoIcon()
        } content: {
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
                            Text("Only Rewind frames before this date are shown. We use the start of the selected day. Default is \(defaultRewindCutoffDateDescription).")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.8))
                        }

                        Spacer()

                        RewindCutoffCalendarTrigger(
                            selectedDate: rewindCutoffDateSelection,
                            isDisabled: isRefreshingRewindCutoff
                        ) { newValue in
                            applyRewindCutoffDate(newValue)
                        }
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
                                Text("Only applies to Retrace data, not Rewind data.")
                                    .foregroundColor(.retraceSecondary)
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

private struct RewindSettingsLogoIcon: View {
    var body: some View {
        RewindLogoIcon(color: .white)
            .frame(width: 18, height: 12)
    }
}

private struct RewindCutoffCalendarTrigger: View {
    let selectedDate: Date
    let isDisabled: Bool
    let onApply: (Date) -> Void

    @State private var isPresented = false
    @State private var draftSelection: Date
    @State private var displayedMonth: Date

    private let calendar = Calendar.current
    private let panelWidth: CGFloat = 296

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter
    }()

    init(
        selectedDate: Date,
        isDisabled: Bool,
        onApply: @escaping (Date) -> Void
    ) {
        self.selectedDate = selectedDate
        self.isDisabled = isDisabled
        self.onApply = onApply

        let calendar = Calendar.current
        let clampedSelection = min(selectedDate, Date())
        let monthAnchor =
            calendar.date(from: calendar.dateComponents([.year, .month], from: clampedSelection))
            ?? clampedSelection

        _draftSelection = State(initialValue: clampedSelection)
        _displayedMonth = State(initialValue: monthAnchor)
    }

    var body: some View {
        Button(action: openCalendar) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.retraceCalloutMedium)

                Text(selectedDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isDisabled ? Color.white.opacity(0.04) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isPresented ? RetraceMenuStyle.actionBlue.opacity(0.75) : Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            browserPanel
        }
        .onChange(of: selectedDate) { newValue in
            guard !isPresented else { return }
            let clampedSelection = clamp(newValue)
            draftSelection = clampedSelection
            displayedMonth = monthAnchor(for: clampedSelection)
        }
    }

    private var browserPanel: some View {
        VStack(spacing: 0) {
            calendarPane
            Divider()
                .background(Color.white.opacity(0.1))

            HStack {
                Button("Today") {
                    let today = clamp(Date())
                    draftSelection = today
                    displayedMonth = monthAnchor(for: today)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.82))

                Spacer()

                Button("Cancel") {
                    closeWithoutSaving()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.68))

                Button("Apply") {
                    commitSelection()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(RetraceMenuStyle.actionBlue)
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(white: 0.08))

                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), Color.white.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
        .frame(width: panelWidth)
        .padding(2)
    }

    private var calendarPane: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Choose Cutoff Date")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.top, 14)
            .padding(.bottom, 12)

            HStack {
                Button(action: { changeMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.retraceCaption2Bold)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text(monthYearString)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Button(action: { changeMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.retraceCaption2Bold)
                        .foregroundColor(.white.opacity(canAdvanceMonth ? 0.6 : 0.25))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(canAdvanceMonth ? 0.08 : 0.03))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canAdvanceMonth)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { day in
                    Text(day)
                        .font(.retraceTinyMedium)
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(daysInMonth(), id: \.self) { day in
                    dayCell(for: day)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 18)
        }
    }

    private var maximumSelectableDate: Date {
        calendar.startOfDay(for: Date())
    }

    private var monthYearString: String {
        Self.monthFormatter.string(from: displayedMonth)
    }

    private var weekdaySymbols: [String] {
        let symbols = Self.weekdayFormatter.shortStandaloneWeekdaySymbols
            ?? Self.weekdayFormatter.shortWeekdaySymbols
            ?? []
        guard !symbols.isEmpty else { return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] }

        let firstWeekdayIndex = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return (Array(symbols[firstWeekdayIndex...]) + Array(symbols[..<firstWeekdayIndex]))
            .map { String($0.prefix(3)) }
    }

    private var canAdvanceMonth: Bool {
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) else {
            return false
        }

        let maxMonth = monthAnchor(for: maximumSelectableDate)
        return nextMonth <= maxMonth
    }

    private func openCalendar() {
        let clampedSelection = clamp(selectedDate)
        draftSelection = clampedSelection
        displayedMonth = monthAnchor(for: clampedSelection)
        isPresented = true
    }

    private func closeWithoutSaving() {
        draftSelection = clamp(selectedDate)
        displayedMonth = monthAnchor(for: draftSelection)
        isPresented = false
    }

    private func commitSelection() {
        onApply(clamp(draftSelection))
        isPresented = false
    }

    private func clamp(_ date: Date) -> Date {
        min(calendar.startOfDay(for: date), maximumSelectableDate)
    }

    private func monthAnchor(for date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func changeMonth(by value: Int) {
        guard let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) else {
            return
        }

        if newMonth <= monthAnchor(for: maximumSelectableDate) {
            withAnimation(.easeInOut(duration: 0.2)) {
                displayedMonth = newMonth
            }
        }
    }

    private func daysInMonth() -> [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start) else {
            return []
        }

        var days: [Date?] = []
        var currentDate = firstWeek.start

        for _ in 0..<42 {
            days.append(currentDate)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }

        return days
    }

    @ViewBuilder
    private func dayCell(for day: Date?) -> some View {
        Group {
            if let day {
                let normalizedDay = calendar.startOfDay(for: day)
                let isToday = calendar.isDateInToday(normalizedDay)
                let isSelected = calendar.isDate(normalizedDay, inSameDayAs: draftSelection)
                let isCurrentMonth = calendar.isDate(normalizedDay, equalTo: displayedMonth, toGranularity: .month)
                let isFuture = normalizedDay > calendar.startOfDay(for: maximumSelectableDate)

                Button(action: {
                    selectDay(normalizedDay)
                }) {
                    Text("\(calendar.component(.day, from: normalizedDay))")
                        .font(isToday ? .retraceCaptionBold : .retraceCaption)
                        .foregroundColor(
                            isFuture
                                ? .white.opacity(0.16)
                                : (isSelected
                                    ? .white
                                    : .white.opacity(isCurrentMonth ? 0.9 : 0.35))
                        )
                        .frame(width: 32, height: 32)
                        .background(
                            ZStack {
                                if isSelected {
                                    Circle()
                                        .fill(RetraceMenuStyle.actionBlue)
                                } else if isToday {
                                    Circle()
                                        .stroke(RetraceMenuStyle.actionBlue, lineWidth: 1.5)
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFuture)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
        }
    }

    private func selectDay(_ day: Date) {
        draftSelection = clamp(day)
        displayedMonth = monthAnchor(for: day)
    }
}
