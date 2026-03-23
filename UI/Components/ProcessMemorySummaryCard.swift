import Foundation
import SwiftUI
import Shared

struct ProcessMemorySummaryCard: View {
    private static let memoryRowsPageSize = 10
    private static let memoryRowsContainerHeight: CGFloat = 268
    private static let tableLeadingPadding: CGFloat = 6
    private static let tableTrailingPadding: CGFloat = 10
    private static let tableVerticalPadding: CGFloat = 10
    private static let compactRankColumnWidth: CGFloat = 34
    private static let expandedRankColumnWidth: CGFloat = 42
    private static let processRowSpacing: CGFloat = 4
    private static let retraceExpansionScrollAnchorY: CGFloat = 0
    private static let retraceExpansionScrollDelayMilliseconds = 40

    typealias MemoryProcessScrollTarget = ProcessMemoryCardScrollTarget
    private typealias DisplayedMemoryRow = ProcessMemoryCardDisplayedRow

    private let onRowsHoverChanged: ((Bool) -> Void)?
    private let onRetraceRowToggle: ((Bool) -> Void)?
    private let isRowsScrollEnabled: Bool
    private let showsOCRBacklogAttribution: Bool

    @ObservedObject private var processCPUMonitor = ProcessCPUMonitor.shared
    @StateObject private var appMetadataCache = AppMetadataCache.shared
    @StateObject private var cardController = ProcessMemoryCardController()

    init(
        onRowsHoverChanged: ((Bool) -> Void)? = nil,
        onRetraceRowToggle: ((Bool) -> Void)? = nil,
        isRowsScrollEnabled: Bool = true,
        showsOCRBacklogAttribution: Bool = false
    ) {
        self.onRowsHoverChanged = onRowsHoverChanged
        self.onRetraceRowToggle = onRetraceRowToggle
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
                    let presentation = cardController.presentation(
                        for: snapshot,
                        isRowsScrollEnabled: isRowsScrollEnabled,
                        compactRankColumnWidth: Self.compactRankColumnWidth,
                        expandedRankColumnWidth: Self.expandedRankColumnWidth
                    )

                    Text("Sampled duration: \(formatWindowDuration(snapshot.sampleDurationSeconds)) • Current Total: \(formatMemoryBytes(snapshot.totalTrackedCurrentResidentBytes)) • Avg Total: \(formatMemoryBytes(snapshot.totalTrackedAverageResidentBytes))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.retraceSecondary.opacity(0.65))

                    VStack(spacing: 0) {
                        HStack {
                            Text("Top memory owners")
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
                                    ForEach(Array(presentation.displayedRows.enumerated()), id: \.offset) { index, displayedRow in
                                        memoryProcessRowView(
                                            displayedRow: displayedRow,
                                            rankColumnWidth: presentation.rankColumnWidth
                                        )
                                        .id(displayedRow.rank.map(Self.memoryProcessRowAnchorID) ?? displayedRow.id)

                                        if index < presentation.displayedRows.count - 1 {
                                            Divider()
                                                .background(Color.white.opacity(0.06))
                                        }
                                    }
                                }
                            }
                            .scrollDisabled(!presentation.allowsInnerScroll)
                            .frame(height: Self.memoryRowsContainerHeight)
                            .clipped()
                            .onHover { hovering in
                                cardController.handleRowsHoverChanged(hovering)
                                onRowsHoverChanged?(Self.parentHoverState(
                                    isHoveringRows: hovering,
                                    allowsInnerScroll: presentation.allowsInnerScroll
                                ))
                            }
                            .onChange(of: presentation.allowsInnerScroll) { enabled in
                                onRowsHoverChanged?(Self.parentHoverState(
                                    isHoveringRows: cardController.isHoveringRows,
                                    allowsInnerScroll: enabled
                                ))
                            }
                            .onChange(of: cardController.scrollTarget) { target in
                                guard let target else { return }
                                Task { @MainActor in
                                    try? await Task.sleep(
                                        for: .milliseconds(Self.retraceExpansionScrollDelayMilliseconds)
                                    )
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        proxy.scrollTo(
                                            target.id,
                                            anchor: UnitPoint(x: 0.5, y: target.anchorY)
                                        )
                                    }
                                    cardController.clearScrollTarget()
                                }
                            }
                        }

                        if presentation.hasMoreRows {
                            HStack {
                                Spacer()
                                Button("Load 10 more") {
                                    cardController.loadMore(totalRows: presentation.totalRows)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.retraceAccent.opacity(0.95))

                                Text("(\(presentation.visibleRows) / \(presentation.totalRows))")
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
            cardController.handleAppear()
        }
        .onDisappear {
            onRowsHoverChanged?(false)
            cardController.handleDisappear()
        }
    }

    private func formatMemoryBytes(_ bytes: UInt64) -> String {
        Self.formatMemoryBytesForDisplay(bytes)
    }

    static func formatMemoryBytesForDisplay(_ bytes: UInt64) -> String {
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0
        let tb = gb * 1024.0
        let value = Double(bytes)
        let megabytes = value / mb

        if value >= tb {
            return String(format: "%.2f TB", value / tb)
        }
        if (megabytes * 10).rounded() >= 10_000 {
            return String(format: "%.2f GB", value / gb)
        }
        if value >= mb {
            return String(format: "%.1f MB", megabytes)
        }
        if value >= kb {
            return String(format: "%.0f KB", value / kb)
        }
        return "\(bytes) B"
    }

    private static func memoryProcessRowAnchorID(_ rowNumber: Int) -> String {
        ProcessMemoryCardPresentation.memoryProcessRowAnchorID(rowNumber)
    }

    static func retraceExpansionScrollTarget(firstFamilyID: String?) -> MemoryProcessScrollTarget? {
        ProcessMemoryCardController.retraceExpansionScrollTarget(
            firstFamilyID: firstFamilyID,
            anchorY: retraceExpansionScrollAnchorY
        )
    }

    static func shouldEnableInnerScroll(
        isRowsScrollEnabled: Bool,
        visibleRows: Int,
        displayedRowsCount: Int
    ) -> Bool {
        ProcessMemoryCardController.shouldEnableInnerScroll(
            isRowsScrollEnabled: isRowsScrollEnabled,
            visibleRows: visibleRows,
            displayedRowsCount: displayedRowsCount,
            pageSize: Self.memoryRowsPageSize
        )
    }

    static func parentHoverState(isHoveringRows: Bool, allowsInnerScroll: Bool) -> Bool {
        ProcessMemoryCardController.parentHoverState(
            isHoveringRows: isHoveringRows,
            allowsInnerScroll: allowsInnerScroll
        )
    }

    @ViewBuilder
    private func memoryProcessRowView(
        displayedRow: DisplayedMemoryRow,
        rankColumnWidth: CGFloat
    ) -> some View {
        let row = displayedRow.row

        HStack(spacing: Self.processRowSpacing) {
            rankIndicatorView(for: displayedRow, rankColumnWidth: rankColumnWidth)
            rowToggleIndicatorView(for: displayedRow)

            memoryRowIconView(for: displayedRow)

            Text(row.name)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(textColor(for: displayedRow))
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

            memoryValueView(bytes: row.currentBytes, weight: .medium, color: .retraceSecondary.opacity(0.95))
            memoryValueView(bytes: row.averageBytes, weight: .semibold, color: .retraceAccent.opacity(0.95))
            memoryValueView(bytes: row.peakBytes, weight: .medium, color: .retraceSecondary.opacity(0.95))
        }
        .padding(.vertical, 3)
        .padding(.leading, leadingPadding(for: displayedRow))
        .background(backgroundColor(for: displayedRow))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            cardController.handleRowTap(
                displayedRow,
                snapshot: processCPUMonitor.snapshot,
                onRetraceRowToggle: onRetraceRowToggle
            )
        }
    }

    @ViewBuilder
    private func rankIndicatorView(
        for displayedRow: DisplayedMemoryRow,
        rankColumnWidth: CGFloat
    ) -> some View {
        Group {
            if let rowNumber = displayedRow.rank {
                Text("\(rowNumber).")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.retraceSecondary.opacity(0.75))
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }
        }
        .lineLimit(1)
        .frame(width: rankColumnWidth, alignment: .leading)
    }

    @ViewBuilder
    private func rowToggleIndicatorView(for displayedRow: DisplayedMemoryRow) -> some View {
        Group {
            if displayedRow.isPinnedRetrace {
                Image(systemName: cardController.isRetraceExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.retraceSecondary.opacity(0.85))
            } else if displayedRow.isRetraceFamily {
                let isExpanded = displayedRow.retraceFamilyID.map {
                    cardController.expandedAttributionFamilyIDs.contains($0)
                } ?? false
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.retraceSecondary.opacity(0.85))
            } else {
                Color.clear
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 10, height: 10, alignment: .center)
    }

    private func memoryValueView(bytes: UInt64, weight: Font.Weight, color: Color) -> some View {
        Text(formatMemoryBytes(bytes))
            .font(.system(size: 12, weight: weight, design: .monospaced))
            .foregroundColor(color)
            .frame(width: 66, alignment: .trailing)
    }

    private func backgroundColor(for displayedRow: DisplayedMemoryRow) -> Color {
        if displayedRow.isPinnedRetrace {
            return Color.retraceAccent.opacity(0.08)
        }
        if displayedRow.isRetraceFamily {
            return Color.retraceAccent.opacity(0.04)
        }
        if displayedRow.isRetraceComponent {
            return Color.white.opacity(0.02)
        }
        return .clear
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

            Text("Grouped by app process family. Retrace expands into internal memory-attribution families.")
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

    @ViewBuilder
    private func memoryRowIconView(for displayedRow: DisplayedMemoryRow) -> some View {
        switch displayedRow.kind {
        case .primary:
            processIconView(for: displayedRow.row)
                .frame(width: 17, height: 17)
        case .retraceFamily:
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retraceAccent.opacity(0.95))
                .frame(width: 17, height: 17)
        case .retraceComponent:
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.retraceSecondary.opacity(0.8))
                .frame(width: 17, height: 17)
        }
    }

    private func textColor(for displayedRow: DisplayedMemoryRow) -> Color {
        if displayedRow.isRetraceFamily {
            return .retracePrimary.opacity(0.96)
        }
        if displayedRow.isRetraceComponent {
            return .retraceSecondary.opacity(0.96)
        }
        return .retracePrimary
    }

    private func leadingPadding(for displayedRow: DisplayedMemoryRow) -> CGFloat {
        if displayedRow.isRetraceComponent {
            return 28
        }
        if displayedRow.isRetraceFamily {
            return 14
        }
        return 0
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

        if row.id.hasPrefix("retrace-proc:") {
            return appMetadataCache.icon(forAppPath: preferredRetraceIconAppPath())
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

        if row.id.hasPrefix("retrace-proc:") {
            appMetadataCache.requestIcon(forAppPath: preferredRetraceIconAppPath())
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
        if row.id == "app:retrace" || row.id.hasPrefix("retrace-proc:") {
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
