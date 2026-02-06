import SwiftUI
import AppKit
import Shared

// MARK: - App Usage Layout Size

/// Fixed layout size for app usage list
/// Content stays at a consistent size; the dashboard centers when the window is wide
enum AppUsageLayoutSize {
    case normal

    static func from(width: CGFloat) -> AppUsageLayoutSize {
        return .normal
    }

    // MARK: - Icon Sizes

    var appIconSize: CGFloat { 32 }

    // MARK: - Text Fonts

    var rankFont: Font { .retraceCaption2Bold }
    var appNameFont: Font { .retraceCalloutMedium }
    var sessionFont: Font { .retraceCaption2 }
    var durationFont: Font { .retraceCalloutBold }
    var percentageFont: Font { .retraceCaption2Medium }

    // MARK: - Window Row Fonts (slightly smaller than app fonts)

    var windowNameFont: Font { .retraceCaptionMedium }
    var windowDurationFont: Font { .retraceCaptionBold }

    // MARK: - Spacing & Padding

    var rowSpacing: CGFloat { 12 }
    var rankWidth: CGFloat { 20 }
    var progressBarWidth: CGFloat { 120 }
    var progressBarHeight: CGFloat { 6 }
    var durationWidth: CGFloat { 70 }
    var horizontalPadding: CGFloat { 12 }
    var verticalPadding: CGFloat { 10 }
    var windowRowIndent: CGFloat { 52 }
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
    var loadWindowUsage: ((String) async -> [WindowUsageData])? = nil  // For websites (domain aggregation)
    var loadTabsForDomain: ((String, String) async -> [WindowUsageData])? = nil  // (bundleID, domain) -> tabs for that domain
    var onWindowTapped: ((AppUsageData, WindowUsageData) -> Void)? = nil

    @State private var hoveredAppIndex: Int? = nil
    @State private var hoveredWindowKey: String? = nil
    @State private var displayedCount: Int = 20
    @State private var isHoveringLoadMore: Bool = false
    @State private var expandedAppBundleID: String? = nil
    @State private var windowUsageCache: [String: [WindowUsageData]] = [:]  // Website/domain data
    @State private var domainTabsCache: [String: [WindowUsageData]] = [:]   // Domain-specific tabs (key: "bundleID_domain")
    @State private var loadingWindows: Set<String> = []
    @State private var loadingDomainTabs: Set<String> = []  // Loading state for domain tabs
    @State private var displayedWindowCounts: [String: Int] = [:]
    @State private var displayedDomainTabCounts: [String: Int] = [:]  // Display count for domain tabs
    @State private var isHoveringWindowLoadMore: String? = nil
    @State private var expandedDomainKey: String? = nil  // Track which domain is expanded (key: "bundleID_domain")

    private let loadMoreIncrement: Int = 10
    private let windowLoadIncrement: Int = 10
    private let initialWindowCount: Int = 10
    private let initialDomainTabCount: Int = 5

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(Array(apps.prefix(displayedCount).enumerated()), id: \.offset) { index, app in
                        VStack(spacing: 0) {
                            appUsageRow(index: index, app: app, layoutSize: layoutSize)

                            // Expandable window rows - content clips within its container
                            if expandedAppBundleID == app.appBundleID {
                                windowRowsSection(for: app, layoutSize: layoutSize, isBrowser: app.isBrowser)
                                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                            }
                        }
                        .clipped()
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

    /// Get the appropriate data source for browser breakdown (always websites view for browsers)
    private func getWindowData(for app: AppUsageData) -> (windows: [WindowUsageData], isLoading: Bool, showAsTab: Bool) {
        return (
            windows: windowUsageCache[app.appBundleID] ?? [],
            isLoading: loadingWindows.contains(app.appBundleID),
            showAsTab: false
        )
    }

    @ViewBuilder
    private func windowRowsSection(for app: AppUsageData, layoutSize: AppUsageLayoutSize, isBrowser: Bool = false) -> some View {
        let data = getWindowData(for: app)
        let windows = data.windows
        let isLoading = data.isLoading
        let showAsTab = data.showAsTab

        let appColor = Color.segmentColor(for: app.appBundleID)
        let displayedWindowCount = displayedWindowCounts[app.appBundleID] ?? initialWindowCount
        let displayedWindows = Array(windows.prefix(displayedWindowCount))
        let hasMoreWindows = windows.count > displayedWindowCount

        VStack(spacing: 4) {
            if isLoading {
                HStack {
                    Spacer()
                    SpinnerView(size: 14, lineWidth: 2, color: .retraceSecondary)
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
                ForEach(Array(displayedWindows.enumerated()), id: \.element.id) { index, window in
                    // For browsers, show websites view with expandable rows for domain tabs
                    if isBrowser {
                        VStack(spacing: 0) {
                            websiteRow(
                                window: window,
                                app: app,
                                appColor: appColor,
                                layoutSize: layoutSize,
                                rowIndex: index
                            )

                            // Nested tabs for this domain (only for actual websites, not window fallbacks)
                            if window.isWebsite {
                                let domainKey = "\(app.appBundleID)_\(window.displayName)"
                                if expandedDomainKey == domainKey {
                                    domainTabsSection(for: app, domain: window.displayName, appColor: appColor, layoutSize: layoutSize)
                                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                                }
                            }
                        }
                    } else {
                        windowRow(
                            window: window,
                            app: app,
                            appColor: appColor,
                            layoutSize: layoutSize,
                            rowIndex: index,
                            isBrowser: isBrowser,
                            showAsTab: showAsTab
                        )
                    }
                }

                // Load More Windows button
                if hasMoreWindows {
                    windowLoadMoreButton(for: app, remainingCount: windows.count - displayedWindowCount, layoutSize: layoutSize)
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .clipped()
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

    private func windowRow(window: WindowUsageData, app: AppUsageData, appColor: Color, layoutSize: AppUsageLayoutSize, rowIndex: Int, isBrowser: Bool = false, showAsTab: Bool = false) -> some View {
        let windowKey = "\(app.appBundleID)_\(window.id)"
        let isHovered = hoveredWindowKey == windowKey

        // For tabs view, extract domain from browserUrl for favicon
        let faviconDomain: String = {
            if showAsTab, let url = window.browserUrl, !url.isEmpty {
                // Extract domain from URL
                if let urlObj = URL(string: url), let host = urlObj.host {
                    return host
                }
            }
            return window.displayName
        }()

        return HStack(spacing: layoutSize.rowSpacing) {
            // Indent spacer + favicon/app icon indicator
            HStack(spacing: 8) {
                Spacer()
                    .frame(width: layoutSize.rankWidth)

                // Favicon for browser URLs, app icon for regular windows
                if isBrowser {
                    FaviconView(domain: faviconDomain, size: 20, fallbackColor: appColor)
                } else {
                    AppIconView(bundleID: app.appBundleID, size: 20)
                }
            }

            // Window/tab name with optional URL subtitle for tabs
            VStack(alignment: .leading, spacing: 2) {
                Text(window.displayName)
                    .font(layoutSize.windowNameFont)
                    .foregroundColor(.retracePrimary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Show URL as subtitle in tabs view
                if showAsTab, let url = window.browserUrl, !url.isEmpty {
                    Text(url)
                        .font(.system(size: 10))
                        .foregroundColor(.retraceSecondary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

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
        .padding(.vertical, layoutSize.verticalPadding * (showAsTab ? 0.7 : 0.6))
        .padding(.leading, layoutSize.windowRowIndent - layoutSize.rankWidth - 14)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.white.opacity(0.03) : Color.clear)
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
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

    // MARK: - Website Row (Expandable) or Window Fallback Row

    /// Website row in "Websites" mode that can expand to show tabs for that domain
    /// For window fallbacks (isWebsite=false), shows app icon instead of favicon and doesn't expand
    private func websiteRow(window: WindowUsageData, app: AppUsageData, appColor: Color, layoutSize: AppUsageLayoutSize, rowIndex: Int) -> some View {
        let domainKey = "\(app.appBundleID)_\(window.displayName)"
        let isExpanded = window.isWebsite && expandedDomainKey == domainKey
        let isHovered = hoveredWindowKey == domainKey

        return HStack(spacing: layoutSize.rowSpacing) {
            // Expand/collapse chevron - only show for websites (not window fallbacks)
            if window.isWebsite {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.retraceSecondary.opacity(0.5))
                    .frame(width: 10)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            } else {
                // Spacer for alignment when no chevron
                Spacer()
                    .frame(width: 10)
            }

            // Indent spacer + icon (favicon for websites, app icon for window fallbacks)
            HStack(spacing: 8) {
                Spacer()
                    .frame(width: layoutSize.rankWidth - 14)

                if window.isWebsite {
                    FaviconView(domain: window.displayName, size: 20, fallbackColor: appColor)
                } else {
                    // Window fallback: use app icon
                    AppIconView(bundleID: app.appBundleID, size: 20)
                }
            }

            // Domain name or window name
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
                .fill(isHovered || isExpanded ? Color.white.opacity(0.03) : Color.clear)
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredWindowKey = hovering ? domainKey : nil
            }
            if hovering {
                NSCursor.pointingHand.push()
                // Preload domain tabs on hover (only for websites)
                if window.isWebsite && domainTabsCache[domainKey] == nil && !loadingDomainTabs.contains(domainKey) {
                    loadDomainTabs(for: app, domain: window.displayName)
                }
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            if window.isWebsite {
                // Websites expand to show tabs
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedDomainKey == domainKey {
                        expandedDomainKey = nil
                    } else {
                        expandedDomainKey = domainKey
                        // Load domain tabs if not cached
                        if domainTabsCache[domainKey] == nil && !loadingDomainTabs.contains(domainKey) {
                            loadDomainTabs(for: app, domain: window.displayName)
                        }
                    }
                }
            } else {
                // Window fallbacks: trigger tap action to open timeline
                onWindowTapped?(app, window)
            }
        }
    }

    // MARK: - Domain Tabs Section

    /// Shows tabs for a specific domain when expanded
    @ViewBuilder
    private func domainTabsSection(for app: AppUsageData, domain: String, appColor: Color, layoutSize: AppUsageLayoutSize) -> some View {
        let domainKey = "\(app.appBundleID)_\(domain)"
        let tabs = domainTabsCache[domainKey] ?? []
        let isLoading = loadingDomainTabs.contains(domainKey)
        let displayedCount = displayedDomainTabCounts[domainKey] ?? initialDomainTabCount
        let displayedTabs = Array(tabs.prefix(displayedCount))
        let hasMoreTabs = tabs.count > displayedCount

        VStack(spacing: 2) {
            if isLoading && tabs.isEmpty {
                HStack {
                    Spacer()
                    SpinnerView(size: 12, lineWidth: 2, color: .retraceSecondary)
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.leading, layoutSize.windowRowIndent + 20)
            } else if tabs.isEmpty {
                HStack {
                    Text("No tab data for this site")
                        .font(.system(size: 10))
                        .foregroundColor(.retraceSecondary.opacity(0.5))
                        .italic()
                }
                .padding(.vertical, 6)
                .padding(.leading, layoutSize.windowRowIndent + 20)
            } else {
                ForEach(Array(displayedTabs.enumerated()), id: \.element.id) { index, tab in
                    domainTabRow(tab: tab, app: app, appColor: appColor, layoutSize: layoutSize)
                }

                // Load more tabs button
                if hasMoreTabs {
                    domainTabLoadMoreButton(domainKey: domainKey, remainingCount: tabs.count - displayedCount, layoutSize: layoutSize)
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    /// Single tab row within the domain expansion
    private func domainTabRow(tab: WindowUsageData, app: AppUsageData, appColor: Color, layoutSize: AppUsageLayoutSize) -> some View {
        let tabKey = "\(app.appBundleID)_domain_\(tab.id)"
        let isHovered = hoveredWindowKey == tabKey

        return HStack(spacing: 6) {
            // Extra indent + dot indicator
            HStack(spacing: 4) {
                Spacer()
                    .frame(width: layoutSize.windowRowIndent + 6)

                Circle()
                    .fill(appColor.opacity(0.4))
                    .frame(width: 4, height: 4)
            }

            // Tab title with URL subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayName)
                    .font(layoutSize.windowNameFont)
                    .foregroundColor(.retracePrimary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let url = tab.browserUrl, !url.isEmpty {
                    Text(url)
                        .font(.system(size: 10))
                        .foregroundColor(.retraceSecondary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Duration
            Text(formatDuration(tab.duration))
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.retraceSecondary.opacity(0.7))
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, layoutSize.horizontalPadding)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.white.opacity(0.02) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredWindowKey = hovering ? tabKey : nil
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            onWindowTapped?(app, tab)
        }
    }

    /// Load more button for domain tabs
    private func domainTabLoadMoreButton(domainKey: String, remainingCount: Int, layoutSize: AppUsageLayoutSize) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                let currentCount = displayedDomainTabCounts[domainKey] ?? initialDomainTabCount
                displayedDomainTabCounts[domainKey] = currentCount + 5
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11, weight: .medium))
                Text("Show more")
                    .font(.system(size: 11, weight: .medium))
                Text("(\(min(5, remainingCount)))")
                    .font(.system(size: 11))
                    .foregroundColor(.retraceSecondary.opacity(0.6))
            }
            .foregroundColor(.retraceSecondary.opacity(0.7))
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .padding(.leading, layoutSize.windowRowIndent + 20)
        .padding(.top, 4)
    }

    /// Load tabs for a specific domain
    private func loadDomainTabs(for app: AppUsageData, domain: String) {
        guard let loader = loadTabsForDomain else { return }

        let domainKey = "\(app.appBundleID)_\(domain)"
        loadingDomainTabs.insert(domainKey)

        Task {
            let tabs = await loader(app.appBundleID, domain)
            await MainActor.run {
                domainTabsCache[domainKey] = tabs
                loadingDomainTabs.remove(domainKey)
            }
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
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.retraceSecondary.opacity(0.6))
                .frame(width: 12)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)

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
                // Preload window/website data on hover so it's ready when user clicks
                if windowUsageCache[app.appBundleID] == nil && !loadingWindows.contains(app.appBundleID) {
                    loadWindowData(for: app)
                }
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

                // Preload favicons for browser URLs
                if app.isBrowser {
                    for window in windows {
                        FaviconProvider.shared.fetchFaviconIfNeeded(for: window.displayName) { _ in }
                    }
                }
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
