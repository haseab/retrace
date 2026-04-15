import SwiftUI
import Shared
import App
import AppKit

extension SpotlightSearchOverlay {
    // MARK: - Recent Entries

    func refreshRankedRecentEntries() {
        rankedRecentEntries = viewModel.rankedRecentSearchEntries(for: viewModel.searchQuery, limit: recentEntryLimit)
    }

    func refreshRecentEntryTagMap() {
        recentEntryTagByID = Dictionary(uniqueKeysWithValues: viewModel.availableTags.map { ($0.id.value, $0) })
    }

    func refreshRecentEntryAppNameMap() {
        recentEntryAppNamesByBundleID = Self.recentEntryAppNameMap(from: viewModel.availableApps)
    }

    var rankedRecentEntriesCount: Int {
        rankedRecentEntries.count
    }

    var shouldShowRecentEntriesPopover: Bool {
        guard isVisible else { return false }
        guard !isRecentEntriesDismissedByUser else { return false }
        let isQueryEmpty = viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if suppressRecentEntriesForCurrentPresentation && isQueryEmpty {
            return false
        }
        if let blockedUntil = recentEntriesRevealBlockedUntil, Date() < blockedUntil {
            return false
        }
        guard !viewModel.isDropdownOpen else { return false }
        guard !viewModel.isSearching else { return false }
        guard !isResultKeyboardNavigationActive else { return false }
        guard !isExpanded else { return false }
        guard viewModel.results == nil else { return false }
        return rankedRecentEntriesCount > 0
    }

    func configureRecentEntriesRevealDelay() {
        recentEntriesRevealTask?.cancel()
        recentEntriesRevealTask = nil

        suppressRecentEntriesForCurrentPresentation = viewModel.consumeSuppressRecentEntriesForNextOverlayOpen()
        let revealDelay = viewModel.consumeNextRecentEntriesRevealDelay()
        Log.info(
            "\(searchLog)[\(overlaySessionID)] configureRecentEntriesRevealDelay suppressForPresentation=\(suppressRecentEntriesForCurrentPresentation) revealDelay=\(String(format: "%.3f", revealDelay))",
            category: .ui
        )
        guard revealDelay > 0 else {
            recentEntriesRevealBlockedUntil = nil
            return
        }

        recentEntriesRevealBlockedUntil = Date().addingTimeInterval(revealDelay)
        recentEntriesRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(revealDelay), clock: .continuous)
            guard !Task.isCancelled else { return }
            recentEntriesRevealBlockedUntil = nil
            Log.info("\(searchLog)[\(overlaySessionID)] revealDelay elapsed; reevaluating popover visibility", category: .ui)
            refreshRecentEntriesPopoverVisibility()
        }
    }

    func refreshRecentEntriesPopoverVisibility() {
        let shouldShow = shouldShowRecentEntriesPopover
        if shouldShow != isRecentEntriesPopoverVisible {
            Log.info(
                "\(searchLog)[\(overlaySessionID)] popover visibility \(isRecentEntriesPopoverVisible) -> \(shouldShow)",
                category: .ui
            )
            withAnimation(.easeOut(duration: 0.15)) {
                isRecentEntriesPopoverVisible = shouldShow
            }
        }

        if shouldShow {
            scheduleRecentEntriesMetadataWarmupIfNeeded()
        }

        if isRecentEntriesPopoverVisible {
            highlightedRecentEntryIndex = min(highlightedRecentEntryIndex, max(rankedRecentEntries.count - 1, 0))
        } else {
            highlightedRecentEntryIndex = 0
            hoveredRecentEntryKey = nil
        }
    }

    func scheduleRecentEntriesMetadataWarmupIfNeeded() {
        guard !didScheduleRecentEntriesMetadataWarmup else { return }
        didScheduleRecentEntriesMetadataWarmup = true

        recentEntriesMetadataWarmupTask?.cancel()
        recentEntriesMetadataWarmupTask = Task(priority: .utility) {
            // Let overlay first frame settle before metadata warmup.
            try? await Task.sleep(for: .milliseconds(120), clock: .continuous)
            guard !Task.isCancelled else { return }

            async let apps: Void = viewModel.loadAvailableApps()
            async let tags: Void = viewModel.loadAvailableTags()
            _ = await (apps, tags)
        }
    }

    func selectHighlightedRecentEntry() {
        let entries = rankedRecentEntries
        guard !entries.isEmpty else { return }
        let selectedIndex = min(highlightedRecentEntryIndex, entries.count - 1)
        selectRecentEntry(entries[selectedIndex])
    }

    func selectRecentEntry(_ entry: SearchViewModel.RecentSearchEntry) {
        viewModel.submitRecentSearchEntry(entry)
        isRecentEntriesPopoverVisible = false
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded = true
        }

        prepareResultKeyboardNavigationAfterSubmit()
    }

    func removeRecentEntry(_ entry: SearchViewModel.RecentSearchEntry) {
        viewModel.removeRecentSearchEntry(entry)
        Log.info("\(searchLog)[\(overlaySessionID)] removed recent entry key=\(entry.key)", category: .ui)
    }

    func dismissRecentEntriesPopoverByUser() {
        isRecentEntriesDismissedByUser = true
        Log.info("\(searchLog)[\(overlaySessionID)] user dismissed recent entries popover via header x", category: .ui)
        withAnimation(.easeOut(duration: 0.15)) {
            isRecentEntriesPopoverVisible = false
        }
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil
    }

    func logRecentEntriesState(context: String) {
        let isQueryEmpty = viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let blockedUntilActive: Bool = {
            if let blockedUntil = recentEntriesRevealBlockedUntil {
                return Date() < blockedUntil
            }
            return false
        }()
        let hasResults = viewModel.results != nil
        let rankedCount = rankedRecentEntriesCount
        let shouldShow = shouldShowRecentEntriesPopover
        Log.info(
            "\(searchLog)[\(overlaySessionID)] \(context) visible=\(isVisible) expanded=\(isExpanded) queryEmpty=\(isQueryEmpty) hasResults=\(hasResults) rankedCount=\(rankedCount) dismissedByUser=\(isRecentEntriesDismissedByUser) suppressForPresentation=\(suppressRecentEntriesForCurrentPresentation) blockedUntilActive=\(blockedUntilActive) dropdownOpen=\(viewModel.isDropdownOpen) searching=\(viewModel.isSearching) resultNavActive=\(isResultKeyboardNavigationActive) popoverVisible=\(isRecentEntriesPopoverVisible) shouldShow=\(shouldShow)",
            category: .ui
        )
    }

    var recentEntriesViewportHeight: CGFloat {
        let visibleCount = max(1, min(recentEntryVisibleCount, rankedRecentEntriesCount))
        let rowsHeight = CGFloat(visibleCount) * recentEntryRowHeight
        let spacingHeight = CGFloat(max(0, visibleCount - 1)) * recentEntryRowSpacing
        return rowsHeight + spacingHeight + (recentEntryListVerticalPadding * 2)
    }

    var recentEntriesPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            recentEntriesHeader
            recentEntriesList
        }
        .frame(width: collapsedWidth - 8, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.4))
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
    }

    private var recentEntriesHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(RetraceMenuStyle.textColorMuted)
            Text("Recent Entries")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(RetraceMenuStyle.textColorMuted)
            Spacer(minLength: 8)
            Button(action: {
                dismissRecentEntriesPopoverByUser()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(RetraceMenuStyle.textColorMuted)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("Hide recent entries")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var recentEntriesList: some View {
        ScrollView(.vertical, showsIndicators: rankedRecentEntriesCount > recentEntryVisibleCount) {
            VStack(spacing: recentEntryRowSpacing) {
                ForEach(Array(rankedRecentEntries.enumerated()), id: \.element.key) { index, entry in
                    let isRowHovered = hoveredRecentEntryKey == entry.key
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            selectRecentEntry(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(entry.query)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(RetraceMenuStyle.textColor)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 6)
                                    Text(recentEntryRelativeTimeText(for: entry))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(RetraceMenuStyle.textColorMuted)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }

                                recentEntryFilterSummaryRow(for: entry.filters)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            removeRecentEntry(entry)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(RetraceMenuStyle.textColorMuted)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 12, height: 12)
                        .padding(.top, 2)
                        .opacity(isRowHovered ? 1 : 0)
                        .allowsHitTesting(isRowHovered)
                        .accessibilityHidden(!isRowHovered)
                        .help("Remove recent search")
                    }
                    .frame(maxWidth: .infinity, minHeight: recentEntryRowHeight, maxHeight: recentEntryRowHeight, alignment: .leading)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                            .fill(index == highlightedRecentEntryIndex ? RetraceMenuStyle.itemHoverColor : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                            .stroke(
                                index == highlightedRecentEntryIndex
                                    ? RetraceMenuStyle.filterStrokeMedium
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .contentShape(Rectangle())
                    .id(entry.key)
                    .onHover { hovering in
                        if hovering {
                            highlightedRecentEntryIndex = index
                            hoveredRecentEntryKey = entry.key
                        } else if hoveredRecentEntryKey == entry.key {
                            hoveredRecentEntryKey = nil
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, recentEntryListVerticalPadding)
        }
        .frame(height: recentEntriesViewportHeight)
        .padding(.bottom, 10)
    }

    func recentEntryRelativeTimeText(for entry: SearchViewModel.RecentSearchEntry) -> String {
        let now = Date()
        let usedDate = Date(timeIntervalSince1970: entry.lastUsedAt)
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(usedDate)))
        let calendar = Calendar.current

        if elapsedSeconds < 60 {
            return "just now"
        }
        if elapsedSeconds < 3600 {
            let minutes = elapsedSeconds / 60
            return "\(minutes) min ago"
        }
        if elapsedSeconds < 86_400 {
            let hours = elapsedSeconds / 3600
            let minutes = (elapsedSeconds % 3600) / 60
            if minutes == 0 {
                return "\(hours) hour\(hours == 1 ? "" : "s") ago"
            }
            return "\(hours) hour\(hours == 1 ? "" : "s") \(minutes) min ago"
        }
        if calendar.isDateInYesterday(usedDate) {
            return "yesterday"
        }
        if elapsedSeconds < 7 * 86_400 {
            let days = elapsedSeconds / 86_400
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }

        return Self.recentEntryMediumDateFormatter.string(from: usedDate)
    }

    @ViewBuilder
    func recentEntryFilterSummaryRow(for filters: SearchViewModel.RecentSearchFilters) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if !filters.appBundleIDs.isEmpty {
                    recentEntryAppSummary(for: filters)
                }

                if !filters.tagIDs.isEmpty {
                    if filters.tagFilterMode == .exclude {
                        recentEntryMetadataToken(icon: "minus.circle.fill", text: "Tags", tint: .orange.opacity(0.9))
                    }
                    ForEach(recentEntryTags(for: filters), id: \.id.value) { tag in
                        recentEntryTagBadge(tag)
                    }
                }

                if let dateLabel = recentEntryDateLabel(for: filters) {
                    recentEntryMetadataToken(icon: "calendar", text: dateLabel)
                }

                if filters.hiddenFilter != .hide {
                    recentEntryMetadataToken(
                        icon: visibilityIcon(for: filters.hiddenFilter),
                        text: visibilityLabel(for: filters.hiddenFilter)
                    )
                }

                if filters.commentFilter != .allFrames {
                    recentEntryMetadataToken(
                        icon: commentIcon(for: filters.commentFilter),
                        text: commentLabel(for: filters.commentFilter)
                    )
                }

                if !filters.windowNameTerms.isEmpty {
                    let tint: Color = filters.windowNameFilterMode == .exclude ? .orange.opacity(0.9) : RetraceMenuStyle.textColorMuted
                    let icon = filters.windowNameFilterMode == .exclude ? "minus.circle.fill" : "rectangle.and.text.magnifyingglass"
                    ForEach(Array(filters.windowNameTerms.prefix(3)), id: \.self) { term in
                        recentEntryMetadataToken(icon: icon, text: "Title: \(term)", tint: tint)
                    }
                    if filters.windowNameTerms.count > 3 {
                        recentEntryMetadataToken(icon: "ellipsis.circle", text: "+\(filters.windowNameTerms.count - 3)", tint: tint)
                    }
                }

                if !filters.browserUrlTerms.isEmpty {
                    let tint: Color = filters.browserUrlFilterMode == .exclude ? .orange.opacity(0.9) : RetraceMenuStyle.textColorMuted
                    let icon = filters.browserUrlFilterMode == .exclude ? "minus.circle.fill" : "link"
                    ForEach(Array(filters.browserUrlTerms.prefix(3)), id: \.self) { term in
                        recentEntryMetadataToken(icon: icon, text: "URL: \(term)", tint: tint)
                    }
                    if filters.browserUrlTerms.count > 3 {
                        recentEntryMetadataToken(icon: "ellipsis.circle", text: "+\(filters.browserUrlTerms.count - 3)", tint: tint)
                    }
                }

                if !filters.excludedQueryTerms.isEmpty {
                    ForEach(Array(filters.excludedQueryTerms.prefix(4)), id: \.self) { excludedTerm in
                        recentEntryMetadataToken(
                            icon: "minus.circle.fill",
                            text: excludedTerm,
                            tint: .orange.opacity(0.9)
                        )
                    }
                    if filters.excludedQueryTerms.count > 4 {
                        recentEntryMetadataToken(
                            icon: "ellipsis.circle",
                            text: "+\(filters.excludedQueryTerms.count - 4)",
                            tint: .orange.opacity(0.9)
                        )
                    }
                }

                if !hasRecentEntryFilterMetadata(filters) {
                    recentEntryMetadataToken(icon: "slider.horizontal.3", text: "No filters")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func recentEntryAppSummary(for filters: SearchViewModel.RecentSearchFilters) -> some View {
        let bundleIDs = filters.appBundleIDs

        return HStack(spacing: 4) {
            if filters.appFilterMode == .exclude {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.orange.opacity(0.95))
            }

            if bundleIDs.count == 1, let bundleID = bundleIDs.first {
                HStack(spacing: 5) {
                    AppIconView(bundleID: bundleID, size: recentEntryAppIconSize)
                        .frame(width: recentEntryAppIconSize, height: recentEntryAppIconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    Text(recentEntryAppName(for: bundleID))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(RetraceMenuStyle.textColorMuted)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: -4) {
                    ForEach(Array(bundleIDs.prefix(8)), id: \.self) { bundleID in
                        AppIconView(bundleID: bundleID, size: recentEntryAppIconSize)
                            .frame(width: recentEntryAppIconSize, height: recentEntryAppIconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                }
            }
        }
    }

    func recentEntryAppName(for bundleID: String) -> String {
        if let appName = recentEntryAppNamesByBundleID[bundleID] {
            return appName
        }
        let fallback = bundleID
            .split(separator: ".")
            .last
            .map(String.init) ?? bundleID
        return fallback
    }

    func recentEntryMetadataToken(icon: String, text: String, tint: Color = RetraceMenuStyle.textColorMuted) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
                .lineLimit(1)
        }
    }

    func recentEntryTagBadge(_ tag: Tag) -> some View {
        let tint = TagColorStore.color(for: tag)
        return HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(tag.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint.opacity(0.95))
                .lineLimit(1)
        }
    }

    func recentEntryTags(for filters: SearchViewModel.RecentSearchFilters) -> [Tag] {
        return filters.tagIDs.map { tagID in
            recentEntryTagByID[tagID] ?? Tag(id: TagID(value: tagID), name: "#\(tagID)")
        }
    }

    func hasRecentEntryFilterMetadata(_ filters: SearchViewModel.RecentSearchFilters) -> Bool {
        let dateRanges = filters.effectiveDateRanges
        return !filters.appBundleIDs.isEmpty ||
        !filters.tagIDs.isEmpty ||
        filters.hiddenFilter != .hide ||
        filters.commentFilter != .allFrames ||
        !dateRanges.isEmpty ||
        !filters.windowNameTerms.isEmpty ||
        !filters.browserUrlTerms.isEmpty ||
        !filters.excludedQueryTerms.isEmpty
    }

    func recentEntryDateLabel(for filters: SearchViewModel.RecentSearchFilters) -> String? {
        let dateRanges = filters.effectiveDateRanges
        if dateRanges.count > 1 {
            return "\(dateRanges.count) date ranges"
        }
        if let startDate = dateRanges.first?.start, let endDate = dateRanges.first?.end {
            return "\(Self.recentEntryShortDateFormatter.string(from: startDate)) - \(Self.recentEntryShortDateFormatter.string(from: endDate))"
        }
        if let startDate = dateRanges.first?.start {
            return "From \(Self.recentEntryShortDateFormatter.string(from: startDate))"
        }
        if let endDate = dateRanges.first?.end {
            return "Until \(Self.recentEntryShortDateFormatter.string(from: endDate))"
        }
        return nil
    }

    func visibilityIcon(for filter: HiddenFilter) -> String {
        switch filter {
        case .hide:
            return "eye"
        case .onlyHidden:
            return "eye.slash"
        case .showAll:
            return "eye.circle"
        }
    }

    func visibilityLabel(for filter: HiddenFilter) -> String {
        switch filter {
        case .hide:
            return "Visible"
        case .onlyHidden:
            return "Hidden"
        case .showAll:
            return "All"
        }
    }

    func commentIcon(for filter: CommentFilter) -> String {
        switch filter {
        case .allFrames:
            return "text.bubble"
        case .commentsOnly:
            return "text.bubble.fill"
        case .noComments:
            return "text.bubble.slash"
        }
    }

    func commentLabel(for filter: CommentFilter) -> String {
        switch filter {
        case .allFrames:
            return "All"
        case .commentsOnly:
            return "Comments"
        case .noComments:
            return "No Comments"
        }
    }
}
