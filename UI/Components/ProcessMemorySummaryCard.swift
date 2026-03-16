import Foundation
import SwiftUI
import Shared

struct ProcessMemorySummaryCard: View {
    private static let memoryRowsPageSize = 10
    private static let memoryRowsContainerHeight: CGFloat = 268

    private let onRowsHoverChanged: ((Bool) -> Void)?
    private let isRowsScrollEnabled: Bool
    private let showsOCRBacklogAttribution: Bool

    private struct DisplayedMemoryRow: Identifiable {
        let row: ProcessMemoryRow
        let rank: Int
        let isPinnedRetrace: Bool

        var id: String { row.id }
    }

    @ObservedObject private var processCPUMonitor = ProcessCPUMonitor.shared
    @StateObject private var appMetadataCache = AppMetadataCache.shared
    @State private var memoryProcessRowsVisible = Self.memoryRowsPageSize
    @State private var memoryProcessScrollTargetID: String?

    init(
        onRowsHoverChanged: ((Bool) -> Void)? = nil,
        isRowsScrollEnabled: Bool = true,
        showsOCRBacklogAttribution: Bool = false
    ) {
        self.onRowsHoverChanged = onRowsHoverChanged
        self.isRowsScrollEnabled = isRowsScrollEnabled
        self.showsOCRBacklogAttribution = showsOCRBacklogAttribution
    }

    var body: some View {
        let snapshot = processCPUMonitor.snapshot

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .font(.retraceCallout)
                    .foregroundColor(.retraceSecondary)

                HStack(spacing: 3) {
                    Text("Memory Log")
                        .font(.retraceCalloutBold)
                        .foregroundColor(.retracePrimary)
                    Text("*")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.retraceSecondary.opacity(0.85))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.06))

            VStack(alignment: .leading, spacing: 12) {
                Text("Avg and Peak are sampled across the visible 12h window. Now is the latest sample.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.9))

                if snapshot.hasRenderableMemoryData {
                    let totalRows = snapshot.topMemoryProcesses.count
                    let visibleRows = min(max(Self.memoryRowsPageSize, memoryProcessRowsVisible), totalRows)
                    let hasMoreRows = visibleRows < totalRows
                    let displayedRows = buildDisplayedRows(from: snapshot, visibleRows: visibleRows)
                    // Keep the parent scroll area in control until the user expands past the first page.
                    let allowsInnerScroll = isRowsScrollEnabled && visibleRows > Self.memoryRowsPageSize

                    Text("Sampled duration: \(formatWindowDuration(snapshot.sampleDurationSeconds)) • Current Total: \(formatMemoryBytes(snapshot.totalTrackedCurrentResidentBytes)) • Avg Total: \(formatMemoryBytes(snapshot.totalTrackedAverageResidentBytes))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.retraceSecondary.opacity(0.65))

                    VStack(spacing: 0) {
                        HStack {
                            Text("Top processes")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.retraceSecondary.opacity(0.7))
                            Spacer()
                            Text("Now")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                            .frame(width: 66, alignment: .trailing)
                            Text("Avg")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.retraceAccent.opacity(0.95))
                            .frame(width: 66, alignment: .trailing)
                            Text("Peak")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                            .frame(width: 66, alignment: .trailing)
                        }
                        .padding(.bottom, 6)

                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: true) {
                                // Use a non-lazy stack + slot-based identity to avoid stale row reuse
                                // when process ranks reshuffle every second.
                                VStack(spacing: 0) {
                                    ForEach(Array(displayedRows.enumerated()), id: \.offset) { index, displayedRow in
                                        let row = displayedRow.row
                                        let rowNumber = displayedRow.rank
                                        HStack(spacing: 6) {
                                            Text("\(rowNumber).")
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundColor(.retraceSecondary.opacity(0.75))
                                                .lineLimit(1)
                                                .frame(width: 28, alignment: .leading)

                                            processIconView(for: row)
                                                .frame(width: 17, height: 17)

                                            Text(row.name)
                                                .font(.system(size: 12, weight: .regular))
                                                .foregroundColor(.retracePrimary)
                                                .lineLimit(1)

                                            if displayedRow.isPinnedRetrace && showsOCRBacklogAttribution {
                                                Text("OCR backlog")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundColor(.retraceAccent.opacity(0.98))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.retraceAccent.opacity(0.14))
                                                    .overlay(
                                                        Capsule()
                                                            .stroke(Color.retraceAccent.opacity(0.32), lineWidth: 1)
                                                    )
                                                    .clipShape(Capsule())
                                            }

                                            Spacer(minLength: 2)

                                            Text(formatMemoryBytes(row.currentBytes))
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundColor(.retraceSecondary.opacity(0.95))
                                                .frame(width: 66, alignment: .trailing)

                                            Text(formatMemoryBytes(row.averageBytes))
                                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                .foregroundColor(.retraceAccent.opacity(0.95))
                                                .frame(width: 66, alignment: .trailing)

                                            Text(formatMemoryBytes(row.peakBytes))
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundColor(.retraceSecondary.opacity(0.95))
                                                .frame(width: 66, alignment: .trailing)
                                        }
                                        .padding(.vertical, 3)
                                        .background(
                                            displayedRow.isPinnedRetrace
                                                ? Color.retraceAccent.opacity(0.08)
                                                : Color.clear
                                        )
                                        .cornerRadius(4)
                                        .id(memoryProcessRowAnchorID(rowNumber))

                                        if index < displayedRows.count - 1 {
                                            Divider()
                                                .background(Color.white.opacity(0.06))
                                        }
                                    }
                                }
                            }
                            .scrollDisabled(!allowsInnerScroll)
                            .frame(height: Self.memoryRowsContainerHeight)
                            .clipped()
                            .onHover { hovering in
                                onRowsHoverChanged?(allowsInnerScroll ? hovering : false)
                            }
                            .onChange(of: allowsInnerScroll) { enabled in
                                if !enabled {
                                    onRowsHoverChanged?(false)
                                }
                            }
                            .onChange(of: memoryProcessScrollTargetID) { targetID in
                                guard let targetID else { return }
                                DispatchQueue.main.async {
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        proxy.scrollTo(targetID, anchor: .top)
                                    }
                                    memoryProcessScrollTargetID = nil
                                }
                            }
                        }

                        if hasMoreRows {
                            HStack {
                                Spacer()
                                Button("Load 10 more") {
                                    let nextStartRow = visibleRows + 1
                                    guard nextStartRow <= totalRows else { return }
                                    memoryProcessRowsVisible = min(totalRows, visibleRows + Self.memoryRowsPageSize)
                                    memoryProcessScrollTargetID = memoryProcessRowAnchorID(nextStartRow)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.retraceAccent.opacity(0.95))

                                Text("(\(visibleRows) / \(totalRows))")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.retraceSecondary.opacity(0.75))
                                Spacer()
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.18))
                    .cornerRadius(8)

                    memoryUsageGuidePanel
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("No recent process memory history yet. Sampling now...")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary)
                    }
                }
            }
            .padding(12)
        }
        .background(Color.white.opacity(0.02))
        .cornerRadius(10)
        .onAppear {
            memoryProcessRowsVisible = Self.memoryRowsPageSize
            memoryProcessScrollTargetID = nil
        }
        .onDisappear {
            onRowsHoverChanged?(false)
        }
    }

    private func formatMemoryBytes(_ bytes: UInt64) -> String {
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0
        let tb = gb * 1024.0
        let value = Double(bytes)

        if value >= tb {
            return String(format: "%.2f TB", value / tb)
        }
        if value >= gb {
            return String(format: "%.2f GB", value / gb)
        }
        if value >= mb {
            return String(format: "%.1f MB", value / mb)
        }
        if value >= kb {
            return String(format: "%.0f KB", value / kb)
        }
        return "\(bytes) B"
    }

    private func memoryProcessRowAnchorID(_ rowNumber: Int) -> String {
        "systemMonitor.memoryProcessRow.\(rowNumber)"
    }

    private var memoryUsageGuidePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Avg Memory Usage Guide")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retracePrimary)
                .padding(.bottom, 4)

            memoryUsageScaleBar
                .padding(.top, 4)
            memoryBoundaryValueRow

            Text("Grouped by app process family, so totals can differ from Activity Monitor.")
                .font(.system(size: 10))
                .foregroundColor(.retraceSecondary.opacity(0.88))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            Text("However Retrace's process should be consistent across different process tools")
                .font(.system(size: 10))
                .foregroundColor(.retraceSecondary.opacity(0.88))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var memoryUsageScaleBar: some View {
        Capsule()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color.green.opacity(0.85), location: 0.00),
                        .init(color: Color.green.opacity(0.85), location: 0.33),
                        .init(color: Color.yellow.opacity(0.90), location: 0.33),
                        .init(color: Color.yellow.opacity(0.90), location: 0.66),
                        .init(color: Color.red.opacity(0.90), location: 0.66),
                        .init(color: Color.red.opacity(0.90), location: 1.00)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 10)
            .overlay {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack(alignment: .leading) {
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        Rectangle()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: 1, height: 12)
                            .offset(x: max(0, (width * 0.33) - 0.5), y: -1)
                        Rectangle()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: 1, height: 12)
                            .offset(x: max(0, (width * 0.66) - 0.5), y: -1)
                    }
                }
                .allowsHitTesting(false)
            }
            .accessibilityLabel("Memory usage guide scale")
            .accessibilityValue("Thresholds at 1 and 2 gigabytes, with lower memory usage better")
    }

    private var memoryBoundaryValueRow: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                HStack {
                    Text("Good")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text("Bad")
                        .font(.system(size: 10, weight: .semibold))
                }

                Text("1.0 GB")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(width: 52, alignment: .center)
                    .offset(x: max(0, (width * 0.33) - 26))
                Text("2.0 GB")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(width: 52, alignment: .center)
                    .offset(x: max(0, (width * 0.66) - 26))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 14)
        .foregroundColor(.retraceSecondary.opacity(0.92))
    }

    private func buildDisplayedRows(from snapshot: ProcessCPUSnapshot, visibleRows: Int) -> [DisplayedMemoryRow] {
        let rankedRows = snapshot.topMemoryProcesses
        guard !rankedRows.isEmpty else { return [] }
        let retraceGroupKey = snapshot.retraceGroupKey

        var displayed = rankedRows
            .prefix(visibleRows)
            .enumerated()
            .map { offset, row in
                DisplayedMemoryRow(
                    row: row,
                    rank: offset + 1,
                    isPinnedRetrace: row.id == retraceGroupKey
                )
            }

        if let retraceGroupKey,
           let retraceIndex = rankedRows.firstIndex(where: { $0.id == retraceGroupKey }),
           retraceIndex >= visibleRows {
            let retraceRow = DisplayedMemoryRow(
                row: rankedRows[retraceIndex],
                rank: retraceIndex + 1,
                isPinnedRetrace: true
            )

            if displayed.isEmpty {
                displayed.append(retraceRow)
            } else {
                displayed[displayed.count - 1] = retraceRow
            }
        }

        return displayed
    }

    private func retraceMemoryRow(from snapshot: ProcessCPUSnapshot) -> ProcessMemoryRow? {
        guard let retraceGroupKey = snapshot.retraceGroupKey else { return nil }
        return snapshot.topMemoryProcesses.first(where: { $0.id == retraceGroupKey })
    }

    @ViewBuilder
    private func processIconView(for row: ProcessMemoryRow) -> some View {
        Group {
            if let icon = cachedProcessIcon(for: row) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.retraceSecondary.opacity(0.75))
            }
        }
        .onAppear {
            requestProcessIconIfNeeded(for: row)
        }
    }

    private func cachedProcessIcon(for row: ProcessMemoryRow) -> NSImage? {
        if let bundleID = processBundleID(for: row),
           let icon = appMetadataCache.icon(for: bundleID) {
            return icon
        }

        if isRetraceProcess(row),
           let icon = appMetadataCache.icon(forAppPath: preferredRetraceIconAppPath()) {
            return icon
        }

        if row.id == "app:retrace" {
            return appMetadataCache.icon(forAppPath: preferredRetraceIconAppPath())
        }

        if let appPath = processAppPath(from: row.id),
           let icon = appMetadataCache.icon(forAppPath: appPath) {
            return icon
        }

        if let icon = appMetadataCache.icon(forProcessName: row.name) {
            return icon
        }

        return nil
    }

    private func requestProcessIconIfNeeded(for row: ProcessMemoryRow) {
        if let bundleID = processBundleID(for: row) {
            appMetadataCache.requestMetadata(for: bundleID)
            if isRetraceProcess(row) {
                appMetadataCache.requestIcon(forAppPath: preferredRetraceIconAppPath())
            }
            appMetadataCache.requestIcon(forProcessName: row.name)
            return
        }

        if row.id == "app:retrace" {
            appMetadataCache.requestIcon(forAppPath: preferredRetraceIconAppPath())
            return
        }

        if let appPath = processAppPath(from: row.id) {
            appMetadataCache.requestIcon(forAppPath: appPath)
            return
        }

        appMetadataCache.requestIcon(forProcessName: row.name)
    }

    private func isRetraceProcess(_ row: ProcessMemoryRow) -> Bool {
        if row.id == "app:retrace" {
            return true
        }

        guard let retraceBundleID = Bundle.main.bundleIdentifier?.lowercased(),
              let bundleID = processBundleID(for: row)?.lowercased() else {
            return false
        }
        return retraceBundleID == bundleID
    }

    private func processBundleID(for row: ProcessMemoryRow) -> String? {
        if row.id.hasPrefix("bundle:") {
            return String(row.id.dropFirst("bundle:".count))
        }
        if row.id == "app:retrace" {
            return Bundle.main.bundleIdentifier
        }
        return nil
    }

    private func processAppPath(from processGroupID: String) -> String? {
        guard processGroupID.hasPrefix("app:") else { return nil }
        let rawValue = String(processGroupID.dropFirst(4))
        guard rawValue.contains("/"), rawValue.hasSuffix(".app") else { return nil }
        return rawValue
    }

    private func preferredRetraceIconAppPath() -> String {
        let installedPath = "/Applications/Retrace.app"
        if FileManager.default.fileExists(atPath: installedPath) {
            return installedPath
        }
        return Bundle.main.bundlePath
    }

    private func formatWindowDuration(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        let hours = clamped / 3600
        let minutes = clamped / 60
        let remainingMinutes = (clamped % 3600) / 60
        let remainingSeconds = clamped % 60

        if hours > 0 {
            if remainingMinutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(remainingMinutes)m"
        }
        if minutes == 0 {
            return "\(remainingSeconds)s"
        }
        if remainingSeconds == 0 {
            return "\(minutes)m"
        }
        return "\(minutes)m \(remainingSeconds)s"
    }
}
