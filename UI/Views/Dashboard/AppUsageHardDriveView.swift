import SwiftUI
import AppKit
import Shared

/// Treemap visualization for app usage - apps shown as blocks proportional to usage time
struct AppUsageHardDriveView: View {
    let apps: [AppUsageData]
    let totalTime: TimeInterval
    var onAppTapped: ((AppUsageData) -> Void)? = nil
    @State private var hoveredApp: AppUsageData? = nil

    private let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Treemap visualization
            treemapVisualization
                .frame(minHeight: 280)

            // Hover tooltip (shown below)
            if let app = hoveredApp {
                tooltipView(for: app)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.15), value: hoveredApp?.id)
    }

    private var treemapVisualization: some View {
        GeometryReader { geometry in
            let layout = calculateTreemap(
                apps: Array(apps.prefix(12)),
                in: CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.size.height)
            )

            ZStack(alignment: .topLeading) {
                // App blocks - use ForEach with explicit positioning
                ForEach(layout, id: \.app.id) { item in
                    appBlock(item: item)
                        .offset(x: item.rect.minX, y: item.rect.minY)
                }
            }
        }
    }

    private func appBlock(item: TreemapItem) -> some View {
        let appColor = Color.segmentColor(for: item.app.appBundleID)
        let isHovered = hoveredApp?.id == item.app.id

        return ZStack {
            // Block background
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [
                            appColor.opacity(isHovered ? 0.6 : 0.35),
                            appColor.opacity(isHovered ? 0.4 : 0.2)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(appColor.opacity(isHovered ? 0.9 : 0.5), lineWidth: isHovered ? 2 : 1)
                )

            // App icon (scaled based on block size)
            VStack(spacing: 4) {
                AppIconView(bundleID: item.app.appBundleID, size: iconSize(for: item.rect.size))

                // Show app name if block is large enough
                if item.rect.width > 80 && item.rect.height > 60 {
                    Text(item.app.appName)
                        .font(.system(size: min(12, item.rect.width / 8), weight: .medium))
                        .foregroundColor(.retracePrimary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: item.rect.width - 12)
                }
            }
        }
        .frame(width: item.rect.width, height: item.rect.height)
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .shadow(color: isHovered ? appColor.opacity(0.4) : .clear, radius: 12, x: 0, y: 4)
        .zIndex(isHovered ? 100 : 0)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredApp = hovering ? item.app : nil
            }
        }
        .onTapGesture {
            onAppTapped?(item.app)
        }
    }

    private func iconSize(for blockSize: CGSize) -> CGFloat {
        let minDimension = min(blockSize.width, blockSize.height)
        return max(16, min(48, minDimension * 0.4))
    }

    private func tooltipView(for app: AppUsageData) -> some View {
        HStack(spacing: 12) {
            AppIconView(bundleID: app.appBundleID, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.retraceCalloutBold)
                    .foregroundColor(.retracePrimary)

                HStack(spacing: 8) {
                    Text(formatDuration(app.duration))
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceAccent)

                    Text("•")
                        .foregroundColor(.retraceSecondary.opacity(0.5))

                    Text(String(format: "%.1f%%", app.percentage * 100))
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)

                    Text("•")
                        .foregroundColor(.retraceSecondary.opacity(0.5))

                    Text("\(app.sessionCount) session\(app.sessionCount == 1 ? "" : "s")")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                }
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - Squarified Treemap Algorithm with Proportion-Preserving Fitting

    private struct TreemapItem {
        let app: AppUsageData
        let rect: CGRect
        let targetArea: CGFloat  // Store target area for validation
    }

    private func calculateTreemap(apps: [AppUsageData], in rect: CGRect) -> [TreemapItem] {
        guard !apps.isEmpty else { return [] }

        // Normalize percentages
        let totalPercentage = apps.reduce(0.0) { $0 + $1.percentage }
        guard totalPercentage > 0 else { return [] }

        // Create normalized values (areas relative to container)
        let containerRect = CGRect(
            x: rect.minX + gap / 2,
            y: rect.minY + gap / 2,
            width: rect.width - gap,
            height: rect.height - gap
        )
        let totalArea = containerRect.width * containerRect.height
        var normalizedApps = apps.map { app -> (app: AppUsageData, area: CGFloat) in
            let normalizedArea = CGFloat(app.percentage / totalPercentage) * totalArea
            return (app: app, area: normalizedArea)
        }

        // Sort by area descending for better layout
        normalizedApps.sort { $0.area > $1.area }

        // Calculate layout using squarified algorithm
        let items = squarifiedLayout(apps: normalizedApps, in: containerRect)

        // Final pass: clamp to container bounds (safety for floating point errors)
        return items.map { item in
            var rect = item.rect
            rect.size.width = min(rect.width, containerRect.maxX - rect.minX)
            rect.size.height = min(rect.height, containerRect.maxY - rect.minY)
            rect.size.width = max(1, rect.width)
            rect.size.height = max(1, rect.height)
            return TreemapItem(app: item.app, rect: rect, targetArea: item.targetArea)
        }
    }

    /// Main squarified treemap layout - processes apps recursively in strips
    private func squarifiedLayout(
        apps: [(app: AppUsageData, area: CGFloat)],
        in rect: CGRect
    ) -> [TreemapItem] {
        guard !apps.isEmpty else { return [] }
        guard rect.width > 0 && rect.height > 0 else { return [] }

        var items: [TreemapItem] = []
        var remainingRect = rect
        var remainingApps = apps
        var remainingArea = apps.reduce(0.0) { $0 + $1.area }

        while !remainingApps.isEmpty && remainingRect.width > 0 && remainingRect.height > 0 {
            // Determine layout direction based on aspect ratio
            let layoutHorizontally = remainingRect.width >= remainingRect.height

            // Find optimal row using squarified algorithm
            let (rowApps, rowArea) = findOptimalRow(
                apps: remainingApps,
                rect: remainingRect,
                layoutHorizontally: layoutHorizontally
            )

            guard !rowApps.isEmpty else { break }

            // Calculate the strip dimension based on actual area ratio
            let stripFraction = rowArea / remainingArea
            let stripItems: [TreemapItem]

            if layoutHorizontally {
                // Horizontal strip across top
                let stripHeight = remainingRect.height * stripFraction
                let stripRect = CGRect(
                    x: remainingRect.minX,
                    y: remainingRect.minY,
                    width: remainingRect.width,
                    height: stripHeight
                )
                stripItems = layoutStrip(apps: rowApps, in: stripRect, horizontal: true)

                // Update remaining rect
                remainingRect = CGRect(
                    x: remainingRect.minX,
                    y: remainingRect.minY + stripHeight,
                    width: remainingRect.width,
                    height: remainingRect.height - stripHeight
                )
            } else {
                // Vertical strip on left
                let stripWidth = remainingRect.width * stripFraction
                let stripRect = CGRect(
                    x: remainingRect.minX,
                    y: remainingRect.minY,
                    width: stripWidth,
                    height: remainingRect.height
                )
                stripItems = layoutStrip(apps: rowApps, in: stripRect, horizontal: false)

                // Update remaining rect
                remainingRect = CGRect(
                    x: remainingRect.minX + stripWidth,
                    y: remainingRect.minY,
                    width: remainingRect.width - stripWidth,
                    height: remainingRect.height
                )
            }

            items.append(contentsOf: stripItems)
            remainingApps.removeFirst(rowApps.count)
            remainingArea -= rowArea
        }

        return items
    }

    /// Find the optimal row of apps that produces the best aspect ratios
    private func findOptimalRow(
        apps: [(app: AppUsageData, area: CGFloat)],
        rect: CGRect,
        layoutHorizontally: Bool
    ) -> ([(app: AppUsageData, area: CGFloat)], CGFloat) {
        guard !apps.isEmpty else { return ([], 0) }

        let totalArea = apps.reduce(0.0) { $0 + $1.area }
        let fixedSide = layoutHorizontally ? rect.width : rect.height
        let variableSide = layoutHorizontally ? rect.height : rect.width

        var bestRow: [(app: AppUsageData, area: CGFloat)] = []
        var bestRowArea: CGFloat = 0
        var bestWorstRatio: CGFloat = .infinity

        var currentRow: [(app: AppUsageData, area: CGFloat)] = []
        var currentRowArea: CGFloat = 0

        for app in apps {
            let testRow = currentRow + [app]
            let testRowArea = currentRowArea + app.area

            // Calculate strip thickness for this row
            let stripFraction = testRowArea / totalArea
            let stripThickness = variableSide * stripFraction

            guard stripThickness > 0 else { continue }

            // Calculate worst aspect ratio in this row
            var worstRatio: CGFloat = 0
            for item in testRow {
                let itemFraction = item.area / testRowArea
                let itemLength = fixedSide * itemFraction
                let aspectRatio = max(itemLength / stripThickness, stripThickness / itemLength)
                worstRatio = max(worstRatio, aspectRatio)
            }

            if worstRatio <= bestWorstRatio || bestRow.isEmpty {
                bestRow = testRow
                bestRowArea = testRowArea
                bestWorstRatio = worstRatio
                currentRow = testRow
                currentRowArea = testRowArea
            } else {
                // Adding more items makes it worse, stop here
                break
            }
        }

        // Ensure we take at least one item
        if bestRow.isEmpty && !apps.isEmpty {
            bestRow = [apps[0]]
            bestRowArea = apps[0].area
        }

        return (bestRow, bestRowArea)
    }

    /// Layout a strip of apps either horizontally or vertically
    private func layoutStrip(
        apps: [(app: AppUsageData, area: CGFloat)],
        in rect: CGRect,
        horizontal: Bool
    ) -> [TreemapItem] {
        guard !apps.isEmpty else { return [] }

        let totalArea = apps.reduce(0.0) { $0 + $1.area }
        guard totalArea > 0 else { return [] }

        var items: [TreemapItem] = []

        if horizontal {
            // Items laid out left-to-right within the strip
            var currentX = rect.minX
            let stripHeight = rect.height

            for (index, app) in apps.enumerated() {
                let itemFraction = app.area / totalArea
                let itemWidth: CGFloat

                if index == apps.count - 1 {
                    // Last item fills remaining space (fixes floating point accumulation)
                    itemWidth = rect.maxX - currentX
                } else {
                    itemWidth = rect.width * itemFraction
                }

                let itemRect = CGRect(
                    x: currentX + gap / 2,
                    y: rect.minY + gap / 2,
                    width: max(1, itemWidth - gap),
                    height: max(1, stripHeight - gap)
                )

                items.append(TreemapItem(app: app.app, rect: itemRect, targetArea: app.area))
                currentX += itemWidth
            }
        } else {
            // Items laid out top-to-bottom within the strip
            var currentY = rect.minY
            let stripWidth = rect.width

            for (index, app) in apps.enumerated() {
                let itemFraction = app.area / totalArea
                let itemHeight: CGFloat

                if index == apps.count - 1 {
                    // Last item fills remaining space (fixes floating point accumulation)
                    itemHeight = rect.maxY - currentY
                } else {
                    itemHeight = rect.height * itemFraction
                }

                let itemRect = CGRect(
                    x: rect.minX + gap / 2,
                    y: currentY + gap / 2,
                    width: max(1, stripWidth - gap),
                    height: max(1, itemHeight - gap)
                )

                items.append(TreemapItem(app: app.app, rect: itemRect, targetArea: app.area))
                currentY += itemHeight
            }
        }

        return items
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AppUsageHardDriveView_Previews: PreviewProvider {
    static var previews: some View {
        AppUsageHardDriveView(
            apps: [
                AppUsageData(appBundleID: "com.apple.Safari", appName: "Safari", duration: 7200, sessionCount: 15, percentage: 0.35),
                AppUsageData(appBundleID: "com.microsoft.VSCode", appName: "VS Code", duration: 5400, sessionCount: 8, percentage: 0.26),
                AppUsageData(appBundleID: "com.apple.MobileSMS", appName: "Messages", duration: 2400, sessionCount: 20, percentage: 0.12),
                AppUsageData(appBundleID: "com.spotify.client", appName: "Spotify", duration: 1800, sessionCount: 5, percentage: 0.09),
                AppUsageData(appBundleID: "com.apple.finder", appName: "Finder", duration: 1200, sessionCount: 30, percentage: 0.06),
                AppUsageData(appBundleID: "com.apple.mail", appName: "Mail", duration: 900, sessionCount: 12, percentage: 0.04),
                AppUsageData(appBundleID: "com.slack.Slack", appName: "Slack", duration: 600, sessionCount: 8, percentage: 0.03),
                AppUsageData(appBundleID: "com.apple.Notes", appName: "Notes", duration: 500, sessionCount: 5, percentage: 0.025),
                AppUsageData(appBundleID: "com.apple.Terminal", appName: "Terminal", duration: 400, sessionCount: 10, percentage: 0.02),
            ],
            totalTime: 20000
        )
        .frame(width: 700, height: 400)
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
