import SwiftUI
import Shared

/// A compact line graph for displaying 7-day metrics within dashboard stat cards
/// Features:
/// - 7 data points connected by a line
/// - Date labels (MM/DD) on x-axis
/// - Y-axis labels with min/mid/max values
/// - Optional gradient fill under the line
/// - Hover detection with tooltips showing values
/// - Interactive dots that highlight on hover
struct MiniLineGraphView: View {
    let dataPoints: [DailyDataPoint]
    let lineColor: Color
    let showGradientFill: Bool
    let showYAxis: Bool
    let valueFormatter: ((Int64) -> String)?

    @State private var hoveredIndex: Int? = nil
    @State private var isHovering = false

    init(
        dataPoints: [DailyDataPoint],
        lineColor: Color = .retraceAccent,
        showGradientFill: Bool = false,
        showYAxis: Bool = true,
        valueFormatter: ((Int64) -> String)? = nil
    ) {
        self.dataPoints = dataPoints
        self.lineColor = lineColor
        self.showGradientFill = showGradientFill
        self.showYAxis = showYAxis
        self.valueFormatter = valueFormatter
    }

    // MARK: - Computed Properties for Y-Axis

    private var maxValue: Int64 {
        dataPoints.map(\.value).max() ?? 0
    }

    private var minValue: Int64 {
        dataPoints.map(\.value).min() ?? 0
    }

    private var midValue: Int64 {
        (maxValue + minValue) / 2
    }

    /// Format Y-axis label - uses custom formatter if provided, otherwise uses compact format
    private func formatYAxisLabel(_ value: Int64) -> String {
        if let formatter = valueFormatter {
            return formatter(value)
        }
        return formatValueCompact(value)
    }

    /// Compact format for Y-axis labels (shorter than tooltip format)
    private func formatValueCompact(_ value: Int64) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fG", Double(value) / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "%.0fM", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let labelHeight: CGFloat = 14
            let yAxisWidth: CGFloat = showYAxis ? 32 : 0
            let graphWidth = width - yAxisWidth
            let graphHeight = height - labelHeight

            HStack(spacing: 0) {
                // Y-axis labels (left side)
                if showYAxis {
                    yAxisLabels(height: graphHeight)
                        .frame(width: yAxisWidth, height: graphHeight)
                }

                VStack(spacing: 0) {
                    // Graph area
                    ZStack {
                        // Horizontal grid lines for Y-axis reference
                        if showYAxis && maxValue > 0 {
                            yAxisGridLines(height: graphHeight)
                        }

                        // Gradient fill under the line (optional)
                        if showGradientFill && !dataPoints.isEmpty {
                            fillPath(width: graphWidth, height: graphHeight)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            lineColor.opacity(0.3),
                                            lineColor.opacity(0.05),
                                            lineColor.opacity(0.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }

                        // The line graph
                        if !dataPoints.isEmpty {
                            linePath(width: graphWidth, height: graphHeight)
                                .stroke(
                                    lineColor,
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                                )
                        }

                        // Data point dots
                        ForEach(Array(dataPoints.enumerated()), id: \.offset) { index, point in
                            let x = xPosition(for: index, width: graphWidth)
                            let y = yPosition(for: point.value, height: graphHeight)
                            let isHovered = hoveredIndex == index
                            let isLast = index == dataPoints.count - 1

                            Circle()
                                .fill(lineColor)
                                .frame(width: isHovered ? 10 : (isLast ? 6 : 4), height: isHovered ? 10 : (isLast ? 6 : 4))
                                .opacity(isHovered || isLast ? 1.0 : 0.6)
                                .position(x: x, y: y)
                                .animation(.easeOut(duration: 0.15), value: isHovered)
                        }

                        // Tooltip (shown above hovered point)
                        if let index = hoveredIndex, index < dataPoints.count {
                            let point = dataPoints[index]
                            let x = xPosition(for: index, width: graphWidth)
                            let y = yPosition(for: point.value, height: graphHeight)

                            tooltipView(for: point, at: CGPoint(x: x, y: y), in: graphWidth)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                .animation(.easeOut(duration: 0.15), value: hoveredIndex)
                        }

                        // Invisible hover detection areas
                        HStack(spacing: 0) {
                            ForEach(Array(dataPoints.enumerated()), id: \.offset) { index, _ in
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .onHover { hovering in
                                        if hovering {
                                            hoveredIndex = index
                                            isHovering = true
                                        } else if hoveredIndex == index {
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                if hoveredIndex == index {
                                                    hoveredIndex = nil
                                                    isHovering = false
                                                }
                                            }
                                        }
                                    }
                            }
                        }
                    }
                    .frame(height: graphHeight)

                    // X-axis labels (date labels)
                    HStack(spacing: 0) {
                        ForEach(Array(dataPoints.enumerated()), id: \.offset) { index, point in
                            Text(point.label)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundColor(hoveredIndex == index ? lineColor : .retraceSecondary.opacity(0.6))
                                .frame(maxWidth: .infinity)
                                .animation(.easeOut(duration: 0.15), value: hoveredIndex)
                        }
                    }
                    .frame(height: labelHeight)
                }
            }
        }
    }

    // MARK: - Y-Axis Views

    /// Y-axis labels showing max, mid, and min values
    private func yAxisLabels(height: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            // Max value label (top)
            Text(formatYAxisLabel(maxValue))
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(.retraceSecondary.opacity(0.6))

            Spacer()

            // Mid value label (center) - only show if there's a meaningful range
            if maxValue > minValue {
                Text(formatYAxisLabel(midValue))
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(.retraceSecondary.opacity(0.5))
            }

            Spacer()

            // Min value label (bottom) - only show if different from max
            if maxValue > minValue || maxValue == 0 {
                Text(formatYAxisLabel(minValue))
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(.retraceSecondary.opacity(0.6))
            }
        }
        .padding(.trailing, 4)
        .padding(.vertical, 4)
    }

    /// Subtle horizontal grid lines for Y-axis reference
    private func yAxisGridLines(height: CGFloat) -> some View {
        let topPadding: CGFloat = 8
        let availableHeight = height - topPadding

        return ZStack {
            // Top line (max value)
            Path { path in
                path.move(to: CGPoint(x: 0, y: topPadding))
                path.addLine(to: CGPoint(x: 1000, y: topPadding))
            }
            .stroke(Color.white.opacity(0.05), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))

            // Middle line (mid value)
            Path { path in
                let midY = topPadding + availableHeight / 2
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: 1000, y: midY))
            }
            .stroke(Color.white.opacity(0.03), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))

            // Bottom line (min/zero value)
            Path { path in
                path.move(to: CGPoint(x: 0, y: height))
                path.addLine(to: CGPoint(x: 1000, y: height))
            }
            .stroke(Color.white.opacity(0.05), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
        }
    }

    // MARK: - Tooltip

    @ViewBuilder
    private func tooltipView(for point: DailyDataPoint, at position: CGPoint, in totalWidth: CGFloat) -> some View {
        let formattedValue = valueFormatter?(point.value) ?? formatValue(point.value)

        VStack(spacing: 2) {
            Text(formattedValue)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(lineColor.opacity(0.5), lineWidth: 1)
                )
        )
        .position(x: clampTooltipX(position.x, in: totalWidth), y: position.y - 20)
    }

    /// Clamp tooltip X position to keep it within bounds
    private func clampTooltipX(_ x: CGFloat, in width: CGFloat) -> CGFloat {
        let tooltipHalfWidth: CGFloat = 30
        return min(max(x, tooltipHalfWidth), width - tooltipHalfWidth)
    }

    /// Default value formatter
    private func formatValue(_ value: Int64) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fGB", Double(value) / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "%.1fMB", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    // MARK: - Path Helpers

    private func linePath(width: CGFloat, height: CGFloat) -> Path {
        guard dataPoints.count > 1 else {
            return Path()
        }

        var path = Path()
        let points = dataPoints.enumerated().map { index, point in
            CGPoint(
                x: xPosition(for: index, width: width),
                y: yPosition(for: point.value, height: height)
            )
        }

        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }

        return path
    }

    private func fillPath(width: CGFloat, height: CGFloat) -> Path {
        guard dataPoints.count > 1 else {
            return Path()
        }

        var path = Path()
        let points = dataPoints.enumerated().map { index, point in
            CGPoint(
                x: xPosition(for: index, width: width),
                y: yPosition(for: point.value, height: height)
            )
        }

        // Start at bottom-left
        path.move(to: CGPoint(x: points[0].x, y: height))

        // Line to first data point
        path.addLine(to: points[0])

        // Add all data points
        for point in points.dropFirst() {
            path.addLine(to: point)
        }

        // Line to bottom-right and close
        path.addLine(to: CGPoint(x: points.last!.x, y: height))
        path.closeSubpath()

        return path
    }

    private func xPosition(for index: Int, width: CGFloat) -> CGFloat {
        guard dataPoints.count > 1 else {
            return width / 2
        }

        let padding: CGFloat = 10
        let availableWidth = width - (padding * 2)
        let step = availableWidth / CGFloat(dataPoints.count - 1)
        return padding + (step * CGFloat(index))
    }

    private func yPosition(for value: Int64, height: CGFloat) -> CGFloat {
        let maxValue = dataPoints.map(\.value).max() ?? 1
        let topPadding: CGFloat = 8
        let availableHeight = height - topPadding

        // All values zero - put at bottom
        guard maxValue > 0 else {
            return height
        }

        // Normalize: 0 = bottom (height), maxValue = top (topPadding)
        let normalizedValue = CGFloat(value) / CGFloat(maxValue)
        return height - (normalizedValue * availableHeight)
    }
}

// MARK: - Preview

#if DEBUG
struct MiniLineGraphView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Sample with data
            MiniLineGraphView(
                dataPoints: [
                    DailyDataPoint(date: Date().addingTimeInterval(-6 * 86400), value: 5),
                    DailyDataPoint(date: Date().addingTimeInterval(-5 * 86400), value: 12),
                    DailyDataPoint(date: Date().addingTimeInterval(-4 * 86400), value: 8),
                    DailyDataPoint(date: Date().addingTimeInterval(-3 * 86400), value: 15),
                    DailyDataPoint(date: Date().addingTimeInterval(-2 * 86400), value: 10),
                    DailyDataPoint(date: Date().addingTimeInterval(-1 * 86400), value: 18),
                    DailyDataPoint(date: Date(), value: 14)
                ],
                lineColor: .purple,
                showGradientFill: true
            )
            .frame(height: 80)
            .padding()
            .background(Color.black.opacity(0.8))
            .cornerRadius(12)

            // Sample with storage-like values
            MiniLineGraphView(
                dataPoints: [
                    DailyDataPoint(date: Date().addingTimeInterval(-6 * 86400), value: 1_500_000_000),
                    DailyDataPoint(date: Date().addingTimeInterval(-5 * 86400), value: 1_800_000_000),
                    DailyDataPoint(date: Date().addingTimeInterval(-4 * 86400), value: 2_100_000_000),
                    DailyDataPoint(date: Date().addingTimeInterval(-3 * 86400), value: 2_300_000_000),
                    DailyDataPoint(date: Date().addingTimeInterval(-2 * 86400), value: 2_600_000_000),
                    DailyDataPoint(date: Date().addingTimeInterval(-1 * 86400), value: 2_900_000_000),
                    DailyDataPoint(date: Date(), value: 3_200_000_000)
                ],
                lineColor: .cyan,
                showGradientFill: true
            )
            .frame(height: 80)
            .padding()
            .background(Color.black.opacity(0.8))
            .cornerRadius(12)

            // Sample with zero values
            MiniLineGraphView(
                dataPoints: [
                    DailyDataPoint(date: Date().addingTimeInterval(-6 * 86400), value: 0),
                    DailyDataPoint(date: Date().addingTimeInterval(-5 * 86400), value: 0),
                    DailyDataPoint(date: Date().addingTimeInterval(-4 * 86400), value: 0),
                    DailyDataPoint(date: Date().addingTimeInterval(-3 * 86400), value: 0),
                    DailyDataPoint(date: Date().addingTimeInterval(-2 * 86400), value: 0),
                    DailyDataPoint(date: Date().addingTimeInterval(-1 * 86400), value: 0),
                    DailyDataPoint(date: Date(), value: 0)
                ],
                lineColor: .blue
            )
            .frame(height: 80)
            .padding()
            .background(Color.black.opacity(0.8))
            .cornerRadius(12)
        }
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
#endif
