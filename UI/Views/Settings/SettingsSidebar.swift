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
    var sidebar: some View {
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

            // Search button
            Button(action: {
                openSettingsSearch(source: "sidebar_button")
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.retraceSecondary)

                    Text("Search")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                        .lineLimit(1)

                    Spacer()

                    HStack(spacing: 2) {
                        Text("\u{2318}")
                            .font(.system(size: 10, weight: .medium))
                        Text("K")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.retraceSecondary.opacity(0.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Navigation items
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarButton(tab: tab)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            // Version info
            VStack(spacing: 2) {
                Text("Retrace")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)

                Group {
                    if let url = BuildInfo.commitURL {
                        Text(BuildInfo.displayVersion)
                            .onTapGesture { NSWorkspace.shared.open(url) }
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                    } else {
                        Text(BuildInfo.displayVersion)
                    }
                }
                .font(.retraceCaption2Medium)
                .foregroundColor(.retraceSecondary.opacity(0.6))

                if let branch = BuildInfo.displayBranch {
                    Text(branch)
                        .font(.system(size: 9))
                        .foregroundColor(.retraceSecondary.opacity(0.4))
                }

                #if DEBUG
                Text("Debug Build")
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.7))
                #endif
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)
        }
        .background(Color.white.opacity(0.02))
    }

    func sidebarButton(tab: SettingsTab) -> some View {
        let isSelected = shellViewModel.selectedTab == tab
        let isHovered = shellViewModel.hoveredTab == tab

        return Button(action: { shellViewModel.selectedTab = tab }) {
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
                shellViewModel.hoveredTab = hovering ? tab : nil
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    var content: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Content header
                    contentHeader

                    // Settings content
                    VStack(alignment: .leading, spacing: 24) {
                        switch shellViewModel.selectedTab {
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
            .onAppear {
                scrollToPendingTarget(using: proxy)
            }
            .onChange(of: shellViewModel.selectedTab) { _ in
                scrollToPendingTarget(using: proxy)
            }
            .onChange(of: shellViewModel.pendingScrollTargetID) { _ in
                scrollToPendingTarget(using: proxy)
            }
        }
    }

    func requestNavigation(to targetID: String) {
        switch targetID {
        case Self.pauseReminderIntervalTargetID:
            shellViewModel.selectedTab = .capture
        case Self.timelineScrollOrientationTargetID:
            shellViewModel.selectedTab = .general
        case Self.powerOCRCardTargetID:
            shellViewModel.selectedTab = .power
        case Self.powerOCRPriorityTargetID:
            shellViewModel.selectedTab = .power
        default:
            break
        }
        shellViewModel.pendingScrollTargetID = targetID
    }

    func postSelectedTabNotification(_ tab: SettingsTab) {
        NotificationCenter.default.post(
            name: .settingsSelectedTabDidChange,
            object: nil,
            userInfo: ["tab": tab.rawValue]
        )
    }

    func scrollToPendingTarget(using proxy: ScrollViewProxy) {
        guard let targetID = shellViewModel.pendingScrollTargetID,
              !shellViewModel.isScrollingToTarget else { return }

        // Ensure tab content is visible before scrolling to a row inside it.
        switch targetID {
        case Self.pauseReminderIntervalTargetID:
            guard shellViewModel.selectedTab == .capture else { return }
        case Self.timelineScrollOrientationTargetID:
            guard shellViewModel.selectedTab == .general else { return }
        case Self.powerOCRCardTargetID:
            guard shellViewModel.selectedTab == .power else { return }
        case Self.powerOCRPriorityTargetID:
            guard shellViewModel.selectedTab == .power else { return }
        default:
            shellViewModel.pendingScrollTargetID = nil
            return
        }

        let anchorID: String
        switch targetID {
        case Self.pauseReminderIntervalTargetID:
            anchorID = Self.pauseReminderCardAnchorID
        case Self.timelineScrollOrientationTargetID:
            anchorID = Self.timelineScrollOrientationAnchorID
        case Self.powerOCRCardTargetID:
            anchorID = Self.powerOCRCardAnchorID
        case Self.powerOCRPriorityTargetID:
            anchorID = Self.powerOCRPriorityAnchorID
        default:
            shellViewModel.pendingScrollTargetID = nil
            return
        }

        shellViewModel.isScrollingToTarget = true
        Task { @MainActor in
            // Wait one layout pass so the target row is in the tree.
            try? await Task.sleep(for: .nanoseconds(Int64(60_000_000)), clock: .continuous)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            if targetID == Self.pauseReminderIntervalTargetID {
                try? await Task.sleep(for: .nanoseconds(Int64(140_000_000)), clock: .continuous)
                shellViewModel.triggerPauseReminderCardHighlight()
            }
            if targetID == Self.timelineScrollOrientationTargetID {
                try? await Task.sleep(for: .nanoseconds(Int64(140_000_000)), clock: .continuous)
                shellViewModel.triggerTimelineScrollOrientationHighlight()
            }
            if targetID == Self.powerOCRCardTargetID {
                try? await Task.sleep(for: .nanoseconds(Int64(140_000_000)), clock: .continuous)
                shellViewModel.triggerOCRCardHighlight()
            }
            if targetID == Self.powerOCRPriorityTargetID {
                try? await Task.sleep(for: .nanoseconds(Int64(140_000_000)), clock: .continuous)
                shellViewModel.triggerOCRPrioritySliderHighlight()
            }
            shellViewModel.pendingScrollTargetID = nil
            shellViewModel.isScrollingToTarget = false
        }
    }

    var contentHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(shellViewModel.selectedTab.gradient.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: shellViewModel.selectedTab.icon)
                        .font(.retraceHeadline)
                        .foregroundStyle(shellViewModel.selectedTab.gradient)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(shellViewModel.selectedTab.rawValue)
                        .font(.retraceMediumNumber)
                        .foregroundColor(.retracePrimary)

                    Text(shellViewModel.selectedTab.description)
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer()

                // System Monitor button (only for Power tab)
                if shellViewModel.selectedTab == .power {
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
                if shellViewModel.selectedTab.resetAction(for: self) != nil {
                    Button(action: { shellViewModel.showingSectionResetConfirmation = true }) {
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
                    .alert("Reset \(shellViewModel.selectedTab.rawValue) Settings?", isPresented: $shellViewModel.showingSectionResetConfirmation) {
                        Button("Cancel", role: .cancel) {}
                        Button("Reset", role: .destructive) {
                            shellViewModel.selectedTab.resetAction(for: self)?()
                        }
                    } message: {
                        Text("This will reset all \(shellViewModel.selectedTab.rawValue.lowercased()) settings to their defaults.")
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 28)
    }

    // MARK: - General Settings
}
