import SwiftUI
import Shared

struct ProcessCPUSummaryCard: View {
    private static let cpuRowsPageSize = 10
    private static let cpuRowsContainerHeight: CGFloat = 228

    @ObservedObject private var processCPUMonitor = ProcessCPUMonitor.shared
    @StateObject private var appMetadataCache = AppMetadataCache.shared
    @State private var cpuProcessRowsVisible = Self.cpuRowsPageSize
    @State private var cpuProcessScrollTargetID: String?

    var body: some View {
        let snapshot = processCPUMonitor.snapshot

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.retraceCallout)
                    .foregroundColor(.retraceSecondary)

                Text("Cumulative CPU (from log, last 24h)")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.retracePrimary)

                Spacer()

                Button("Restart") {
                    processCPUMonitor.resetSampler()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retraceSecondary.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
                .help("Clear CPU sampler history and restart baseline collection")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.06))

            VStack(alignment: .leading, spacing: 12) {
            Text("Activity Monitor %CPU is one-core scale. Total Share = %CPU ÷ \(max(snapshot.logicalCoreCount, 1)) cores. Running Share is relative to tracked processes.")
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary.opacity(0.85))

            if snapshot.hasEnoughData {
                let totalRows = snapshot.topProcesses.count
                let visibleRows = min(max(Self.cpuRowsPageSize, cpuProcessRowsVisible), totalRows)
                let hasMoreRows = visibleRows < totalRows

                Text("Sampled duration: \(formatWindowDuration(snapshot.sampleDurationSeconds)) • Total tracked CPU work: \(formatCPUSec(snapshot.totalTrackedCPUSeconds)) CPU Seconds")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.65))

                VStack(spacing: 0) {
                    HStack {
                        Text("Top processes")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("CPU")
                            Text("Seconds")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.retraceSecondary.opacity(0.7))
                        .frame(width: 68, alignment: .trailing)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Running")
                            Text("Share %")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.retraceSecondary.opacity(0.7))
                        .frame(width: 58, alignment: .trailing)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Avg CPU")
                            Text("Usage %")
                        }
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.retraceAccent.opacity(0.95))
                        .frame(width: 68, alignment: .trailing)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Peak CPU")
                            Text("Usage %")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.retraceSecondary.opacity(0.7))
                        .frame(width: 100, alignment: .trailing)
                    }
                    .padding(.bottom, 6)

                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: true) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(snapshot.topProcesses.prefix(visibleRows).enumerated()), id: \.element.id) { index, row in
                                    let rowNumber = index + 1
                                    let peakTotalSharePercent = snapshot.logicalCoreCount > 0
                                        ? ((snapshot.peakPercentByGroup[row.id] ?? 0) / Double(snapshot.logicalCoreCount))
                                        : 0

                                    HStack(spacing: 8) {
                                        Text("\(rowNumber).")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(.retraceSecondary.opacity(0.75))
                                            .lineLimit(1)
                                            .frame(width: 26, alignment: .leading)

                                        processIconView(for: row)
                                            .frame(width: 16, height: 16)

                                        Text(row.name)
                                            .font(.system(size: 11, weight: .regular))
                                            .foregroundColor(.retracePrimary)
                                            .lineLimit(1)

                                        Spacer(minLength: 4)

                                        Text(formatCPUSec(row.cpuSeconds))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(.retracePrimary)
                                            .frame(width: 68, alignment: .trailing)

                                        Text(formatCPUPercent(row.shareOfTrackedPercent))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(.retraceSecondary.opacity(0.95))
                                            .frame(width: 58, alignment: .trailing)

                                        Text(formatCPUPercent(row.capacityPercent))
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.retraceAccent.opacity(0.95))
                                            .frame(width: 68, alignment: .trailing)

                                        Text(formatCPUPercent(peakTotalSharePercent))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(.retraceSecondary.opacity(0.95))
                                            .frame(width: 100, alignment: .trailing)
                                    }
                                    .padding(.vertical, 3)
                                    .id(cpuProcessRowAnchorID(rowNumber))

                                    if index < visibleRows - 1 {
                                        Divider()
                                            .background(Color.white.opacity(0.06))
                                    }
                                }
                            }
                        }
                        .frame(height: Self.cpuRowsContainerHeight)
                        .clipped()
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
                .padding(10)
                .background(Color.black.opacity(0.18))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Legend")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.retraceSecondary.opacity(0.75))
                    Text("CPU Seconds: Total CPU work accumulated by the process during sampled time.")
                        .font(.system(size: 10))
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                    Text("Running Share %: Process share of total tracked CPU work in this table.")
                        .font(.system(size: 10))
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                    Text("Avg CPU Usage %: Process share of total machine CPU capacity (all cores), averaged over sampled time.")
                        .font(.system(size: 10))
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                    Text("Peak CPU Usage %: Highest sampled instant share of total machine CPU capacity (all cores).")
                        .font(.system(size: 10))
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                }
                .padding(.top, 2)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Collecting process CPU baseline...")
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
        }
    }

    private func formatCPUSec(_ seconds: Double) -> String {
        if seconds >= 100 {
            return String(format: "%.0f", seconds)
        }
        return String(format: "%.1f", seconds)
    }

    private func formatCPUPercent(_ percent: Double) -> String {
        String(format: "%.2f%%", percent)
    }

    private func cpuProcessRowAnchorID(_ rowNumber: Int) -> String {
        "systemMonitor.cpuProcessRow.\(rowNumber)"
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
                    .font(.system(size: 11))
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
