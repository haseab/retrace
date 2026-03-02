import SwiftUI
import Shared
import App
import Processing

/// System monitor view showing background task status
public struct SystemMonitorView: View {
    @StateObject private var viewModel: SystemMonitorViewModel
    @StateObject private var scrollLatch = SystemMonitorScrollLatchState()
    @State private var localScrollMonitor: Any?

    public init(coordinator: AppCoordinator) {
        _viewModel = StateObject(wrappedValue: SystemMonitorViewModel(coordinator: coordinator))
    }

    /// Maximum width for the system monitor content area before it centers
    /// Matches dashboardMaxWidth for consistent layout in the shared window
    private let monitorMaxWidth: CGFloat = 1100

    public var body: some View {
        ZStack {
            // Background matching dashboard - extends under titlebar
            backgroundView
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header
                    .frame(maxWidth: monitorMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 24)

                // Main content
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        // OCR Processing Section
                        ocrProcessingSection
                            .padding(.bottom, 40)
                        processResourceSummarySection

                        // Future sections placeholder
                        // - Data Transfers
                        // - Migrations
                    }
                    .frame(maxWidth: monitorMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
                .scrollDisabled(isOuterScrollDisabled)
            }
        }
        .task {
            await viewModel.startMonitoring()
        }
        .onAppear {
            installScrollMonitorIfNeeded()
            ProcessCPUMonitor.shared.setConsumerVisible(.systemMonitor, isVisible: true)
        }
        .onDisappear {
            removeScrollMonitor()
            ProcessCPUMonitor.shared.setConsumerVisible(.systemMonitor, isVisible: false)
            viewModel.stopMonitoring()
        }
        .background(
            // Cmd+[ to go back to dashboard
            Button("") {
                NotificationCenter.default.post(name: .openDashboard, object: nil)
            }
            .keyboardShortcut("[", modifiers: .command)
            .hidden()
        )
    }

    // MARK: - Background

    private var backgroundView: some View {
        ZStack {
            Color.retraceBackground

            // Top-right ambient glow (stronger)
            RadialGradient(
                colors: [
                    Color.retraceAccent.opacity(0.12),
                    Color.retraceAccent.opacity(0.04),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 50,
                endRadius: 500
            )

            // Bottom-left ambient glow
            RadialGradient(
                colors: [
                    Color.retraceAccent.opacity(0.08),
                    Color.retraceAccent.opacity(0.02),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 30,
                endRadius: 400
            )
        }
    }

    // MARK: - Header

    @State private var isHoveringBack = false
    @State private var isHoveringSettings = false
    @State private var settingsRotation: Double = 0

    private var header: some View {
        HStack(alignment: .center) {
            // Back button
            Button(action: {
                NotificationCenter.default.post(name: .openDashboard, object: nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Dashboard")
                        .font(.retraceCaptionMedium)
                }
                .foregroundColor(.retraceSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(isHoveringBack ? 0.08 : 0.05))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHoveringBack = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            Spacer()

            // Title
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.retraceTitle3)
                    .foregroundColor(.white)

                Text("System Monitor")
                    .font(.retraceTitle3)
                    .foregroundColor(.retracePrimary)
            }

            Spacer()

            // Right side: Live indicator + Settings button
            HStack(spacing: 12) {
                // Live indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(Color.green.opacity(0.5), lineWidth: 2)
                                .scaleEffect(viewModel.pulseScale)
                                .opacity(viewModel.pulseOpacity)
                        )

                    Text("Live")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                }

                // Settings button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        settingsRotation += 90
                    }
                    NotificationCenter.default.post(name: .openSettingsPower, object: nil)
                }) {
                    Image(systemName: "gearshape")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retraceSecondary)
                        .rotationEffect(.degrees(settingsRotation + (isHoveringSettings ? 30 : 0)))
                        .animation(.easeInOut(duration: 0.2), value: isHoveringSettings)
                        .padding(10)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHoveringSettings = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
    }

    // MARK: - OCR Processing Section

    private var ocrProcessingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "text.viewfinder")
                        .font(.retraceCallout)
                        .foregroundColor(.retraceSecondary)
                    Text("OCR Processing")
                        .font(.retraceCalloutBold)
                        .foregroundColor(.retracePrimary)

                    Spacer()
                    statusBadge
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider()
                    .background(Color.white.opacity(0.06))

                // Chart area
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Frames processed")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                        Text("·")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.5))
                        Text("Last 30 min")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                        Spacer()
                    }

                    ProcessingBarChart(
                        dataPoints: viewModel.processingHistory,
                        pendingCount: viewModel.pendingCount,
                        processingCount: viewModel.processingCount,
                        hoveredIndex: $viewModel.hoveredBarIndex
                    )
                    .frame(height: 140)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 20)

                Divider()
                    .background(Color.white.opacity(0.06))

                // Stats row - horizontal layout with dots between
                HStack(spacing: 16) {
                    // Processed (left) - blue
                    HStack(spacing: 4) {
                        Text("\(viewModel.processedLast30Min)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.retraceAccent)
                        // Show "in the last 30 minutes" only when idle (no pending/processing)
                        if viewModel.processingCount == 0 && viewModel.pendingCount == 0 {
                            Text("processed in the last 30 minutes")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))
                        } else {
                            Text("processed")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))
                        }
                    }

                    if viewModel.processingCount > 0 {
                        Circle()
                            .fill(Color.retraceSecondary.opacity(0.3))
                            .frame(width: 3, height: 3)

                        // Processing (status 1) - green
                        HStack(spacing: 4) {
                            Text("\(viewModel.processingCount)")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.green)
                            Text("processing")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))
                        }
                    }

                    if viewModel.pendingCount > 0 {
                        Circle()
                            .fill(Color.retraceSecondary.opacity(0.3))
                            .frame(width: 3, height: 3)

                        // Pending (status 0) - orange
                        HStack(spacing: 4) {
                            Text("\(viewModel.pendingCount)")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.orange)
                            Text("pending")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))
                        }
                    }

                    Spacer()

                    // ETA (right side)
                    if viewModel.queueDepth > 0 {
                        HStack(spacing: 4) {
                            Text(viewModel.etaText)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.retracePrimary)
                            Text(viewModel.etaSuffixText)
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)

                // Paused warning
                if viewModel.isPausedForBattery {
                    Divider()
                        .background(Color.white.opacity(0.06))

                    HStack(spacing: 8) {
                        Image(systemName: "bolt.slash.fill")
                            .font(.retraceCaption)
                            .foregroundColor(.orange)
                        Text("Processing paused by power settings — adjust them in ")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary)
                        + Text("Settings")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceAccent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NotificationCenter.default.post(name: .openSettingsPowerOCRCard, object: nil)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.05))
                }

                // OCR disabled warning
                if !viewModel.ocrEnabled {
                    Divider()
                        .background(Color.white.opacity(0.06))

                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.retraceAccent.opacity(0.28))
                                .frame(width: 28, height: 28)
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("OCR is paused")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.95))
                            Text("New frames are still captured, but text won’t be searchable until OCR resumes.")
                                .font(.retraceCaption2)
                                .foregroundColor(.white.opacity(0.78))
                        }

                        Spacer()

                        HStack(spacing: 4) {
                            Text("Open Power Settings")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.retraceAccent.opacity(0.30))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.retraceAccent.opacity(0.55), lineWidth: 1)
                        )
                        .cornerRadius(8)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NotificationCenter.default.post(name: .openSettingsPowerOCRCard, object: nil)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.retraceAccent.opacity(0.22),
                                        Color.retraceAccent.opacity(0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.retraceAccent.opacity(0.35), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }

                if viewModel.shouldShowPerformanceNudge {
                    Divider()
                        .background(Color.white.opacity(0.06))

                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.25))
                                .frame(width: 30, height: 30)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.orange)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Large OCR Backlog Detected")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.96))
                            Text("\(viewModel.queueDepth) frames queued. Go to System Settings to increase your OCR Priority.")
                                .font(.retraceCaption2)
                                .foregroundColor(.white.opacity(0.82))
                        }

                        Spacer()

                        HStack(spacing: 4) {
                            Text("Go to System Settings")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.retraceAccent.opacity(0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.retraceAccent.opacity(0.6), lineWidth: 1)
                        )
                        .cornerRadius(8)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NotificationCenter.default.post(name: .openSettingsPowerOCRPriority, object: nil)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.orange.opacity(0.24),
                                        Color.orange.opacity(0.12)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.orange.opacity(0.42), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private var processResourceSummarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.needle")
                    .font(.retraceCallout)
                    .foregroundColor(.retraceSecondary)

                Text("Process Resource Logs (last 12h)")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.retracePrimary)

                Spacer()

                Button("Restart Baseline") {
                    ProcessCPUMonitor.shared.resetSampler()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retraceSecondary.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
                .help("Clear CPU/memory sampler history and restart baseline collection")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.06))

            HStack(alignment: .top, spacing: 12) {
                processCPUSummarySection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                processMemorySummarySection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(12)
        }
        .background(Color.white.opacity(0.02))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var processCPUSummarySection: some View {
        ProcessCPUSummaryCard(
            onRowsHoverChanged: { hovering in
                scrollLatch.updateHover(cpu: hovering)
            },
            isRowsScrollEnabled: isCPUScrollEnabled
        )
    }

    private var processMemorySummarySection: some View {
        ProcessMemorySummaryCard(
            onRowsHoverChanged: { hovering in
                scrollLatch.updateHover(memory: hovering)
            },
            isRowsScrollEnabled: isMemoryScrollEnabled
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(viewModel.statusColor)
                .frame(width: 6, height: 6)
            Text(viewModel.statusBadgeText)
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }

    private func formatNumber(_ number: Int) -> String {
        if number >= 1_000_000 {
            return String(format: "%.1fM", Double(number) / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.1fK", Double(number) / 1_000)
        }
        return "\(number)"
    }

    private var isOuterScrollDisabled: Bool {
        switch scrollLatch.latchedTarget {
        case .cpu, .memory:
            return true
        case .outer, .none:
            return false
        }
    }

    private var isCPUScrollEnabled: Bool {
        switch scrollLatch.latchedTarget {
        case .outer, .memory:
            return false
        case .cpu, .none:
            return true
        }
    }

    private var isMemoryScrollEnabled: Bool {
        switch scrollLatch.latchedTarget {
        case .outer, .cpu:
            return false
        case .memory, .none:
            return true
        }
    }

    private func installScrollMonitorIfNeeded() {
        guard localScrollMonitor == nil else { return }

        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            scrollLatch.handleScrollEvent(event)
            return event
        }
    }

    private func removeScrollMonitor() {
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }
        scrollLatch.reset()
    }
}

@MainActor
private final class SystemMonitorScrollLatchState: ObservableObject {
    enum ScrollTarget {
        case outer
        case cpu
        case memory
    }

    @Published private(set) var latchedTarget: ScrollTarget?

    private var isHoveringCPULogTable = false
    private var isHoveringMemoryLogTable = false
    private var lastScrollTimestamp: CFAbsoluteTime = 0
    private var releaseWorkItem: DispatchWorkItem?

    private let scrollSequenceGap: CFAbsoluteTime = 0.12
    private let releaseDelay: TimeInterval = 0.16
    private let systemMonitorWindowTitle = "System Monitor"

    func updateHover(cpu: Bool? = nil, memory: Bool? = nil) {
        if let cpu {
            isHoveringCPULogTable = cpu
        }
        if let memory {
            isHoveringMemoryLogTable = memory
        }
    }

    func handleScrollEvent(_ event: NSEvent) {
        guard event.window?.title == systemMonitorWindowTitle else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let phase = event.phase
        let momentumPhase = event.momentumPhase
        let startedByPhase = phase.contains(.began) || phase.contains(.mayBegin)
        let startedByGap = latchedTarget == nil || (now - lastScrollTimestamp) > scrollSequenceGap

        if startedByPhase || startedByGap {
            latchedTarget = hoveredTarget
        }
        lastScrollTimestamp = now

        releaseWorkItem?.cancel()
        let hasEnded = phase.contains(.ended) || phase.contains(.cancelled) ||
            momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled)
        if hasEnded {
            latchedTarget = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.latchedTarget = nil
        }
        releaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay, execute: workItem)
    }

    func reset() {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        latchedTarget = nil
        isHoveringCPULogTable = false
        isHoveringMemoryLogTable = false
    }

    private var hoveredTarget: ScrollTarget {
        if isHoveringCPULogTable {
            return .cpu
        }
        if isHoveringMemoryLogTable {
            return .memory
        }
        return .outer
    }

    deinit {
        releaseWorkItem?.cancel()
    }
}

// MARK: - Processing Bar Chart

struct ProcessingBarChart: View {
    let dataPoints: [ProcessingDataPoint]
    let pendingCount: Int
    let processingCount: Int
    @Binding var hoveredIndex: Int?

    // Backlog hover state
    @State private var isHoveringBacklog = false

    // Cap for each backlog bar and maximum number of visible backlog bars.
    private let backlogBarCap = 100
    private let maxVisibleBacklogBars = 10
    private let tooltipEstimatedHeight: CGFloat = 56
    private let tooltipGapAboveBar: CGFloat = 8
    private let tooltipTopOverflowAllowance: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let xAxisHeight: CGFloat = 1  // x-axis line
            let labelPadding: CGFloat = 4  // space between axis and labels
            let labelHeight: CGFloat = 12  // actual label height
            let bottomAreaHeight = xAxisHeight + labelPadding + labelHeight
            let chartHeight = geometry.size.height - bottomAreaHeight

            // Reserve space for backlog section if there's pending work
            let hasBacklog = pendingCount > 0
            // Total backlog bars represented by pending count (each bar shows up to backlogBarCap)
            let totalBacklogBarCount = hasBacklog ? max(1, Int(ceil(Double(pendingCount) / Double(backlogBarCap)))) : 0
            // Render only the most recent backlog bars to avoid overflow in the chart UI.
            let visibleBacklogBarCount = min(totalBacklogBarCount, maxVisibleBacklogBars)
            let singleBarWidth: CGFloat = 28
            let backlogSpacing: CGFloat = 2
            let backlogWidth: CGFloat = hasBacklog ? CGFloat(visibleBacklogBarCount) * singleBarWidth + CGFloat(max(0, visibleBacklogBarCount - 1)) * backlogSpacing + 12 : 0
            let separatorWidth: CGFloat = hasBacklog ? 12 : 0
            let chartWidth = totalWidth - backlogWidth - separatorWidth

            let spacing: CGFloat = 1
            let barWidth = max(3, (chartWidth - CGFloat(dataPoints.count - 1) * spacing) / CGFloat(dataPoints.count))

            // For live bar: total = processed this minute + currently processing
            let lastIndex = dataPoints.count - 1
            let liveProcessedCount = dataPoints.last?.count ?? 0
            let liveTotalForScaling = liveProcessedCount + processingCount

            // Scale based on max of historical data, live total, or backlog cap
            let historicalMax = dataPoints.map(\.count).max() ?? 1
            let maxValue = max(historicalMax, liveTotalForScaling, backlogBarCap, 1)

            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 0) {
                    // Main chart area
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(Array(dataPoints.enumerated()), id: \.offset) { index, point in
                                let isHovered = hoveredIndex == index
                                let isLive = index == lastIndex

                                if isLive {
                                    // Live bar: blue (processed) + green (processing) stacked
                                    liveBarView(
                                        processedCount: point.count,
                                        processingCount: processingCount,
                                        maxValue: maxValue,
                                        barWidth: barWidth,
                                        height: chartHeight,
                                        isHovered: isHovered,
                                        index: index
                                    )
                                } else {
                                    // Historical bar (blue)
                                    let normalizedHeight = CGFloat(point.count) / CGFloat(maxValue)
                                    let barHeight = chartHeight * normalizedHeight

                                    UnevenRoundedRectangle(
                                        topLeadingRadius: 2,
                                        bottomLeadingRadius: 0,
                                        bottomTrailingRadius: 0,
                                        topTrailingRadius: 2
                                    )
                                    .fill(Color.retraceAccent.opacity(isHovered ? 0.9 : 0.6))
                                    .frame(width: barWidth, height: max(barHeight, point.count > 0 ? 3 : 1))
                                    .animation(.easeOut(duration: 0.15), value: isHovered)
                                    .contentShape(Rectangle().size(width: barWidth, height: chartHeight))
                                    .onHover { hovering in
                                        hoveredIndex = hovering ? index : nil
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: chartWidth, height: chartHeight)
                    .overlay(alignment: .top) {
                        // Tooltip for main chart (index >= 0 excludes backlog hover which uses -1)
                        if let index = hoveredIndex, index >= 0, index < dataPoints.count {
                            let point = dataPoints[index]
                            let isLive = index == lastIndex
                            let xPosition = CGFloat(index) * (barWidth + spacing) + barWidth / 2
                            let yPosition = mainTooltipYOffset(
                                for: point,
                                isLive: isLive,
                                maxValue: maxValue,
                                chartHeight: chartHeight
                            )

                            tooltipView(for: point, isLive: isLive)
                                .offset(x: clampTooltipOffset(xPosition, in: chartWidth), y: yPosition)
                                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
                                .animation(.spring(response: 0.18, dampingFraction: 0.86), value: hoveredIndex)
                        }
                    }

                    // Separator and backlog section
                    if hasBacklog {
                        // Dotted vertical line separator
                        Path { path in
                            let dashHeight: CGFloat = 4
                            let gapHeight: CGFloat = 3
                            var y: CGFloat = 0
                            while y < chartHeight {
                                path.move(to: CGPoint(x: separatorWidth / 2, y: y))
                                path.addLine(to: CGPoint(x: separatorWidth / 2, y: min(y + dashHeight, chartHeight)))
                                y += dashHeight + gapHeight
                            }
                        }
                        .stroke(Color.retraceSecondary.opacity(0.3), lineWidth: 1)
                        .frame(width: separatorWidth, height: chartHeight)

                        // Backlog bars (orange) - multiple bars if count exceeds cap
                        backlogBarsView(
                            pendingCount: pendingCount,
                            maxValue: maxValue,
                            visibleBarCount: visibleBacklogBarCount,
                            totalBarCount: totalBacklogBarCount,
                            singleBarWidth: singleBarWidth,
                            spacing: backlogSpacing,
                            totalWidth: backlogWidth,
                            height: chartHeight
                        )
                    }
                }
                .frame(height: chartHeight)

                // X-axis line (spans full width including backlog)
                Rectangle()
                    .fill(Color.retraceSecondary.opacity(0.2))
                    .frame(height: -1)

                // X-axis labels
                HStack(spacing: 0) {
                    // Main chart labels
                    HStack {
                        Text("-30m")
                        Spacer()
                        Text("now")
                    }
                    .frame(width: chartWidth)

                    if hasBacklog {
                        // Separator space
                        Spacer()
                            .frame(width: separatorWidth)

                        // Backlog label
                        Text("backlog")
                            .foregroundColor(.orange.opacity(0.7))
                            .frame(width: backlogWidth)
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.retraceSecondary.opacity(0.5))
                .padding(.top, labelPadding)
                .frame(height: labelPadding + labelHeight)
            }
        }
    }

    // MARK: - Live Bar (blue processed + green processing)

    private func liveBarView(
        processedCount: Int,
        processingCount: Int,
        maxValue: Int,
        barWidth: CGFloat,
        height: CGFloat,
        isHovered: Bool,
        index: Int
    ) -> some View {
        let processedNormalized = CGFloat(processedCount) / CGFloat(maxValue)
        let processingNormalized = CGFloat(processingCount) / CGFloat(maxValue)
        let processedHeight = height * processedNormalized
        let processingHeight = height * processingNormalized

        return VStack(spacing: 0) {
            // Processing portion (green) - on top
            if processingCount > 0 {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 2
                )
                .fill(Color.green.opacity(isHovered ? 1.0 : 0.8))
                .frame(width: barWidth, height: max(processingHeight, 3))
            }

            // Processed portion (blue) - on bottom
            if processedCount > 0 || processingCount == 0 {
                UnevenRoundedRectangle(
                    topLeadingRadius: processingCount > 0 ? 0 : 2,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: processingCount > 0 ? 0 : 2
                )
                .fill(Color.retraceAccent.opacity(isHovered ? 0.9 : 0.6))
                .frame(width: barWidth, height: max(processedHeight, processedCount > 0 ? 3 : 1))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle().size(width: barWidth, height: height))
        .onHover { hovering in
            hoveredIndex = hovering ? index : nil
        }
    }

    // MARK: - Backlog Bars (orange pending, multiple bars for overflow)

    private func backlogBarsView(
        pendingCount: Int,
        maxValue: Int,
        visibleBarCount: Int,
        totalBarCount: Int,
        singleBarWidth: CGFloat,
        spacing: CGFloat,
        totalWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        let newestBarIndex = totalBarCount - 1

        return HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<visibleBarCount, id: \.self) { visibleBarIndex in
                // Show only the most recent N backlog bars when total bar count exceeds UI cap.
                // Bars are rendered left -> right, with newest chunk first so leftmost drains first.
                let actualBarIndex = newestBarIndex - visibleBarIndex
                let previousBarsTotal = actualBarIndex * backlogBarCap
                let remainingForThisBar = pendingCount - previousBarsTotal
                let thisBarCount = min(max(remainingForThisBar, 0), backlogBarCap)

                // Normalize against maxValue (which includes backlogBarCap)
                let normalizedHeight = CGFloat(thisBarCount) / CGFloat(maxValue)
                let barHeight = height * normalizedHeight

                UnevenRoundedRectangle(
                    topLeadingRadius: 3,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 3
                )
                .fill(Color.orange.opacity(isHoveringBacklog ? 0.8 : 0.5))
                .frame(width: singleBarWidth, height: max(barHeight, 6))
            }
        }
        .frame(width: totalWidth, height: height, alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringBacklog = hovering
            hoveredIndex = hovering ? -1 : nil // Use -1 for backlog
        }
        .overlay(alignment: .top) {
            if isHoveringBacklog {
                backlogTooltipView(pendingCount: pendingCount)
                    .offset(y: backlogTooltipYOffset(pendingCount: pendingCount, maxValue: maxValue, chartHeight: height))
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
                    .animation(.spring(response: 0.18, dampingFraction: 0.86), value: isHoveringBacklog)
            }
        }
    }

    // MARK: - Tooltips

    private func tooltipView(for point: ProcessingDataPoint, isLive: Bool) -> some View {
        floatingTooltip {
            VStack(spacing: 5) {
                Text(isLive ? "LIVE NOW" : point.minute.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.45)
                    .foregroundColor(.white.opacity(0.72))

                HStack(spacing: 6) {
                    tooltipMetricChip(
                        text: "\(point.count)",
                        tint: .retraceAccent
                    )
                    if isLive && processingCount > 0 {
                        tooltipMetricChip(
                            text: "+\(processingCount)",
                            tint: .green
                        )
                    }
                }
            }
        }
    }

    private func backlogTooltipView(pendingCount: Int) -> some View {
        VStack(spacing: 0) {
            Text("\(pendingCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.orange.opacity(0.18))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, 6)
                .padding(.top, 5)
                .padding(.bottom, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.15, green: 0.18, blue: 0.24).opacity(0.98),
                                    Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.98)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.34), radius: 10, x: 0, y: 6)
                )

            TooltipPointer()
                .fill(Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.98))
                .frame(width: 10, height: 6)
                .overlay(
                    TooltipPointer()
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )
                .offset(y: -1)
        }
    }

    @ViewBuilder
    private func floatingTooltip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, 8)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.15, green: 0.18, blue: 0.24).opacity(0.98),
                                    Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.98)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.34), radius: 14, x: 0, y: 8)
                )

            TooltipPointer()
                .fill(Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.98))
                .frame(width: 12, height: 7)
                .overlay(
                    TooltipPointer()
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )
                .offset(y: -1)
        }
    }

    private func tooltipMetricChip(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            )
    }

    private func mainTooltipYOffset(
        for point: ProcessingDataPoint,
        isLive: Bool,
        maxValue: Int,
        chartHeight: CGFloat
    ) -> CGFloat {
        let barHeight = mainBarVisualHeight(for: point, isLive: isLive, maxValue: maxValue, chartHeight: chartHeight)
        let barTopY = chartHeight - barHeight
        let desiredY = barTopY - tooltipEstimatedHeight - tooltipGapAboveBar
        return max(-tooltipTopOverflowAllowance, desiredY)
    }

    private func backlogTooltipYOffset(
        pendingCount: Int,
        maxValue: Int,
        chartHeight: CGFloat
    ) -> CGFloat {
        let normalizedHeight = CGFloat(min(max(pendingCount, 0), backlogBarCap)) / CGFloat(max(maxValue, 1))
        let barHeight = max(chartHeight * normalizedHeight, 6)
        let barTopY = chartHeight - barHeight
        let desiredY = barTopY - tooltipEstimatedHeight - tooltipGapAboveBar
        return max(-tooltipTopOverflowAllowance, desiredY)
    }

    private func mainBarVisualHeight(
        for point: ProcessingDataPoint,
        isLive: Bool,
        maxValue: Int,
        chartHeight: CGFloat
    ) -> CGFloat {
        if isLive {
            let processedNormalized = CGFloat(point.count) / CGFloat(max(maxValue, 1))
            let processingNormalized = CGFloat(processingCount) / CGFloat(max(maxValue, 1))
            let processedHeight = chartHeight * processedNormalized
            let processingHeight = chartHeight * processingNormalized

            let visibleProcessingHeight = processingCount > 0 ? max(processingHeight, 3) : 0
            let visibleProcessedHeight = (point.count > 0 || processingCount == 0) ? max(processedHeight, point.count > 0 ? 3 : 1) : 0
            return max(visibleProcessingHeight + visibleProcessedHeight, 1)
        }

        let normalizedHeight = CGFloat(point.count) / CGFloat(max(maxValue, 1))
        let barHeight = chartHeight * normalizedHeight
        return max(barHeight, point.count > 0 ? 3 : 1)
    }

    private func clampTooltipOffset(_ x: CGFloat, in width: CGFloat) -> CGFloat {
        let center = width / 2
        let offset = x - center
        let tooltipHalfWidth: CGFloat = 66
        let maxOffset = max(0, (width / 2) - tooltipHalfWidth)
        return min(max(offset, -maxOffset), maxOffset)
    }
}

private struct TooltipPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}


// MARK: - Data Point

struct ProcessingDataPoint: Identifiable {
    let id = UUID()
    let minute: Date
    let count: Int

    var timeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter.string(from: minute)
    }
}

// MARK: - ViewModel

@MainActor
class SystemMonitorViewModel: ObservableObject {
    #if DEBUG
    private enum DebugDefaultsKey {
        static let pendingCount = "debugSystemMonitorPendingCount"
        static let processingCount = "debugSystemMonitorProcessingCount"
        static let queueDepth = "debugSystemMonitorQueueDepth"
    }
    #endif

    // Queue stats
    @Published var queueDepth: Int = 0
    @Published var pendingCount: Int = 0       // Frames waiting (status 0)
    @Published var processingCount: Int = 0    // Frames being processed (status 1)
    @Published var totalProcessed: Int = 0
    @Published var ocrEnabled: Bool = true
    @Published var isPausedForBattery: Bool = false
    @Published var powerSource: PowerStateMonitor.PowerSource = .unknown
    @Published var ocrProcessingLevel: Int = 3
    @Published var isRecordingActive: Bool = false

    // Chart data
    @Published var processingHistory: [ProcessingDataPoint] = []
    @Published var hoveredBarIndex: Int? = nil

    // Animation
    @Published var pulseScale: CGFloat = 1.0
    @Published var pulseOpacity: Double = 1.0

    private let coordinator: AppCoordinator
    private var monitoringTask: Task<Void, Never>?

    // Track frames processed per minute using minute key (minutes since epoch)
    // Using Int key instead of Date to avoid timezone/rounding issues at minute boundaries
    private var minuteProcessingCounts: [Int: Int] = [:]
    private var queueDepthSamples: [(timestamp: Date, depth: Int)] = []
    private var previousTotalProcessed: Int = 0
    private let backlogNudgeThreshold = 100
    private let queueDepthSampleWindowSeconds: TimeInterval = 45
    private let minimumQueueTrendWindowSeconds: TimeInterval = 12
    private let queueDepthGrowthEpsilonPerMinute: Double = 0.5

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        initializeHistory()
    }

    /// Convert a Date to a minute key (minutes since epoch)
    private func minuteKey(for date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 60)
    }

    /// Convert a minute key back to a Date (start of that minute)
    private func date(fromMinuteKey key: Int) -> Date {
        Date(timeIntervalSince1970: Double(key) * 60)
    }

    private func initializeHistory() {
        // Create 30 empty data points (one per minute)
        let nowKey = minuteKey(for: Date())
        processingHistory = (0..<30).reversed().map { minutesAgo in
            let key = nowKey - minutesAgo
            return ProcessingDataPoint(minute: date(fromMinuteKey: key), count: 0)
        }
    }

    /// Total frames processed in the last 30 minutes (sum of history)
    var processedLast30Min: Int {
        processingHistory.reduce(0) { $0 + $1.count }
    }

    var statusColor: Color {
        if !ocrEnabled {
            return .gray
        } else if isPausedForBattery {
            return .orange
        } else if queueDepth > 0 {
            return .retraceAccent
        } else {
            return .retraceAccent
        }
    }

    var statusBadgeText: String {
        if !ocrEnabled {
            return "Disabled"
        } else if isPausedForBattery {
            return "Paused"
        } else if queueDepth > 0 {
            return "Processing"
        } else {
            return "Idle"
        }
    }

    private var recentProcessingRateFramesPerMinute: Double? {
        let recentProcessed = processingHistory.suffix(5).reduce(0) { $0 + $1.count }
        let minutesOfData = min(5, processingHistory.count)
        guard recentProcessed > 0, minutesOfData > 0 else { return nil }
        return Double(recentProcessed) / Double(minutesOfData)
    }

    private var recentQueueDepthChangePerMinute: Double? {
        Self.queueDepthChangePerMinute(
            samples: queueDepthSamples,
            minimumObservationWindow: minimumQueueTrendWindowSeconds
        )
    }

    private var effectiveDrainRateFramesPerMinute: Double? {
        guard let processingRate = recentProcessingRateFramesPerMinute else { return nil }
        guard isRecordingActive else {
            return processingRate
        }

        // When recording is active, infer net drain from actual queue behavior instead of
        // configured capture interval. Dedup/app filters can make theoretical capture rate wrong.
        if let queueDepthChange = recentQueueDepthChangePerMinute {
            return -queueDepthChange
        }

        // Not enough queue-depth samples yet; fall back to processing rate temporarily.
        return processingRate
    }

    var isBacklogGrowingAtCurrentRates: Bool {
        guard queueDepth > 0,
              isRecordingActive,
              let queueDepthChange = recentQueueDepthChangePerMinute else {
            return false
        }
        return queueDepthChange > queueDepthGrowthEpsilonPerMinute
    }

    var etaText: String {
        guard queueDepth > 0 else { return "—" }
        guard let drainRate = effectiveDrainRateFramesPerMinute else { return "..." }
        guard drainRate > 0 else { return "∞" }

        let minutesRemaining = Double(queueDepth) / drainRate

        if minutesRemaining < 1 {
            return "<1m"
        } else if minutesRemaining < 60 {
            return "\(Int(minutesRemaining))m"
        } else {
            let hours = Int(minutesRemaining / 60)
            let mins = Int(minutesRemaining.truncatingRemainder(dividingBy: 60))
            return "\(hours)h \(mins)m"
        }
    }

    var etaSuffixText: String {
        if isPausedForBattery || !ocrEnabled {
            return "processing time"
        }
        if isBacklogGrowingAtCurrentRates {
            return "backlog growing"
        }
        return "remaining"
    }

    var shouldShowPerformanceNudge: Bool {
        ocrEnabled &&
        !isPausedForBattery &&
        queueDepth >= backlogNudgeThreshold &&
        (1...3).contains(ocrProcessingLevel)
    }

    func startMonitoring() async {
        // Start pulse animation
        startPulseAnimation()

        // Load historical data on first load
        await loadHistoricalData()

        monitoringTask = Task {
            while !Task.isCancelled {
                await updateStats()
                try? await Task.sleep(for: .nanoseconds(Int64(1_000_000_000)), clock: .continuous) // 1 second
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private func startPulseAnimation() {
        Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.easeOut(duration: 1.0)) {
                    pulseScale = 1.6
                    pulseOpacity = 0
                }
                try? await Task.sleep(for: .nanoseconds(Int64(1_000_000_000)), clock: .continuous)
                pulseScale = 1.0
                pulseOpacity = 1.0
            }
        }
    }

    private func loadHistoricalData() async {
        // Query frames processed in last 30 minutes from database
        // Group by minute offset
        if let historicalCounts = try? await coordinator.getFramesProcessedPerMinute(lastMinutes: 30) {
            let nowKey = minuteKey(for: Date())

            for (minuteOffset, count) in historicalCounts {
                let key = nowKey - minuteOffset
                minuteProcessingCounts[key] = count
            }
            updateProcessingHistory()
        }
    }

    private func updateStats() async {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

        // Get queue statistics
        if let stats = await coordinator.getQueueStatistics() {
            queueDepth = stats.queueDepth
            pendingCount = stats.pendingCount
            processingCount = stats.processingCount

            // Calculate frames processed since last update
            let newlyProcessed = stats.totalProcessed - previousTotalProcessed
            if previousTotalProcessed > 0 && newlyProcessed > 0 {
                // Add to current minute's count using stable minute key
                let currentKey = minuteKey(for: Date())
                minuteProcessingCounts[currentKey, default: 0] += newlyProcessed
            }
            previousTotalProcessed = stats.totalProcessed
            totalProcessed = stats.totalProcessed

            updateProcessingHistory()
        }

        #if DEBUG
        applyDebugQueueOverrides(defaults: defaults)
        #endif
        recordQueueDepthSample(queueDepth)

        // Get power state
        let powerState = coordinator.getCurrentPowerState()
        powerSource = powerState.source
        isPausedForBattery = powerState.isPaused

        // Get OCR enabled state
        ocrEnabled = defaults.object(forKey: "ocrEnabled") as? Bool ?? true
        isRecordingActive = coordinator.statusHolder.status.isRunning
        let processingLevel = (defaults.object(forKey: "ocrProcessingLevel") as? NSNumber)?.intValue ?? 3
        ocrProcessingLevel = min(max(processingLevel, 1), 5)
    }

    #if DEBUG
    private func applyDebugQueueOverrides(defaults: UserDefaults) {
        let pendingOverride = (defaults.object(forKey: DebugDefaultsKey.pendingCount) as? NSNumber)?.intValue
        let processingOverride = (defaults.object(forKey: DebugDefaultsKey.processingCount) as? NSNumber)?.intValue
        let queueDepthOverride = (defaults.object(forKey: DebugDefaultsKey.queueDepth) as? NSNumber)?.intValue

        if let pendingOverride {
            pendingCount = max(pendingOverride, 0)
        }

        if let processingOverride {
            processingCount = max(processingOverride, 0)
        }

        if let queueDepthOverride {
            queueDepth = max(queueDepthOverride, 0)
        } else if pendingOverride != nil || processingOverride != nil {
            queueDepth = max(pendingCount + processingCount, 0)
        }
    }
    #endif

    private func updateProcessingHistory() {
        let nowKey = minuteKey(for: Date())

        // Build new history with current minute counts
        var newHistory: [ProcessingDataPoint] = []

        for minutesAgo in (0..<30).reversed() {
            let key = nowKey - minutesAgo
            let count = minuteProcessingCounts[key] ?? 0
            newHistory.append(ProcessingDataPoint(minute: date(fromMinuteKey: key), count: count))
        }

        processingHistory = newHistory

        // Clean up old entries (older than 31 minutes)
        let cutoffKey = nowKey - 31
        minuteProcessingCounts = minuteProcessingCounts.filter { $0.key > cutoffKey }
    }

    private func recordQueueDepthSample(_ depth: Int, at timestamp: Date = Date()) {
        queueDepthSamples.append((timestamp: timestamp, depth: max(depth, 0)))
        let cutoff = timestamp.addingTimeInterval(-queueDepthSampleWindowSeconds)
        queueDepthSamples.removeAll { $0.timestamp < cutoff }
    }

    static func queueDepthChangePerMinute(
        samples: [(timestamp: Date, depth: Int)],
        minimumObservationWindow: TimeInterval = 12
    ) -> Double? {
        guard let oldestSample = samples.first,
              let newestSample = samples.last else {
            return nil
        }

        let elapsedSeconds = newestSample.timestamp.timeIntervalSince(oldestSample.timestamp)
        guard elapsedSeconds >= minimumObservationWindow else {
            return nil
        }

        let depthDelta = Double(newestSample.depth - oldestSample.depth)
        return depthDelta / (elapsedSeconds / 60.0)
    }
}
