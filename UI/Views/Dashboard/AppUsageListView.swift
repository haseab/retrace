import SwiftUI
import AppKit
import Shared

// MARK: - App Usage Layout Size

/// Responsive layout sizes for app usage list
/// Matches the dashboard stat card scaling
enum AppUsageLayoutSize {
    case normal      // < 1100px
    case large       // 1100-1400px
    case extraLarge  // 1400-1700px
    case massive     // > 1700px

    static func from(width: CGFloat) -> AppUsageLayoutSize {
        if width > 1700 {
            return .massive
        } else if width > 1400 {
            return .extraLarge
        } else if width > 1100 {
            return .large
        } else {
            return .normal
        }
    }

    // MARK: - Icon Sizes

    var appIconSize: CGFloat {
        switch self {
        case .normal: return 32
        case .large: return 38
        case .extraLarge: return 44
        case .massive: return 50
        }
    }

    // MARK: - Text Fonts

    var rankFont: Font {
        switch self {
        case .normal: return .retraceCaption2Bold
        case .large: return .retraceCaptionBold
        case .extraLarge: return .retraceCalloutBold
        case .massive: return .retraceBodyBold
        }
    }

    var appNameFont: Font {
        switch self {
        case .normal: return .retraceCalloutMedium
        case .large: return .retraceBodyMedium
        case .extraLarge: return .retraceHeadline
        case .massive: return .retraceTitle3
        }
    }

    var sessionFont: Font {
        switch self {
        case .normal: return .retraceCaption2
        case .large: return .retraceCaption
        case .extraLarge: return .retraceCallout
        case .massive: return .retraceBody
        }
    }

    var durationFont: Font {
        switch self {
        case .normal: return .retraceCalloutBold
        case .large: return .retraceBodyBold
        case .extraLarge: return .retraceHeadline
        case .massive: return .retraceTitle3
        }
    }

    var percentageFont: Font {
        switch self {
        case .normal: return .retraceCaption2Medium
        case .large: return .retraceCaptionMedium
        case .extraLarge: return .retraceCalloutMedium
        case .massive: return .retraceBodyMedium
        }
    }

    // MARK: - Window Row Fonts (slightly smaller than app fonts)

    var windowNameFont: Font {
        switch self {
        case .normal: return .retraceCaption2Medium
        case .large: return .retraceCaptionMedium
        case .extraLarge: return .retraceCalloutMedium
        case .massive: return .retraceBodyMedium
        }
    }

    var windowDurationFont: Font {
        switch self {
        case .normal: return .retraceCaption2Bold
        case .large: return .retraceCaptionBold
        case .extraLarge: return .retraceCalloutBold
        case .massive: return .retraceBodyBold
        }
    }

    // MARK: - Spacing & Padding

    var rowSpacing: CGFloat {
        switch self {
        case .normal: return 12
        case .large: return 14
        case .extraLarge: return 16
        case .massive: return 18
        }
    }

    var rankWidth: CGFloat {
        switch self {
        case .normal: return 20
        case .large: return 24
        case .extraLarge: return 28
        case .massive: return 32
        }
    }

    var progressBarWidth: CGFloat {
        switch self {
        case .normal: return 120
        case .large: return 140
        case .extraLarge: return 160
        case .massive: return 180
        }
    }

    var progressBarHeight: CGFloat {
        switch self {
        case .normal: return 6
        case .large: return 7
        case .extraLarge: return 8
        case .massive: return 9
        }
    }

    var durationWidth: CGFloat {
        switch self {
        case .normal: return 70
        case .large: return 85
        case .extraLarge: return 100
        case .massive: return 115
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .normal: return 12
        case .large: return 14
        case .extraLarge: return 16
        case .massive: return 18
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .normal: return 10
        case .large: return 12
        case .extraLarge: return 14
        case .massive: return 16
        }
    }

    var windowRowIndent: CGFloat {
        switch self {
        case .normal: return 52
        case .large: return 62
        case .extraLarge: return 72
        case .massive: return 82
        }
    }
}

// MARK: - Scroll Affordance

/// A subtle inner shadow at the bottom of a container that suggests scrollable content continues
private struct ScrollAffordance: View {
    var height: CGFloat = 24
    var color: Color = .black

    var body: some View {
        VStack {
            Spacer()
            LinearGradient(
                colors: [
                    color.opacity(0),
                    color.opacity(0.6),
                    color.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }
}

/// List-style view for app usage data with expandable window details
struct AppUsageListView: View {
    let apps: [AppUsageData]
    let totalTime: TimeInterval
    var layoutSize: AppUsageLayoutSize = .normal
    var loadWindowUsage: ((String) async -> [WindowUsageData])? = nil
    var onWindowTapped: ((AppUsageData, WindowUsageData) -> Void)? = nil

    @State private var hoveredAppIndex: Int? = nil
    @State private var hoveredWindowKey: String? = nil
    @State private var displayedCount: Int = 20
    @State private var isHoveringLoadMore: Bool = false
    @State private var expandedAppBundleID: String? = nil
    @State private var windowUsageCache: [String: [WindowUsageData]] = [:]
    @State private var loadingWindows: Set<String> = []
    @State private var displayedWindowCounts: [String: Int] = [:]
    @State private var isHoveringWindowLoadMore: String? = nil

    private let loadMoreIncrement: Int = 10
    private let windowLoadIncrement: Int = 10
    private let initialWindowCount: Int = 10

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(Array(apps.prefix(displayedCount).enumerated()), id: \.offset) { index, app in
                        VStack(spacing: 0) {
                            appUsageRow(index: index, app: app, layoutSize: layoutSize)

                            // Expandable window rows
                            if expandedAppBundleID == app.appBundleID {
                                windowRowsSection(for: app, layoutSize: layoutSize)
                            }
                        }
                    }

                    // Load More button (only show if there are more apps to display)
                    if displayedCount < apps.count {
                        loadMoreButton
                    }
                }
                .padding(16)
                .padding(.bottom, 16) // Extra padding for scroll affordance
            }

            // Inner shadow scroll affordance
            ScrollAffordance(height: 40, color: Color.retraceBackground)
        }
    }

    // MARK: - Window Rows Section

    @ViewBuilder
    private func windowRowsSection(for app: AppUsageData, layoutSize: AppUsageLayoutSize) -> some View {
        let windows = windowUsageCache[app.appBundleID] ?? []
        let isLoading = loadingWindows.contains(app.appBundleID)
        let appColor = Color.segmentColor(for: app.appBundleID)
        let displayedWindowCount = displayedWindowCounts[app.appBundleID] ?? initialWindowCount
        let displayedWindows = Array(windows.prefix(displayedWindowCount))
        let hasMoreWindows = windows.count > displayedWindowCount

        VStack(spacing: 4) {
            if isLoading {
                HStack {
                    Spacer()
                    SpinnerView(size: 14, lineWidth: 2, color: .retraceSecondary)
                    Text("Loading windows...")
                        .font(layoutSize.windowNameFont)
                        .foregroundColor(.retraceSecondary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.leading, layoutSize.windowRowIndent)
            } else if windows.isEmpty {
                HStack {
                    Text("No window data available")
                        .font(layoutSize.windowNameFont)
                        .foregroundColor(.retraceSecondary.opacity(0.6))
                        .italic()
                }
                .padding(.vertical, 8)
                .padding(.leading, layoutSize.windowRowIndent)
            } else {
                ForEach(displayedWindows) { window in
                    windowRow(window: window, app: app, appColor: appColor, layoutSize: layoutSize)
                }

                // Load More Windows button
                if hasMoreWindows {
                    windowLoadMoreButton(for: app, remainingCount: windows.count - displayedWindowCount, layoutSize: layoutSize)
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Window Load More Button

    private func windowLoadMoreButton(for app: AppUsageData, remainingCount: Int, layoutSize: AppUsageLayoutSize) -> some View {
        let isHovering = isHoveringWindowLoadMore == app.appBundleID

        return Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                let currentCount = displayedWindowCounts[app.appBundleID] ?? initialWindowCount
                displayedWindowCounts[app.appBundleID] = currentCount + windowLoadIncrement
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 10, weight: .medium))
                Text("Load More")
                    .font(layoutSize.windowNameFont)
                Text("(\(min(windowLoadIncrement, remainingCount)) more)")
                    .font(.system(size: 10))
                    .foregroundColor(.retraceSecondary.opacity(0.7))
            }
            .foregroundColor(.retraceSecondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.white.opacity(0.06) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.leading, layoutSize.windowRowIndent)
        .padding(.top, 4)
        .onHover { hovering in
            isHoveringWindowLoadMore = hovering ? app.appBundleID : nil
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Window Row

    private func windowRow(window: WindowUsageData, app: AppUsageData, appColor: Color, layoutSize: AppUsageLayoutSize) -> some View {
        let windowKey = "\(app.appBundleID)_\(window.id)"
        let isHovered = hoveredWindowKey == windowKey

        return HStack(spacing: layoutSize.rowSpacing) {
            // Indent spacer + tree connector visual
            HStack(spacing: 4) {
                Spacer()
                    .frame(width: layoutSize.rankWidth)

                // Vertical line connector
                Rectangle()
                    .fill(appColor.opacity(0.3))
                    .frame(width: 2, height: 16)

                // Horizontal connector
                Rectangle()
                    .fill(appColor.opacity(0.3))
                    .frame(width: 8, height: 2)
            }

            // Window name
            Text(window.displayName)
                .font(layoutSize.windowNameFont)
                .foregroundColor(.retracePrimary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Mini progress bar
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.03))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(appColor.opacity(0.5))
                        .frame(width: max(geometry.size.width * window.percentage, 4))
                }
            }
            .frame(width: layoutSize.progressBarWidth * 0.6, height: layoutSize.progressBarHeight - 1)

            // Duration and percentage
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatDuration(window.duration))
                    .font(layoutSize.windowDurationFont)
                    .foregroundColor(.retracePrimary.opacity(0.85))

                Text(String(format: "%.1f%%", window.percentage * 100))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.7))
            }
            .frame(width: layoutSize.durationWidth * 0.8, alignment: .trailing)
        }
        .padding(.horizontal, layoutSize.horizontalPadding)
        .padding(.vertical, layoutSize.verticalPadding * 0.6)
        .padding(.leading, layoutSize.windowRowIndent - layoutSize.rankWidth - 14)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.white.opacity(0.03) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredWindowKey = hovering ? windowKey : nil
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            onWindowTapped?(app, window)
        }
    }

    private var loadMoreButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                displayedCount = min(displayedCount + loadMoreIncrement, apps.count)
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.retraceCaption2Medium)
                Text("Load More")
                    .font(.retraceCaption2Medium)
                Text("(\(min(loadMoreIncrement, apps.count - displayedCount)) more)")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary.opacity(0.7))
            }
            .foregroundColor(.retraceSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHoveringLoadMore ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHoveringLoadMore = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .padding(.top, 8)
    }

    private func appUsageRow(index: Int, app: AppUsageData, layoutSize: AppUsageLayoutSize) -> some View {
        let isHovered = hoveredAppIndex == index
        let isExpanded = expandedAppBundleID == app.appBundleID
        let appColor = Color.segmentColor(for: app.appBundleID)

        return HStack(spacing: layoutSize.rowSpacing) {
            // Expand/collapse chevron
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.retraceSecondary.opacity(0.6))
                .frame(width: 12)

            // App icon
            AppIconView(bundleID: app.appBundleID, size: layoutSize.appIconSize)

            // App info
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(layoutSize.appNameFont)
                    .foregroundColor(.retracePrimary)
                    .lineLimit(1)

                Text(app.uniqueItemLabel)
                    .font(layoutSize.sessionFont)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.05))

                    // Progress
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [appColor.opacity(0.8), appColor.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * app.percentage, 8))
                }
            }
            .frame(width: layoutSize.progressBarWidth, height: layoutSize.progressBarHeight)

            // Duration and percentage
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatDuration(app.duration))
                    .font(layoutSize.durationFont)
                    .foregroundColor(.retracePrimary)

                Text(String(format: "%.1f%%", app.percentage * 100))
                    .font(layoutSize.percentageFont)
                    .foregroundColor(.retraceSecondary)
            }
            .frame(width: layoutSize.durationWidth, alignment: .trailing)
        }
        .padding(.horizontal, layoutSize.horizontalPadding)
        .padding(.vertical, layoutSize.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered || isExpanded ? Color.white.opacity(0.05) : Color.clear)
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredAppIndex = hovering ? index : nil
            }
        }
        .onTapGesture {
            toggleExpansion(for: app)
        }
    }

    // MARK: - Expansion Logic

    private func toggleExpansion(for app: AppUsageData) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedAppBundleID == app.appBundleID {
                // Collapse
                expandedAppBundleID = nil
                // Reset displayed window count for next expansion
                displayedWindowCounts[app.appBundleID] = nil
            } else {
                // Expand
                expandedAppBundleID = app.appBundleID
                // Initialize displayed window count
                displayedWindowCounts[app.appBundleID] = initialWindowCount

                // Load window data if not cached
                if windowUsageCache[app.appBundleID] == nil && !loadingWindows.contains(app.appBundleID) {
                    loadWindowData(for: app)
                }
            }
        }
    }

    private func loadWindowData(for app: AppUsageData) {
        guard let loader = loadWindowUsage else { return }

        loadingWindows.insert(app.appBundleID)

        Task {
            let windows = await loader(app.appBundleID)
            await MainActor.run {
                windowUsageCache[app.appBundleID] = windows
                loadingWindows.remove(app.appBundleID)
            }
        }
    }

    private var totalRow: some View {
        HStack(spacing: 12) {
            // Clock icon instead of rank
            Image(systemName: "clock.fill")
                .font(.system(size: 14))
                .foregroundColor(.retraceSecondary)
                .frame(width: 20)

            // Total icon placeholder (same size as app icons)
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 32, height: 32)
                Image(systemName: "sum")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.retraceSecondary)
            }

            // Label
            VStack(alignment: .leading, spacing: 2) {
                Text("Total Screen Time")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)
                    .lineLimit(1)

                Text("This week")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            // Total duration
            Text(formatDuration(totalTime))
                .font(.retraceCalloutBold)
                .foregroundColor(.retracePrimary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
        )
        .padding(.top, 8)
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
