import SwiftUI
import Shared

/// Dashboard-native changelog view backed by appcast.xml.
/// Presents versions as expandable cards in a modern, readable layout.
struct ChangelogView: View {
    @ObservedObject private var updaterManager = UpdaterManager.shared

    @State private var expandedEntryID: String?
    @State private var openStartTime: CFAbsoluteTime?
    @State private var didRecordOpenLatency = false

    private let contentMaxWidth: CGFloat = 1100
    private let headerHorizontalPadding: CGFloat = 32
    private let cardsHorizontalPadding: CGFloat = 100

    var body: some View {
        VStack(spacing: 0) {
            header

            if updaterManager.changelogEntries.isEmpty {
                emptyState
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, headerHorizontalPadding)
                    .padding(.bottom, 32)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 14) {
                        ForEach(updaterManager.changelogEntries) { entry in
                            ChangelogEntryCard(
                                entry: entry,
                                isExpanded: expandedEntryID == entry.id,
                                isInstalledVersion: isInstalledVersion(entry)
                            ) {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                    expandedEntryID = expandedEntryID == entry.id ? nil : entry.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, cardsHorizontalPadding)
                    .padding(.bottom, 30)
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                Color.retraceBackground

                LinearGradient(
                    colors: [
                        Color.retraceAccent.opacity(0.13),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blur(radius: 44)
            }
            .ignoresSafeArea()
        )
        .onAppear {
            openStartTime = CFAbsoluteTimeGetCurrent()
            didRecordOpenLatency = false
            ensureExpandedEntryIsValid()
            scheduleOpenLatencyMeasurement(trigger: "on_appear")
        }
        .onChange(of: updaterManager.changelogEntries.map(\.id)) { _ in
            ensureExpandedEntryIsValid()
            scheduleOpenLatencyMeasurement(trigger: "entries_changed")
        }
        .onChange(of: expandedEntryID) { _ in
            scheduleOpenLatencyMeasurement(trigger: "expanded_changed")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
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

                        Text("Changelog")
                            .font(.retraceTitle3)
                            .foregroundColor(.retracePrimary)
                    }

                    Text("Release notes synced from appcast.xml, refreshed when a new update is downloaded.")
                        .font(.retraceCallout)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 10) {
                    if let refreshedAt = updaterManager.changelogLastRefreshDate {
                        Label {
                            Text(refreshedAt.formatted(date: .abbreviated, time: .shortened))
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                    }

                    Text("Updates when a new app version is downloaded")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary.opacity(0.9))
                }
            }
        }
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, headerHorizontalPadding)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: updaterManager.changelogIsRefreshing ? "arrow.clockwise.circle" : "text.book.closed")
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(.retraceAccent)

            Text(updaterManager.changelogIsRefreshing ? "Refreshing changelog..." : "No changelog entries yet")
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            Text("Changelog sync runs when a new app update is downloaded.")
                .font(.retraceCallout)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 34)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func ensureExpandedEntryIsValid() {
        guard !updaterManager.changelogEntries.isEmpty else {
            expandedEntryID = nil
            return
        }

        if let expandedEntryID,
           updaterManager.changelogEntries.contains(where: { $0.id == expandedEntryID }) {
            return
        }

        expandedEntryID = updaterManager.changelogEntries.first?.id
    }

    private func scheduleOpenLatencyMeasurement(trigger: String) {
        guard !didRecordOpenLatency else { return }
        guard !updaterManager.changelogEntries.isEmpty else { return }
        guard expandedEntryID != nil else { return }
        guard let openStartTime else { return }

        didRecordOpenLatency = true
        let entryCount = updaterManager.changelogEntries.count
        let expandedID = expandedEntryID ?? "none"

        Task { @MainActor in
            // Let SwiftUI complete one frame before recording open latency.
            await Task.yield()
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - openStartTime) * 1000

            Log.recordLatency(
                "dashboard.changelog.open_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 1,
                warningThresholdMs: 300,
                criticalThresholdMs: 900
            )
            Log.info(
                "[ChangelogLatency] open completed trigger=\(trigger) entries=\(entryCount) expandedID=\(expandedID) elapsedMs=\(formatMs(elapsedMs))",
                category: .ui
            )
        }
    }

    private func formatMs(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func isInstalledVersion(_ entry: UpdaterManager.ChangelogEntry) -> Bool {
        var hasVersionSignal = false

        if let shortVersion = entry.shortVersion, !shortVersion.isEmpty {
            hasVersionSignal = true
            if shortVersion != updaterManager.currentVersion {
                return false
            }
        }

        if let buildVersion = entry.buildVersion, !buildVersion.isEmpty {
            hasVersionSignal = true
            if buildVersion != updaterManager.currentBuild {
                return false
            }
        }

        return hasVersionSignal
    }
}

private struct ChangelogEntryCard: View {
    let entry: UpdaterManager.ChangelogEntry
    let isExpanded: Bool
    let isInstalledVersion: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(entry.title)
                                .font(.retraceHeadline)
                                .foregroundColor(.retracePrimary)
                                .multilineTextAlignment(.leading)

                            versionChip

                            if isInstalledVersion {
                                installedChip
                            }
                        }

                        HStack(spacing: 10) {
                            if let publishedAt = entry.publishedAt {
                                Label {
                                    Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                                } icon: {
                                    Image(systemName: "calendar")
                                }
                                .font(.retraceCaptionMedium)
                                .foregroundColor(.retraceSecondary)
                            }

                            if let buildVersion = entry.buildVersion, !buildVersion.isEmpty {
                                Text("build \(buildVersion)")
                                    .font(.retraceCaption2Medium)
                                    .foregroundColor(.retraceSecondary.opacity(0.9))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.white.opacity(0.05))
                                    )
                            }
                        }
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.down")
                        .font(.retraceCaptionBold)
                        .foregroundColor(.retraceSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)

                    ChangelogDetailsText(
                        blocks: entry.detailBlocks
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isInstalledVersion {
                        Button(action: {}) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.retraceCaptionBold)
                                Text("You are on this version")
                                    .font(.retraceCaptionBold)
                            }
                            .foregroundColor(.retraceSecondary.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(true)
                    } else if let downloadURL = entry.downloadURL {
                        Link(destination: downloadURL) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.retraceCaptionBold)
                                Text("Download this release")
                                    .font(.retraceCaptionBold)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.retraceAccent.opacity(0.85))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(isExpanded ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isExpanded
                        ? Color.retraceAccent.opacity(0.45)
                        : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(isExpanded ? 0.22 : 0.12), radius: isExpanded ? 16 : 8, x: 0, y: isExpanded ? 8 : 4)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private var versionChip: some View {
        Text("v\(entry.displayVersion)")
            .font(.retraceCaptionBold)
            .foregroundColor(.retracePrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.retraceAccent.opacity(0.2))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.retraceAccent.opacity(0.35), lineWidth: 1)
            )
    }

    private var installedChip: some View {
        Text("Installed")
            .font(.retraceTinyBold)
            .foregroundColor(.retraceSuccess)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.retraceSuccess.opacity(0.16))
            )
    }
}

private struct ChangelogDetailsText: View {
    let blocks: [UpdaterManager.ChangelogEntry.DetailBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.bottom, bottomSpacing(for: index))
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: UpdaterManager.ChangelogEntry.DetailBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(level <= 2 ? .retraceTitle3 : .retraceHeadline)
                .fontWeight(.semibold)
                .foregroundColor(.retracePrimary)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .paragraph(text):
            Text(text)
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary.opacity(0.95))
                .lineSpacing(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .bullet(text):
            HStack(alignment: .top, spacing: 12) {
                Text("•")
                    .font(.retraceBodyBold)
                    .foregroundColor(.retraceSecondary.opacity(0.95))
                    .frame(width: 14, alignment: .leading)
                    .padding(.top, 1)

                Text(text)
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary.opacity(0.95))
                    .lineSpacing(6)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bottomSpacing(for index: Int) -> CGFloat {
        guard index < blocks.count else { return 0 }
        let current = blocks[index]
        let next = (index + 1 < blocks.count) ? blocks[index + 1] : nil

        switch current {
        case .heading:
            return 10
        case .paragraph:
            return 14
        case .bullet:
            if case .bullet? = next {
                return 7
            }
            return 16
        }
    }
}
