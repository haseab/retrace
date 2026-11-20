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
    @ViewBuilder
    func cardView(for entry: SettingsSearchEntry) -> some View {
        switch entry.id {
        case "general.shortcuts": keyboardShortcutsCard
        case "general.updates": updatesCard
        case "general.startup": startupCard
        case "general.appearance": appearanceCard
        case "capture.rate": captureRateCard
        case "capture.menuBarIcon": menuBarIconCard
        case "capture.compression": compressionCard
        case "capture.pauseReminder": pauseReminderCard
        case "capture.inPageURLs": inPageURLCollectionCard
        case "storage.rewindData": rewindDataCard
        case "storage.databaseLocations": databaseLocationsCard
        case "storage.retentionPolicy": retentionPolicyCard
        case "exportData.comingSoon": comingSoonCard
        case "privacy.excludedApps": appLevelRedactionCard
        case "privacy.frameRedaction": windowLevelRedactionCard
        case "privacy.phraseRedaction": phraseLevelRedactionCard
        case "privacy.quickDelete": quickDeleteCard
        case "privacy.permissions": permissionsCard
        case "power.ocrProcessing": ocrProcessingCard
        case "power.powerEfficiency": powerEfficiencyCard
        case "power.appFilter": appFilterCard
        case "tags.manageTags": manageTagsCard
        case "advanced.cache": cacheCard
        case "advanced.timeline": timelineCard
        case "advanced.developer": developerCard
        case "advanced.dangerZone": dangerZoneCard
        default: EmptyView()
        }
    }

    // MARK: - Settings Search Overlay

    @ViewBuilder
    var settingsSearchOverlay: some View {
        if shellViewModel.showSettingsSearch {
            ZStack {
                // Backdrop
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { dismissSettingsSearch() }

                // Search panel
                VStack(spacing: 0) {
                    // Search bar
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.5))

                        SettingsSearchField(
                            text: $shellViewModel.settingsSearchQuery,
                            onEscape: { dismissSettingsSearch() }
                        )
                        .frame(height: 24)

                        Text("esc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.3))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                    Divider()
                        .background(Color.white.opacity(0.1))

                    // Results
                    let results = SettingsShellViewModel.searchResults(for: shellViewModel.settingsSearchQuery)

                    if shellViewModel.settingsSearchQuery.isEmpty {
                        VStack(spacing: 8) {
                            Text("Search settings...")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retraceSecondary)
                            Text("Type to find settings like \"OCR\", \"retention\", \"privacy\"")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else if results.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 32))
                                .foregroundColor(.retraceSecondary.opacity(0.4))
                            Text("No settings found for \"\(shellViewModel.settingsSearchQuery)\"")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retraceSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ScrollView(showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(results) { entry in
                                    VStack(alignment: .leading, spacing: 8) {
                                        // Breadcrumb
                                        HStack(spacing: 6) {
                                            Image(systemName: entry.tab.icon)
                                                .font(.system(size: 10))
                                                .foregroundStyle(entry.tab.gradient)
                                            Text(entry.breadcrumb)
                                                .font(.retraceCaption2)
                                                .foregroundColor(.retraceSecondary)

                                            Spacer()

                                            // Navigate button
                                            Button(action: {
                                                dismissSettingsSearch()
                                                shellViewModel.selectedTab = entry.tab
                                            }) {
                                                HStack(spacing: 4) {
                                                    Text("Go to")
                                                        .font(.system(size: 10, weight: .medium))
                                                    Image(systemName: "arrow.right")
                                                        .font(.system(size: 8, weight: .semibold))
                                                }
                                                .foregroundColor(.retraceAccent)
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        // Actual settings card with working controls
                                        cardView(for: entry)
                                    }
                                }
                            }
                            .padding(20)
                        }
                        .frame(maxHeight: 500)
                    }
                }
                .frame(width: 600)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
            }
            .transition(.opacity)
            .onExitCommand { dismissSettingsSearch() }
        }
    }

    func dismissSettingsSearch() {
        withAnimation(.easeOut(duration: 0.15)) {
            shellViewModel.showSettingsSearch = false
        }
        shellViewModel.scheduleSettingsSearchReset()
    }

    func openSettingsSearch(source: String) {
        if !shellViewModel.showSettingsSearch {
            DashboardViewModel.recordSettingsSearchOpened(
                coordinator: coordinatorWrapper.coordinator,
                source: source
            )
        }

        shellViewModel.cancelSettingsSearchReset()
        withAnimation(.easeOut(duration: 0.15)) {
            shellViewModel.showSettingsSearch = true
        }
    }
}
