import SwiftUI
import Shared
import App
import Processing

/// System monitor view showing background task status
public struct SystemMonitorView: View {
    @StateObject private var viewModel: SystemMonitorViewModel
    private let coordinator: AppCoordinator
    @StateObject private var scrollLatch = SystemMonitorScrollLatchState()
    @State private var localScrollMonitor: Any?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _viewModel = StateObject(wrappedValue: SystemMonitorViewModel(coordinator: coordinator))
    }

    /// Maximum width for the system monitor content area before it centers
    /// Matches dashboardMaxWidth for consistent layout in the shared window
    private let monitorMaxWidth: CGFloat = 1100

    public var body: some View {
        GeometryReader { geometry in
            let isCompactLayout = geometry.size.width < dashboardCompactLayoutThreshold

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
                            videoRewritingSection
                                .padding(.bottom, 40)
                            processResourceSummarySection(isCompactLayout: isCompactLayout)

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
        }
        .task {
            await viewModel.startMonitoring()
        }
        .onAppear {
            installScrollMonitorIfNeeded()
            ProcessCPUMonitor.shared.setConsumerVisible(.systemMonitor, isVisible: true)
            DashboardViewModel.recordSystemMonitorOpened(
                coordinator: coordinator,
                source: "dashboard_window"
            )
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
    @State private var isHoveringHelp = false
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

            // Right side: Live indicator + Help + Settings button
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

                Button(action: {
                    DashboardViewModel.recordHelpOpened(
                        coordinator: coordinator,
                        source: "system_monitor_header"
                    )
                    NotificationCenter.default.post(name: .openFeedback, object: nil)
                }) {
                    Image(systemName: "questionmark.circle")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retraceSecondary)
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
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .help("Help")
                .scaleEffect(isHoveringHelp ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isHoveringHelp)
                .onHover { hovering in
                    isHoveringHelp = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                // Settings button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        settingsRotation += 90
                    }
                    DashboardViewModel.recordSystemMonitorSettingsOpened(
                        coordinator: coordinator,
                        source: "monitor_header_settings"
                    )
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
                .help("Settings")
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
        activityMonitorCard(
            model: ocrMonitorCardModel,
            hoveredIndex: $viewModel.hoveredOCRBarIndex
        ) {
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
                    DashboardViewModel.recordSystemMonitorOpenPowerOCRCard(
                        coordinator: coordinator,
                        source: "monitor_paused_warning"
                    )
                    NotificationCenter.default.post(name: .openSettingsPowerOCRCard, object: nil)
                }
                .padding(12)
                .background(Color.orange.opacity(0.05))
            }

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
                    DashboardViewModel.recordSystemMonitorOpenPowerOCRCard(
                        coordinator: coordinator,
                        source: "monitor_ocr_disabled_warning"
                    )
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
                        Text("\(viewModel.ocrQueueDepth) frames queued. Go to System Settings to increase your OCR Priority.")
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
                    DashboardViewModel.recordSystemMonitorOpenPowerOCRPriority(
                        coordinator: coordinator,
                        source: "monitor_backlog_nudge"
                    )
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
    }

    private var videoRewritingSection: some View {
        activityMonitorCard(
            model: videoRewritingCardModel,
            hoveredIndex: $viewModel.hoveredRewriteBarIndex
        ) {
            EmptyView()
        }
    }

    private var ocrMonitorCardModel: ActivityMonitorCardModel {
        ActivityMonitorCardModel(
            icon: "text.viewfinder",
            title: "OCR Processing",
            statusText: viewModel.ocrStatusBadgeText,
            statusColor: viewModel.ocrStatusColor,
            metricTitle: "Frames processed",
            history: viewModel.ocrProcessingHistory,
            completedLast30Minutes: viewModel.ocrProcessedLast30Min,
            completedLabel: "processed",
            activeCount: viewModel.ocrProcessingCount,
            activeLabel: "processing",
            pendingCount: viewModel.ocrPendingCount,
            pendingLabel: "pending",
            queueDepth: viewModel.ocrQueueDepth,
            etaText: viewModel.ocrEtaText,
            etaSuffixText: viewModel.ocrEtaSuffixText,
            backlogAxisLabel: "backlog"
        )
    }

    private var videoRewritingCardModel: ActivityMonitorCardModel {
        ActivityMonitorCardModel(
            icon: "film.stack",
            title: "Video Rewriting",
            statusText: viewModel.rewriteStatusBadgeText,
            statusColor: viewModel.rewriteStatusColor,
            metricTitle: "Frames rewritten",
            history: viewModel.rewriteHistory,
            completedLast30Minutes: viewModel.rewrittenLast30Min,
            completedLabel: "rewritten",
            activeCount: viewModel.rewriteProcessingCount,
            activeLabel: "rewriting",
            pendingCount: viewModel.rewritePendingCount,
            pendingLabel: "queued",
            queueDepth: viewModel.rewriteQueueDepth,
            etaText: viewModel.rewriteEtaText,
            etaSuffixText: viewModel.rewriteEtaSuffixText,
            backlogAxisLabel: "queue"
        )
    }

    private func activityMonitorCard<Footer: View>(
        model: ActivityMonitorCardModel,
        hoveredIndex: Binding<Int?>,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: model.icon)
                    .font(.retraceCallout)
                    .foregroundColor(.retraceSecondary)
                Text(model.title)
                    .font(.retraceCalloutBold)
                    .foregroundColor(.retracePrimary)

                Spacer()
                statusBadge(text: model.statusText, color: model.statusColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
                .background(Color.white.opacity(0.06))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(model.metricTitle)
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

                ActivityBarChart(
                    dataPoints: model.history,
                    pendingCount: model.pendingCount,
                    processingCount: model.activeCount,
                    completedTint: model.completedTint,
                    activeTint: model.activeTint,
                    pendingTint: model.pendingTint,
                    backlogLabel: model.backlogAxisLabel,
                    hoveredIndex: hoveredIndex
                )
                .frame(height: 140)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)

            Divider()
                .background(Color.white.opacity(0.06))

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("\(model.completedLast30Minutes)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(model.completedTint)
                    if model.isIdle {
                        Text("\(model.completedLabel) in the last 30 minutes")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                    } else {
                        Text(model.completedLabel)
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                    }
                }

                if model.activeCount > 0 {
                    Circle()
                        .fill(Color.retraceSecondary.opacity(0.3))
                        .frame(width: 3, height: 3)

                    HStack(spacing: 4) {
                        Text("\(model.activeCount)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(model.activeTint)
                        Text(model.activeLabel)
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                    }
                }

                if model.pendingCount > 0 {
                    HStack(spacing: 16) {
                        Circle()
                            .fill(Color.retraceSecondary.opacity(0.3))
                            .frame(width: 3, height: 3)

                        HStack(spacing: 4) {
                            Text("\(model.pendingCount)")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(model.pendingTint)
                            Text(model.pendingLabel)
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.7))
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
                }

                Spacer()

                if model.queueDepth > 0,
                   let etaText = model.etaText,
                   let etaSuffixText = model.etaSuffixText {
                    HStack(spacing: 4) {
                        Text(etaText)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.retracePrimary)
                        Text(etaSuffixText)
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.7))
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: model.pendingCount > 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: model.queueDepth > 0)

            footer()
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

    private func processResourceSummarySection(isCompactLayout: Bool) -> some View {
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

            Group {
                if isCompactLayout {
                    VStack(alignment: .leading, spacing: 12) {
                        processCPUSummarySection
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        processMemorySummarySection
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        processCPUSummarySection
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        processMemorySummarySection
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
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
            isRowsScrollEnabled: isCPUScrollEnabled,
            showsOCRBacklogAttribution: viewModel.shouldShowOCRBacklogAttribution
        )
    }

    private var processMemorySummarySection: some View {
        ProcessMemorySummaryCard(
            onRowsHoverChanged: { hovering in
                scrollLatch.updateHover(memory: hovering)
            },
            isRowsScrollEnabled: isMemoryScrollEnabled,
            showsOCRBacklogAttribution: viewModel.shouldShowOCRBacklogAttribution
        )
    }

    private func statusBadge(text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
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

private struct ActivityMonitorCardModel {
    let icon: String
    let title: String
    let statusText: String
    let statusColor: Color
    let metricTitle: String
    let history: [ProcessingDataPoint]
    let completedLast30Minutes: Int
    let completedLabel: String
    let activeCount: Int
    let activeLabel: String
    let pendingCount: Int
    let pendingLabel: String
    let queueDepth: Int
    let etaText: String?
    let etaSuffixText: String?
    let completedTint: Color = .retraceAccent
    let activeTint: Color = .green
    let pendingTint: Color = .orange
    let backlogAxisLabel: String

    var isIdle: Bool {
        queueDepth == 0
    }
}

// MARK: - Processing Bar Chart

struct ActivityBarChart: View {
    struct LayoutMetrics {
        let chartHeight: CGFloat
        let chartWidth: CGFloat
        let barWidth: CGFloat
        let backlogWidth: CGFloat
        let separatorWidth: CGFloat
        let totalBacklogBarCount: Int
        let visibleBacklogBarCount: Int
    }

    let dataPoints: [ProcessingDataPoint]
    let pendingCount: Int
    let processingCount: Int
    let completedTint: Color
    let activeTint: Color
    let pendingTint: Color
    let backlogLabel: String
    @Binding var hoveredIndex: Int?

    // Backlog hover state
    @State private var isHoveringBacklog = false

    // Cap for each backlog bar and maximum number of visible backlog bars.
    private let backlogBarCap = 100
    private let maxVisibleBacklogBars = 10
    private let tooltipEstimatedHeight: CGFloat = 56
    private let tooltipGapAboveBar: CGFloat = 8
    private let tooltipTopOverflowAllowance: CGFloat = 14
    private let tooltipBubbleWidth: CGFloat = 60
    private let tooltipHorizontalOverflowAllowance: CGFloat = 20
    private let tooltipPointerInset: CGFloat = 14
    private let backlogTransitionAnimation = Animation.spring(response: 0.28, dampingFraction: 0.84)

    var body: some View {
        GeometryReader { geometry in
            let xAxisHeight: CGFloat = 1  // x-axis line
            let labelPadding: CGFloat = 4  // space between axis and labels
            let labelHeight: CGFloat = 12  // actual label height
            let backlogSpacing: CGFloat = 2
            let spacing: CGFloat = 1
            let singleBarWidth: CGFloat = 28
            let metrics = Self.layoutMetrics(
                totalWidth: geometry.size.width,
                totalHeight: geometry.size.height,
                dataPointCount: dataPoints.count,
                pendingCount: pendingCount,
                backlogBarCap: backlogBarCap,
                maxVisibleBacklogBars: maxVisibleBacklogBars,
                xAxisHeight: xAxisHeight,
                labelPadding: labelPadding,
                labelHeight: labelHeight,
                singleBarWidth: singleBarWidth,
                backlogSpacing: backlogSpacing,
                spacing: spacing
            )
            let chartHeight = metrics.chartHeight
            let chartWidth = metrics.chartWidth
            let barWidth = metrics.barWidth
            let backlogWidth = metrics.backlogWidth
            let separatorWidth = metrics.separatorWidth
            let totalBacklogBarCount = metrics.totalBacklogBarCount
            let visibleBacklogBarCount = metrics.visibleBacklogBarCount
            let hasBacklog = totalBacklogBarCount > 0

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
                                    isHovered: isHovered
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
                                .fill(completedTint.opacity(isHovered ? 0.9 : 0.6))
                                .frame(width: barWidth, height: max(barHeight, point.count > 0 ? 3 : 1))
                                .animation(.easeOut(duration: 0.15), value: isHovered)
                            }
                        }
                    }
                    .frame(width: chartWidth, height: chartHeight, alignment: .bottom)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredIndex = Self.hoveredDataIndex(
                                at: location.x,
                                dataPointCount: dataPoints.count,
                                barWidth: barWidth,
                                spacing: spacing
                            )
                        case .ended:
                            hoveredIndex = nil
                        }
                    }
                    .overlay(alignment: .top) {
                        // Tooltip for main chart (index >= 0 excludes backlog hover which uses -1)
                        if let index = hoveredIndex, index >= 0, index < dataPoints.count {
                            let point = dataPoints[index]
                            let isLive = index == lastIndex
                            let xPosition = CGFloat(index) * (barWidth + spacing) + barWidth / 2
                            let tooltipCenterX = Self.clampedTooltipCenterX(
                                anchorX: xPosition,
                                containerWidth: chartWidth,
                                tooltipWidth: tooltipBubbleWidth,
                                horizontalOverflowAllowance: tooltipHorizontalOverflowAllowance
                            )
                            let yPosition = mainTooltipYOffset(
                                for: point,
                                isLive: isLive,
                                maxValue: maxValue,
                                chartHeight: chartHeight
                            )

                            tooltipView(
                                for: point,
                                isLive: isLive,
                                pointerOffset: Self.tooltipPointerOffset(
                                    bubbleCenterX: tooltipCenterX,
                                    anchorX: xPosition,
                                    tooltipWidth: tooltipBubbleWidth,
                                    pointerInset: tooltipPointerInset
                                )
                            )
                                .offset(x: tooltipCenterX - (chartWidth / 2), y: yPosition)
                                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
                                .animation(.spring(response: 0.18, dampingFraction: 0.86), value: hoveredIndex)
                        }
                    }

                    // Separator and backlog section
                    if hasBacklog {
                        HStack(alignment: .bottom, spacing: 0) {
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
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .trailing))
                        ))
                    }
                }
                .frame(height: chartHeight)
                .animation(backlogTransitionAnimation, value: hasBacklog)
                .animation(backlogTransitionAnimation, value: visibleBacklogBarCount)

                // X-axis line (spans full width including backlog)
                Rectangle()
                    .fill(Color.retraceSecondary.opacity(0.2))
                    .frame(height: xAxisHeight)

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
                        HStack(spacing: 0) {
                            // Separator space
                            Spacer()
                                .frame(width: separatorWidth)

                            // Backlog label
                            Text(backlogLabel)
                                .foregroundColor(pendingTint.opacity(0.7))
                                .frame(width: backlogWidth)
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.retraceSecondary.opacity(0.5))
                .padding(.top, labelPadding)
                .frame(height: labelPadding + labelHeight)
                .animation(backlogTransitionAnimation, value: hasBacklog)
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
        isHovered: Bool
    ) -> some View {
        let processedNormalized = CGFloat(processedCount) / CGFloat(maxValue)
        let processingNormalized = CGFloat(processingCount) / CGFloat(maxValue)
        let processedHeight = height * processedNormalized
        let processingHeight = height * processingNormalized

        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Processing portion (green) - on top
                if processingCount > 0 {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 2,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 2
                    )
                    .fill(activeTint.opacity(isHovered ? 1.0 : 0.8))
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
                    .fill(completedTint.opacity(isHovered ? 0.9 : 0.6))
                    .frame(width: barWidth, height: max(processedHeight, processedCount > 0 ? 3 : 1))
                }
            }
        }
        .frame(width: barWidth, height: height, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: isHovered)
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
                .fill(pendingTint.opacity(isHoveringBacklog ? 0.8 : 0.5))
                .frame(width: singleBarWidth, height: max(barHeight, 6))
            }
        }
        .frame(width: totalWidth, height: height, alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringBacklog = hovering
            hoveredIndex = hovering ? -1 : nil // Use -1 for backlog
        }
        .animation(backlogTransitionAnimation, value: visibleBarCount)
        .animation(backlogTransitionAnimation, value: pendingCount > 0)
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

    private func tooltipView(
        for point: ProcessingDataPoint,
        isLive: Bool,
        pointerOffset: CGFloat
    ) -> some View {
        floatingTooltip(pointerOffset: pointerOffset, width: tooltipBubbleWidth) {
            VStack(spacing: 5) {
                Text(isLive ? "LIVE NOW" : point.minute.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.45)
                    .foregroundColor(.white.opacity(0.72))

                HStack(spacing: 6) {
                    tooltipMetricChip(
                        text: "\(point.count)",
                        tint: completedTint
                    )
                    if isLive && processingCount > 0 {
                        tooltipMetricChip(
                            text: "+\(processingCount)",
                            tint: activeTint
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
                .foregroundColor(pendingTint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(pendingTint.opacity(0.18))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(pendingTint.opacity(0.35), lineWidth: 1)
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
    private func floatingTooltip<Content: View>(
        pointerOffset: CGFloat = 0,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity)
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
                .frame(width: width)

            TooltipPointer()
                .fill(Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.98))
                .frame(width: 12, height: 7)
                .overlay(
                    TooltipPointer()
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )
                .offset(x: pointerOffset, y: -1)
        }
        .frame(width: width)
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

    static func hoveredDataIndex(
        at x: CGFloat,
        dataPointCount: Int,
        barWidth: CGFloat,
        spacing: CGFloat
    ) -> Int? {
        guard dataPointCount > 0 else { return nil }

        let stride = barWidth + spacing
        guard stride > 0 else { return 0 }

        let index = Int(floor((max(0, x) + (spacing / 2)) / stride))
        return min(max(index, 0), dataPointCount - 1)
    }

    static func layoutMetrics(
        totalWidth: CGFloat,
        totalHeight: CGFloat,
        dataPointCount: Int,
        pendingCount: Int,
        backlogBarCap: Int,
        maxVisibleBacklogBars: Int,
        xAxisHeight: CGFloat,
        labelPadding: CGFloat,
        labelHeight: CGFloat,
        singleBarWidth: CGFloat,
        backlogSpacing: CGFloat,
        spacing: CGFloat
    ) -> LayoutMetrics {
        let clampedTotalWidth = max(totalWidth, 0)
        let clampedTotalHeight = max(totalHeight, 0)
        let bottomAreaHeight = xAxisHeight + labelPadding + labelHeight
        // Clamp chart dimensions so transient window/layout states never feed
        // negative or non-finite frame sizes back into SwiftUI.
        let chartHeight = max(clampedTotalHeight - bottomAreaHeight, 0)

        let hasBacklog = pendingCount > 0
        let totalBacklogBarCount = hasBacklog ? max(1, Int(ceil(Double(pendingCount) / Double(backlogBarCap)))) : 0
        let visibleBacklogBarCount = min(totalBacklogBarCount, maxVisibleBacklogBars)
        let separatorWidth: CGFloat = hasBacklog ? 12 : 0
        let backlogWidth: CGFloat = hasBacklog
            ? CGFloat(visibleBacklogBarCount) * singleBarWidth
                + CGFloat(max(0, visibleBacklogBarCount - 1)) * backlogSpacing
                + 12
            : 0
        let chartWidth = max(clampedTotalWidth - backlogWidth - separatorWidth, 0)
        let safeDataPointCount = max(dataPointCount, 1)
        let spacingWidth = CGFloat(max(dataPointCount - 1, 0)) * spacing
        let barWidth = max(3, max(chartWidth - spacingWidth, 0) / CGFloat(safeDataPointCount))

        return LayoutMetrics(
            chartHeight: chartHeight,
            chartWidth: chartWidth,
            barWidth: barWidth,
            backlogWidth: backlogWidth,
            separatorWidth: separatorWidth,
            totalBacklogBarCount: totalBacklogBarCount,
            visibleBacklogBarCount: visibleBacklogBarCount
        )
    }

    static func clampedTooltipCenterX(
        anchorX: CGFloat,
        containerWidth: CGFloat,
        tooltipWidth: CGFloat,
        horizontalOverflowAllowance: CGFloat
    ) -> CGFloat {
        let halfWidth = tooltipWidth / 2
        let minCenter = halfWidth - horizontalOverflowAllowance
        let maxCenter = max(minCenter, containerWidth - halfWidth + horizontalOverflowAllowance)
        return min(max(anchorX, minCenter), maxCenter)
    }

    static func tooltipPointerOffset(
        bubbleCenterX: CGFloat,
        anchorX: CGFloat,
        tooltipWidth: CGFloat,
        pointerInset: CGFloat
    ) -> CGFloat {
        let maxPointerOffset = max(0, (tooltipWidth / 2) - pointerInset)
        return min(max(anchorX - bubbleCenterX, -maxPointerOffset), maxPointerOffset)
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
        static let ocrPendingCount = "debugSystemMonitorPendingCount"
        static let ocrProcessingCount = "debugSystemMonitorProcessingCount"
        static let ocrQueueDepth = "debugSystemMonitorQueueDepth"
    }
    #endif

    // Queue stats
    @Published var ocrQueueDepth: Int = 0
    @Published var ocrPendingCount: Int = 0
    @Published var ocrProcessingCount: Int = 0
    @Published var rewriteQueueDepth: Int = 0
    @Published var rewritePendingCount: Int = 0
    @Published var rewriteProcessingCount: Int = 0
    @Published var ocrTotalProcessed: Int = 0
    @Published var totalRewritten: Int = 0
    @Published var ocrEnabled: Bool = true
    @Published var isPausedForBattery: Bool = false
    @Published var powerSource: PowerStateMonitor.PowerSource = .unknown
    @Published var ocrProcessingLevel: Int = 3
    @Published var pauseOnBatterySetting: Bool = false
    @Published var pauseOnLowPowerModeSetting: Bool = false
    @Published var isRecordingActive: Bool = false

    // Chart data
    @Published var ocrProcessingHistory: [ProcessingDataPoint] = []
    @Published var rewriteHistory: [ProcessingDataPoint] = []
    @Published var hoveredOCRBarIndex: Int? = nil
    @Published var hoveredRewriteBarIndex: Int? = nil

    // Animation
    @Published var pulseScale: CGFloat = 1.0
    @Published var pulseOpacity: Double = 1.0

    private let coordinator: AppCoordinator
    private var monitoringTask: Task<Void, Never>?

    // Track frames processed per minute using minute key (minutes since epoch)
    // Using Int key instead of Date to avoid timezone/rounding issues at minute boundaries
    private var ocrMinuteProcessingCounts: [Int: Int] = [:]
    private var rewriteMinuteCounts: [Int: Int] = [:]
    private var ocrQueueDepthSamples: [(timestamp: Date, depth: Int)] = []
    private var previousTotalProcessed: Int = 0
    private var previousTotalRewritten: Int = 0
    private let backlogNudgeThreshold = 100
    private let queueDepthSampleWindowSeconds: TimeInterval = 45
    private let minimumQueueTrendWindowSeconds: TimeInterval = 12
    private let queueDepthGrowthEpsilonPerMinute: Double = 0.5

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        initializeHistories()
    }

    /// Convert a Date to a minute key (minutes since epoch)
    private func minuteKey(for date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 60)
    }

    /// Convert a minute key back to a Date (start of that minute)
    private func date(fromMinuteKey key: Int) -> Date {
        Date(timeIntervalSince1970: Double(key) * 60)
    }

    private func initializeHistories() {
        // Create 30 empty data points (one per minute)
        let nowKey = minuteKey(for: Date())
        let emptyHistory = (0..<30).reversed().map { minutesAgo in
            let key = nowKey - minutesAgo
            return ProcessingDataPoint(minute: date(fromMinuteKey: key), count: 0)
        }
        ocrProcessingHistory = emptyHistory
        rewriteHistory = emptyHistory
    }

    /// Total frames processed in the last 30 minutes (sum of history)
    var ocrProcessedLast30Min: Int {
        ocrProcessingHistory.reduce(0) { $0 + $1.count }
    }

    var rewrittenLast30Min: Int {
        rewriteHistory.reduce(0) { $0 + $1.count }
    }

    var ocrStatusColor: Color {
        if !ocrEnabled {
            return .gray
        } else if isPausedForBattery {
            return .orange
        } else if ocrQueueDepth > 0 {
            return .retraceAccent
        } else {
            return .retraceAccent
        }
    }

    var ocrStatusBadgeText: String {
        if !ocrEnabled {
            return "Disabled"
        } else if isPausedForBattery {
            return "Paused"
        } else if ocrQueueDepth > 0 {
            return "Processing"
        } else {
            return "Idle"
        }
    }

    var rewriteStatusColor: Color {
        rewriteQueueDepth > 0 ? .green : .gray
    }

    var rewriteStatusBadgeText: String {
        rewriteQueueDepth > 0 ? "Rewriting" : "Idle"
    }

    private func recentCompletionRateFramesPerMinute(for history: [ProcessingDataPoint]) -> Double? {
        let recentProcessed = history.suffix(5).reduce(0) { $0 + $1.count }
        let minutesOfData = min(5, history.count)
        guard recentProcessed > 0, minutesOfData > 0 else { return nil }
        return Double(recentProcessed) / Double(minutesOfData)
    }

    private var recentQueueDepthChangePerMinute: Double? {
        Self.queueDepthChangePerMinute(
            samples: ocrQueueDepthSamples,
            minimumObservationWindow: minimumQueueTrendWindowSeconds
        )
    }

    private var effectiveOCRDrainRateFramesPerMinute: Double? {
        guard let processingRate = recentCompletionRateFramesPerMinute(for: ocrProcessingHistory) else { return nil }
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
        guard ocrQueueDepth > 0,
              isRecordingActive,
              let queueDepthChange = recentQueueDepthChangePerMinute else {
            return false
        }
        return queueDepthChange > queueDepthGrowthEpsilonPerMinute
    }

    private func etaText(queueDepth: Int, drainRate: Double?) -> String {
        guard queueDepth > 0 else { return "—" }
        guard let drainRate else { return "..." }
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

    var ocrEtaText: String {
        etaText(queueDepth: ocrQueueDepth, drainRate: effectiveOCRDrainRateFramesPerMinute)
    }

    var ocrEtaSuffixText: String {
        if isPausedForBattery || !ocrEnabled {
            return "processing time"
        }
        if isBacklogGrowingAtCurrentRates {
            return "backlog growing"
        }
        return "remaining"
    }

    var rewriteEtaText: String {
        etaText(
            queueDepth: rewriteQueueDepth,
            drainRate: recentCompletionRateFramesPerMinute(for: rewriteHistory)
        )
    }

    var rewriteEtaSuffixText: String {
        "remaining"
    }

    var shouldShowPerformanceNudge: Bool {
        ocrEnabled &&
        !isPausedForBattery &&
        ocrQueueDepth >= backlogNudgeThreshold &&
        ocrProcessingLevel == 3 &&
        !pauseOnBatterySetting &&
        !pauseOnLowPowerModeSetting
    }

    var shouldShowOCRBacklogAttribution: Bool {
        ocrEnabled &&
        !isPausedForBattery &&
        ocrProcessingCount > 0
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
        let nowKey = minuteKey(for: Date())

        if let historicalCounts = try? await coordinator.getFramesProcessedPerMinute(lastMinutes: 30) {
            for (minuteOffset, count) in historicalCounts {
                let key = nowKey - minuteOffset
                ocrMinuteProcessingCounts[key] = count
            }
        }

        if let rewriteCounts = try? await coordinator.getFramesRewrittenPerMinute(lastMinutes: 30) {
            for (minuteOffset, count) in rewriteCounts {
                let key = nowKey - minuteOffset
                rewriteMinuteCounts[key] = count
            }
        }

        updateOCRProcessingHistory()
        updateRewriteHistory()
    }

    private func updateStats() async {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

        // Get queue statistics
        if let stats = await coordinator.getQueueStatistics() {
            ocrQueueDepth = stats.ocrQueueDepth
            ocrPendingCount = stats.ocrPendingCount
            ocrProcessingCount = stats.ocrProcessingCount
            rewriteQueueDepth = stats.rewriteQueueDepth
            rewritePendingCount = stats.rewritePendingCount
            rewriteProcessingCount = stats.rewriteProcessingCount

            // Calculate frames processed since last update
            let newlyProcessed = stats.totalProcessed - previousTotalProcessed
            if previousTotalProcessed > 0 && newlyProcessed > 0 {
                let currentKey = minuteKey(for: Date())
                ocrMinuteProcessingCounts[currentKey, default: 0] += newlyProcessed
            }
            previousTotalProcessed = stats.totalProcessed
            ocrTotalProcessed = stats.totalProcessed

            let newlyRewritten = stats.totalRewritten - previousTotalRewritten
            if previousTotalRewritten > 0 && newlyRewritten > 0 {
                let currentKey = minuteKey(for: Date())
                rewriteMinuteCounts[currentKey, default: 0] += newlyRewritten
            }
            previousTotalRewritten = stats.totalRewritten
            totalRewritten = stats.totalRewritten

            updateOCRProcessingHistory()
            updateRewriteHistory()
        }

        #if DEBUG
        applyDebugQueueOverrides(defaults: defaults)
        #endif
        recordQueueDepthSample(ocrQueueDepth)

        // Get power state
        let powerState = coordinator.getCurrentPowerState()
        powerSource = powerState.source
        isPausedForBattery = powerState.isPaused

        // Get OCR power settings snapshot from defaults to keep the nudge logic aligned
        // with the power configuration shown in Settings.
        let powerSettings = OCRPowerSettingsSnapshot.fromDefaults(defaults)
        ocrEnabled = powerSettings.ocrEnabled
        isRecordingActive = coordinator.statusHolder.status.isRunning
        ocrProcessingLevel = min(max(powerSettings.processingLevel, 1), 5)
        pauseOnBatterySetting = powerSettings.pauseOnBattery
        pauseOnLowPowerModeSetting = powerSettings.pauseOnLowPowerMode
    }

    #if DEBUG
    private func applyDebugQueueOverrides(defaults: UserDefaults) {
        let pendingOverride = (defaults.object(forKey: DebugDefaultsKey.ocrPendingCount) as? NSNumber)?.intValue
        let processingOverride = (defaults.object(forKey: DebugDefaultsKey.ocrProcessingCount) as? NSNumber)?.intValue
        let queueDepthOverride = (defaults.object(forKey: DebugDefaultsKey.ocrQueueDepth) as? NSNumber)?.intValue

        if let pendingOverride {
            ocrPendingCount = max(pendingOverride, 0)
        }

        if let processingOverride {
            ocrProcessingCount = max(processingOverride, 0)
        }

        if let queueDepthOverride {
            ocrQueueDepth = max(queueDepthOverride, 0)
        } else if pendingOverride != nil || processingOverride != nil {
            ocrQueueDepth = max(ocrPendingCount + ocrProcessingCount, 0)
        }
    }
    #endif

    private func updateOCRProcessingHistory() {
        let nowKey = minuteKey(for: Date())

        var newHistory: [ProcessingDataPoint] = []

        for minutesAgo in (0..<30).reversed() {
            let key = nowKey - minutesAgo
            let count = ocrMinuteProcessingCounts[key] ?? 0
            newHistory.append(ProcessingDataPoint(minute: date(fromMinuteKey: key), count: count))
        }

        ocrProcessingHistory = newHistory

        let cutoffKey = nowKey - 31
        ocrMinuteProcessingCounts = ocrMinuteProcessingCounts.filter { $0.key > cutoffKey }
    }

    private func updateRewriteHistory() {
        let nowKey = minuteKey(for: Date())

        var newHistory: [ProcessingDataPoint] = []

        for minutesAgo in (0..<30).reversed() {
            let key = nowKey - minutesAgo
            let count = rewriteMinuteCounts[key] ?? 0
            newHistory.append(ProcessingDataPoint(minute: date(fromMinuteKey: key), count: count))
        }

        rewriteHistory = newHistory

        let cutoffKey = nowKey - 31
        rewriteMinuteCounts = rewriteMinuteCounts.filter { $0.key > cutoffKey }
    }

    private func recordQueueDepthSample(_ depth: Int, at timestamp: Date = Date()) {
        ocrQueueDepthSamples.append((timestamp: timestamp, depth: max(depth, 0)))
        let cutoff = timestamp.addingTimeInterval(-queueDepthSampleWindowSeconds)
        ocrQueueDepthSamples.removeAll { $0.timestamp < cutoff }
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
