import SwiftUI
import Shared
import App
import Processing

/// System monitor view showing background task status
public struct SystemMonitorView: View {
    @StateObject private var viewModel: SystemMonitorViewModel

    public init(coordinator: AppCoordinator) {
        _viewModel = StateObject(wrappedValue: SystemMonitorViewModel(coordinator: coordinator))
    }

    public var body: some View {
        ZStack {
            // Background matching dashboard - extends under titlebar
            backgroundView
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 24)

                // Main content
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        // OCR Processing Section
                        ocrProcessingSection

                        // Future sections placeholder
                        // - Data Transfers
                        // - Migrations
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
        }
        .task {
            await viewModel.startMonitoring()
        }
        .onDisappear {
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
                    NotificationCenter.default.post(name: .openSettings, object: nil)
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
            // Section header
            HStack {
                Image(systemName: "text.viewfinder")
                    .font(.retraceCallout)
                    .foregroundColor(.retraceSecondary)
                Text("OCR Processing")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.retracePrimary)

                Spacer()

                // Status badge
                statusBadge
            }

            // Content card
            VStack(spacing: 0) {
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
                    .frame(height: 100)
                }
                .padding(16)

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
                            Text(viewModel.isPausedForBattery ? "worth of processing" : "remaining")
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
                        Text("Processing paused — connect to power to resume or ")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary)
                        + Text("change this in Settings")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceAccent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NotificationCenter.default.post(name: .openSettingsPower, object: nil)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.05))
                }
            }
            .background(Color.white.opacity(0.02))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
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
}

// MARK: - Processing Bar Chart

struct ProcessingBarChart: View {
    let dataPoints: [ProcessingDataPoint]
    let pendingCount: Int
    let processingCount: Int
    @Binding var hoveredIndex: Int?

    // Backlog hover state
    @State private var isHoveringBacklog = false

    // Cap for each backlog bar
    private let backlogBarCap = 100

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
            // Calculate number of backlog bars needed (each bar shows up to 150)
            let backlogBarCount = hasBacklog ? max(1, Int(ceil(Double(pendingCount) / Double(backlogBarCap)))) : 0
            let singleBarWidth: CGFloat = 28
            let backlogSpacing: CGFloat = 2
            let backlogWidth: CGFloat = hasBacklog ? CGFloat(backlogBarCount) * singleBarWidth + CGFloat(max(0, backlogBarCount - 1)) * backlogSpacing + 12 : 0
            let separatorWidth: CGFloat = hasBacklog ? 12 : 0
            let chartWidth = totalWidth - backlogWidth - separatorWidth

            let spacing: CGFloat = 1
            let barWidth = max(3, (chartWidth - CGFloat(dataPoints.count - 1) * spacing) / CGFloat(dataPoints.count))

            // For live bar: total = processed this minute + currently processing
            let lastIndex = dataPoints.count - 1
            let liveProcessedCount = dataPoints.last?.count ?? 0
            let liveTotalForScaling = liveProcessedCount + processingCount

            // Scale based on max of historical data, live total, or backlog cap (150)
            // Backlog bars are capped at 150, so use that for scaling
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

                            tooltipView(for: point, isLive: isLive)
                                .offset(x: clampTooltipOffset(xPosition, in: chartWidth), y: 0)
                                .transition(.opacity)
                                .animation(.easeOut(duration: 0.1), value: hoveredIndex)
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
                            barCount: backlogBarCount,
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
        barCount: Int,
        singleBarWidth: CGFloat,
        spacing: CGFloat,
        totalWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { barIndex in
                // FIFO: rightmost bars drain first, so we fill from right to left
                // barIndex 0 = leftmost bar (last to drain), barIndex N-1 = rightmost bar (first to drain)
                // Reverse the index for calculation: rightmost bar shows remainder, leftmost bars are full
                let reverseIndex = barCount - 1 - barIndex
                let previousBarsTotal = reverseIndex * backlogBarCap
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
                    .offset(y: 4)
            }
        }
    }

    // MARK: - Tooltips

    private func tooltipView(for point: ProcessingDataPoint, isLive: Bool) -> some View {
        HStack(spacing: 4) {
            Text("\(point.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.retraceAccent)
            if isLive && processingCount > 0 {
                Text("+\(processingCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)
            }
            if isLive {
                Text("now")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.retraceSecondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.85))
        )
    }

    private func backlogTooltipView(pendingCount: Int) -> some View {
        Text("\(pendingCount)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.85))
            )
    }

    private func clampTooltipOffset(_ x: CGFloat, in width: CGFloat) -> CGFloat {
        let center = width / 2
        let offset = x - center
        let tooltipHalfWidth: CGFloat = 30
        let maxOffset = (width / 2) - tooltipHalfWidth
        return min(max(offset, -maxOffset), maxOffset)
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
    // Queue stats
    @Published var queueDepth: Int = 0
    @Published var pendingCount: Int = 0       // Frames waiting (status 0)
    @Published var processingCount: Int = 0    // Frames being processed (status 1)
    @Published var totalProcessed: Int = 0
    @Published var ocrEnabled: Bool = true
    @Published var isPausedForBattery: Bool = false
    @Published var powerSource: PowerStateMonitor.PowerSource = .unknown

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
    private var previousTotalProcessed: Int = 0

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

    var etaText: String {
        guard queueDepth > 0 else { return "—" }

        // Calculate average processing rate from recent history
        let recentProcessed = processingHistory.suffix(5).reduce(0) { $0 + $1.count }
        let minutesOfData = min(5, processingHistory.count)

        guard recentProcessed > 0, minutesOfData > 0 else {
            return "..."
        }

        let framesPerMinute = Double(recentProcessed) / Double(minutesOfData)
        let minutesRemaining = Double(queueDepth) / framesPerMinute

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

    func startMonitoring() async {
        // Start pulse animation
        startPulseAnimation()

        // Load historical data on first load
        await loadHistoricalData()

        monitoringTask = Task {
            while !Task.isCancelled {
                await updateStats()
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
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
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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

        // Get power state
        let powerState = coordinator.getCurrentPowerState()
        powerSource = powerState.source
        isPausedForBattery = powerState.isPaused

        // Get OCR enabled state
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        ocrEnabled = defaults.object(forKey: "ocrEnabled") as? Bool ?? true
    }

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
}
