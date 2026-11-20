import SwiftUI
import Shared

struct ProcessCPUSummaryCard: View {
    private static let cpuRowsPageSize = 10
    private static let cpuRowsContainerHeight: CGFloat = 268
    private static let tableLeadingPadding: CGFloat = 6
    private static let tableTrailingPadding: CGFloat = 10
    private static let tableVerticalPadding: CGFloat = 10
    private static let compactRankColumnWidth: CGFloat = 34
    private static let expandedRankColumnWidth: CGFloat = 42
    private static let processRowSpacing: CGFloat = 4
    private static let latestSampleTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    private let onRowsHoverChanged: ((Bool) -> Void)?
    private let isRowsScrollEnabled: Bool
    private let showsOCRBacklogAttribution: Bool

    private struct DisplayedCPURow: Identifiable {
        let row: ProcessCPURow
        let rank: Int
        let isPinnedRetrace: Bool

        var id: String { row.id }
    }

    @ObservedObject private var processCPUMonitor = ProcessCPUMonitor.shared
    @StateObject private var appMetadataCache = AppMetadataCache.shared
    @State private var cpuProcessRowsVisible = Self.cpuRowsPageSize
    @State private var cpuProcessScrollTargetID: String?
    @State private var isHoveringCPURows = false

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
                Image(systemName: "cpu")
                    .font(.retraceCallout)
                    .foregroundColor(.retraceSecondary)

                Text("CPU Log")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.retracePrimary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.06))

            VStack(alignment: .leading, spacing: 12) {
            Text("Now % is the latest sampled share of total machine capacity (\(max(snapshot.logicalCoreCount, 1)) cores). Avg % is the window average. Energy is cumulative per-process estimate.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.retraceSecondary.opacity(0.9))

            if snapshot.hasRenderableCPUData {
                let totalRows = snapshot.topProcesses.count
                let visibleRows = min(max(Self.cpuRowsPageSize, cpuProcessRowsVisible), totalRows)
                let hasMoreRows = visibleRows < totalRows
                let displayedRows = buildDisplayedRows(from: snapshot, visibleRows: visibleRows)
                let rankColumnWidth = processRankColumnWidth(for: displayedRows)
                // Keep the parent scroll area in control until the user expands past the first page.
                let allowsInnerScroll = isRowsScrollEnabled && visibleRows > Self.cpuRowsPageSize

                Text(
                    "Sampled duration: \(formatWindowDuration(snapshot.sampleDurationSeconds))"
                        + " • Latest sample: \(formatLatestSampleTime(snapshot.latestSampleTimestamp))"
                        + " • \(formatEnergy(snapshot.totalTrackedEnergyJoules)) J"
                )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.65))

                VStack(spacing: 0) {
                    HStack {
                        Text("Top processes")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                        Spacer()
                        Text("Now %")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                            .frame(width: 50, alignment: .trailing)
                        Text("Energy (J)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                            .frame(width: 62, alignment: .trailing)
                        Text("Avg %")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.retraceAccent.opacity(0.95))
                            .frame(width: 46, alignment: .trailing)
                        Text("Peak %")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                            .frame(width: 50, alignment: .trailing)
                    }
                    .padding(.bottom, 6)

                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: true) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(displayedRows.enumerated()), id: \.element.id) { index, displayedRow in
                                    let row = displayedRow.row
                                    let rowNumber = displayedRow.rank
                                    let peakTotalSharePercent = snapshot.logicalCoreCount > 0
                                        ? ((snapshot.peakPercentByGroup[row.id] ?? 0) / Double(snapshot.logicalCoreCount))
                                        : 0

                                    HStack(spacing: Self.processRowSpacing) {
                                        Text("\(rowNumber).")
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.retraceSecondary.opacity(0.75))
                                            .lineLimit(1)
                                            .frame(width: rankColumnWidth, alignment: .leading)

                                        processIconView(for: row)
                                            .frame(width: 17, height: 17)

                                        Text(row.name)
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundColor(.retracePrimary)
                                            .lineLimit(1)

                                        if displayedRow.isPinnedRetrace && showsOCRBacklogAttribution {
                                            Text("OCR running")
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

                                        Text(formatCPUPercent(row.currentCapacityPercent))
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.retracePrimary)
                                            .frame(width: 50, alignment: .trailing)

                                        Text(formatEnergy(row.energyJoules))
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.retracePrimary)
                                            .frame(width: 62, alignment: .trailing)

                                        Text(formatCPUPercent(row.capacityPercent))
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.retraceAccent.opacity(0.95))
                                            .frame(width: 46, alignment: .trailing)

                                        Text(formatCPUPercent(peakTotalSharePercent))
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.retraceSecondary.opacity(0.95))
                                            .frame(width: 50, alignment: .trailing)
                                    }
                                    .padding(.vertical, 3)
                                    .background(
                                        displayedRow.isPinnedRetrace
                                            ? Color.retraceAccent.opacity(0.08)
                                            : Color.clear
                                    )
                                    .cornerRadius(4)
                                    .id(cpuProcessRowAnchorID(rowNumber))

                                    if index < displayedRows.count - 1 {
                                        Divider()
                                            .background(Color.white.opacity(0.06))
                                    }
                                }
                            }
                        }
                        .scrollDisabled(!allowsInnerScroll)
                        .frame(height: Self.cpuRowsContainerHeight)
                        .clipped()
                        .onHover { hovering in
                            isHoveringCPURows = hovering
                            onRowsHoverChanged?(Self.parentHoverState(
                                isHoveringRows: hovering,
                                allowsInnerScroll: allowsInnerScroll
                            ))
                        }
                        .onChange(of: allowsInnerScroll) { enabled in
                            onRowsHoverChanged?(Self.parentHoverState(
                                isHoveringRows: isHoveringCPURows,
                                allowsInnerScroll: enabled
                            ))
                        }
                        .onChange(of: cpuProcessScrollTargetID) { targetID in
                            guard let targetID else { return }
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    proxy.scrollTo(targetID, anchor: .top)
                                }
                                cpuProcessScrollTargetID = nil
                            }
                        }
                    }

                    if hasMoreRows {
                        HStack {
                            Spacer()
                            Button("Load 10 more") {
                                let nextStartRow = visibleRows + 1
                                guard nextStartRow <= totalRows else { return }
                                cpuProcessRowsVisible = min(totalRows, visibleRows + Self.cpuRowsPageSize)
                                cpuProcessScrollTargetID = cpuProcessRowAnchorID(nextStartRow)
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
                .padding(.leading, Self.tableLeadingPadding)
                .padding(.trailing, Self.tableTrailingPadding)
                .padding(.vertical, Self.tableVerticalPadding)
                .background(Color.black.opacity(0.18))
                .cornerRadius(8)

                cpuUsageGuidePanel
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("No recent process CPU history yet. Sampling now...")
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
            cpuProcessRowsVisible = Self.cpuRowsPageSize
            cpuProcessScrollTargetID = nil
            isHoveringCPURows = false
        }
        .onDisappear {
            onRowsHoverChanged?(false)
        }
    }

    private func formatCPUPercent(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }

    private func formatEnergy(_ joules: Double) -> String {
        let safeJoules = max(0, joules)
        if safeJoules >= 100 {
            return String(format: "%.0f", safeJoules)
        }
        if safeJoules >= 10 {
            return String(format: "%.1f", safeJoules)
        }
        return String(format: "%.2f", safeJoules)
    }

    private func formatLatestSampleTime(_ timestamp: TimeInterval?) -> String {
        guard let timestamp else { return "waiting..." }
        return Self.latestSampleTimeFormatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private func cpuProcessRowAnchorID(_ rowNumber: Int) -> String {
        "systemMonitor.cpuProcessRow.\(rowNumber)"
    }

    static func parentHoverState(isHoveringRows: Bool, allowsInnerScroll: Bool) -> Bool {
        allowsInnerScroll && isHoveringRows
    }

    private func processRankColumnWidth(for displayedRows: [DisplayedCPURow]) -> CGFloat {
        let hasThreeDigitRank = displayedRows.contains { $0.rank >= 100 }
        return hasThreeDigitRank ? Self.expandedRankColumnWidth : Self.compactRankColumnWidth
    }

    private var cpuUsageGuidePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Avg CPU Usage Guide")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retracePrimary)

            cpuUsageScaleBar
                .padding(.top, 4)
            cpuBoundaryValueRow

            Text("Note: Retrace will likely consume more Avg. CPU than other apps")
                .font(.system(size: 10))
                .foregroundColor(.retraceSecondary.opacity(0.85))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            Text("That is fine so long as it is within the green range. Pause OCR to reduce CPU usage.")
                .font(.system(size: 10))
                .foregroundColor(.retraceSecondary.opacity(0.85))
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

    private var cpuUsageScaleBar: some View {
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
            .accessibilityLabel("CPU usage guide scale")
            .accessibilityValue("Thresholds at 5 and 10 percent, with lower usage better")
    }

    private var cpuBoundaryValueRow: some View {
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

                Text("5%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(width: 30, alignment: .center)
                    .offset(x: max(0, (width * 0.33) - 15))
                Text("10%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(width: 36, alignment: .center)
                    .offset(x: max(0, (width * 0.66) - 18))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 14)
        .foregroundColor(.retraceSecondary.opacity(0.92))
    }

    private func buildDisplayedRows(from snapshot: ProcessCPUSnapshot, visibleRows: Int) -> [DisplayedCPURow] {
        let rankedRows = snapshot.topProcesses
        guard !rankedRows.isEmpty else { return [] }
        let retraceGroupKey = snapshot.retraceGroupKey

        var displayed = rankedRows
            .prefix(visibleRows)
            .enumerated()
            .map { offset, row in
                DisplayedCPURow(
                    row: row,
                    rank: offset + 1,
                    isPinnedRetrace: row.id == retraceGroupKey
                )
            }

        if let retraceGroupKey,
           let retraceIndex = rankedRows.firstIndex(where: { $0.id == retraceGroupKey }),
           retraceIndex >= visibleRows {
            let retraceRow = DisplayedCPURow(
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

    @ViewBuilder
    private func processIconView(for row: ProcessCPURow) -> some View {
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

    private func cachedProcessIcon(for row: ProcessCPURow) -> NSImage? {
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

    private func requestProcessIconIfNeeded(for row: ProcessCPURow) {
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

    private func isRetraceProcess(_ row: ProcessCPURow) -> Bool {
        if row.id == "app:retrace" {
            return true
        }

        guard let retraceBundleID = Bundle.main.bundleIdentifier?.lowercased(),
              let bundleID = processBundleID(for: row)?.lowercased() else {
            return false
        }
        return retraceBundleID == bundleID
    }

    private func processBundleID(for row: ProcessCPURow) -> String? {
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
