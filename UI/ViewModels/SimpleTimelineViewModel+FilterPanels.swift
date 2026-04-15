import App
import Foundation
import Shared
import SwiftUI

extension SimpleTimelineViewModel {
    public struct TimelineStateSnapshot {
        let filterCriteria: FilterCriteria
        let frames: [TimelineFrame]
        let currentIndex: Int
        let hasMoreOlder: Bool
        let hasMoreNewer: Bool
    }
}

extension SimpleTimelineViewModel {
    // MARK: - Filter Dropdown State

    public enum FilterDropdownType: Equatable {
        case none
        case apps
        case tags
        case visibility
        case comments
        case dateRange
        case advanced
    }

    public var activeFilterDropdown: FilterDropdownType { filterStore.sessionState.activeFilterDropdown }
    public var filterDropdownAnchorFrame: CGRect { filterStore.sessionState.filterDropdownAnchorFrame }
    public var filterAnchorFrames: [FilterDropdownType: CGRect] { filterStore.sessionState.filterAnchorFrames }
    public var isDateRangeCalendarEditing: Bool { filterStore.sessionState.isDateRangeCalendarEditing }

    public func replacePendingFilterCriteria(_ criteria: FilterCriteria) {
        let normalized = normalizedTimelineFilterCriteria(criteria)
        filterStore.setPendingFilterCriteria(normalized, invalidate: notifyFilterStateWillChange)
    }

    public func replaceAppliedAndPendingFilterCriteria(_ criteria: FilterCriteria) {
        let normalized = normalizedTimelineFilterCriteria(criteria)
        filterStore.replaceCriteria(normalized, invalidate: notifyFilterStateWillChange)
    }

    public func clearPendingAppSelection() {
        var updatedCriteria = pendingFilterCriteria
        updatedCriteria.selectedApps = nil
        replacePendingFilterCriteria(updatedCriteria)
    }

    public func clearPendingTagSelection() {
        var updatedCriteria = pendingFilterCriteria
        updatedCriteria.selectedTags = nil
        replacePendingFilterCriteria(updatedCriteria)
    }

    public func setPendingWindowNameFilter(_ value: String?) {
        var updatedCriteria = pendingFilterCriteria
        updatedCriteria.windowNameFilter = value
        replacePendingFilterCriteria(updatedCriteria)
    }

    public func setPendingBrowserURLFilter(_ value: String?) {
        var updatedCriteria = pendingFilterCriteria
        updatedCriteria.browserUrlFilter = value
        replacePendingFilterCriteria(updatedCriteria)
    }

    func notifyCommentStateWillChange() {
        objectWillChange.send()
    }

    func notifyFilterStateWillChange() {
        objectWillChange.send()
    }

    public func showFilterDropdown(_ type: FilterDropdownType, anchorFrame: CGRect) {
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[FilterDropdown] showFilterDropdown type=\(type), anchor=\(anchorFrame)", category: .ui)
        }

        filterStore.showDropdown(type, anchorFrame: anchorFrame, invalidate: notifyFilterStateWillChange)

        if type == .apps {
            startAvailableAppsForFilterLoadIfNeeded()
        }
    }

    public func dismissFilterDropdown() {
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[FilterDropdown] dismissFilterDropdown", category: .ui)
        }
        filterStore.dismissDropdown(invalidate: notifyFilterStateWillChange)
    }

    public func setFilterAnchorFrame(_ frame: CGRect, for type: FilterDropdownType) {
        var updatedAnchorFrames = filterAnchorFrames
        updatedAnchorFrames[type] = frame
        filterStore.setFilterAnchorFrames(
            updatedAnchorFrames,
            activeDropdown: activeFilterDropdown,
            currentType: type,
            anchorFrame: frame,
            invalidate: notifyFilterStateWillChange
        )
    }

    public func setDateRangeCalendarEditingState(_ isEditing: Bool) {
        filterStore.setDateRangeCalendarEditing(isEditing, invalidate: notifyFilterStateWillChange)
    }

    public func setAppliedFilterCriteria(_ criteria: FilterCriteria) {
        let normalized = normalizedTimelineFilterCriteria(criteria)
        filterStore.setFilterCriteria(normalized, invalidate: notifyFilterStateWillChange)
    }

    public func setFilterPanelVisible(_ isVisible: Bool) {
        filterStore.setPanelVisible(isVisible, invalidate: notifyFilterStateWillChange)
    }

    // MARK: - Filter Data Loading

    public func loadAvailableAppsForFilter() async {
        await filterStore.loadAvailableAppsForFilter(
            environment: TimelineFilterStore.AvailableAppsLoadEnvironment(
                rewindCacheContext: TimelineFilterStore.currentRewindAppBundleIDCacheContext(),
                installedApps: { [weak self] in
                    guard let self else { return [] }
                    return await self.installedAppsForFilter()
                },
                distinctAppBundleIDs: { [weak self] source in
                    guard let self else { return [] }
                    return try await self.distinctAppBundleIDsForFilter(source: source)
                },
                resolveApps: { [weak self] bundleIDs in
                    guard let self else { return [] }
                    return await self.resolveAppsForFilter(bundleIDs: bundleIDs)
                },
                loadCachedRewindAppBundleIDs: { context in
                    await TimelineFilterStore.loadCachedRewindAppBundleIDs(matching: context)
                },
                saveCachedRewindAppBundleIDs: { bundleIDs, context in
                    await TimelineFilterStore.saveCachedRewindAppBundleIDs(bundleIDs, context: context)
                },
                removeCachedRewindAppBundleIDs: {
                    await TimelineFilterStore.removeCachedRewindAppBundleIDs()
                },
                invalidate: { [weak self] in
                    self?.notifyFilterStateWillChange()
                }
            )
        )
    }

    private func startAvailableAppsForFilterLoadIfNeeded() {
        let rewindCacheContext = TimelineFilterStore.currentRewindAppBundleIDCacheContext()
        filterStore.startAvailableAppsLoadIfNeeded(rewindCacheContext: rewindCacheContext) { [weak self] in
            guard let self else { return }
            await self.loadAvailableAppsForFilter()
        }
    }

    private func scheduleFilterPanelSupportingDataLoad() {
        let shouldSkipSupportingPanelDataLoad: Bool
#if DEBUG
        shouldSkipSupportingPanelDataLoad = test_availableAppsForFilterHooks.skipSupportingPanelDataLoad
#else
        shouldSkipSupportingPanelDataLoad = false
#endif
        filterStore.scheduleSupportingDataLoad(skip: shouldSkipSupportingPanelDataLoad) { [weak self] in
            guard let self else { return }
            let callbacks = self.makeCommentTagIndicatorCallbacks()
            await self.filterStore.loadSupportingPanelDataIfNeeded(
                commentsStore: self.commentsStore,
                fetchAllTags: { [weak self] in
                    guard let self else { return [] }
                    return try await self.coordinator.getAllTags()
                },
                fetchHiddenSegmentIDs: { [weak self] in
                    guard let self else { return [] }
                    return try await self.coordinator.getHiddenSegmentIds()
                },
                fetchSegmentTagsMap: { [weak self] in
                    guard let self else { return [:] }
                    return try await self.coordinator.getSegmentTagsMap()
                },
                invalidateComments: callbacks.invalidate,
                invalidateFilters: self.notifyFilterStateWillChange,
                didUpdateAvailableTags: callbacks.didUpdateAvailableTags,
                didUpdateSegmentTagsMap: callbacks.didUpdateSegmentTagsMap
            )
        }
    }

    private func installedAppsForFilter() async -> [AppInfo] {
#if DEBUG
        if let getInstalledApps = test_availableAppsForFilterHooks.getInstalledApps {
            return getInstalledApps()
        }
#endif
        return await Task.detached(priority: .utility) {
            AppNameResolver.shared.getInstalledApps()
        }.value
    }

    private func distinctAppBundleIDsForFilter(source: FrameSource?) async throws -> [String] {
#if DEBUG
        if let getDistinctAppBundleIDs = test_availableAppsForFilterHooks.getDistinctAppBundleIDs {
            return try await getDistinctAppBundleIDs(source)
        }
#endif
        return try await coordinator.getDistinctAppBundleIDs(source: source)
    }

    private func resolveAppsForFilter(bundleIDs: [String]) async -> [AppInfo] {
#if DEBUG
        if let resolveAllBundleIDs = test_availableAppsForFilterHooks.resolveAllBundleIDs {
            return resolveAllBundleIDs(bundleIDs)
        }
#endif
        return await Task.detached(priority: .utility) {
            AppNameResolver.shared.resolveAll(bundleIDs: bundleIDs)
        }.value
    }

    // MARK: - Filter Criteria

    func normalizedTimelineFilterCriteria(_ criteria: FilterCriteria) -> FilterCriteria {
        TimelineFilterStateSupport.normalizedCriteria(criteria)
    }

    func summarizeFiltersForLog(_ filters: FilterCriteria) -> String {
        TimelineFilterStateSupport.summarizeFiltersForLog(filters)
    }

    public func toggleAppFilter(_ bundleID: String) {
        replacePendingFilterCriteria(
            TimelineFilterStateSupport.toggledApp(bundleID, in: pendingFilterCriteria)
        )
        let appCount = pendingFilterCriteria.selectedApps?.count ?? 0
        Log.debug("[Filter] Toggled app filter for \(bundleID), now \(appCount) apps selected (pending)", category: .ui)
    }

    public func toggleTagFilter(_ tagId: TagID) {
        replacePendingFilterCriteria(
            TimelineFilterStateSupport.toggledTag(tagId.value, in: pendingFilterCriteria)
        )
        let tagCount = pendingFilterCriteria.selectedTags?.count ?? 0
        Log.debug("[Filter] Toggled tag filter for \(tagId.value), now \(tagCount) tags selected (pending)", category: .ui)
    }

    public func setHiddenFilter(_ mode: HiddenFilter) {
        replacePendingFilterCriteria(
            TimelineFilterStateSupport.settingHiddenFilter(mode, in: pendingFilterCriteria)
        )
        Log.debug("[Filter] Set hidden filter to \(mode.rawValue) (pending)", category: .ui)
    }

    public func setCommentFilter(_ mode: CommentFilter) {
        replacePendingFilterCriteria(
            TimelineFilterStateSupport.settingCommentFilter(mode, in: pendingFilterCriteria)
        )
        Log.debug("[Filter] Set comment filter to \(mode.rawValue) (pending)", category: .ui)
    }

    public func setAppFilterMode(_ mode: AppFilterMode) {
        replacePendingFilterCriteria(
            TimelineFilterStateSupport.settingAppFilterMode(mode, in: pendingFilterCriteria)
        )
        Log.debug("[Filter] Set app filter mode to \(mode.rawValue) (pending)", category: .ui)
    }

    public func setTagFilterMode(_ mode: TagFilterMode) {
        replacePendingFilterCriteria(
            TimelineFilterStateSupport.settingTagFilterMode(mode, in: pendingFilterCriteria)
        )
        Log.debug("[Filter] Set tag filter mode to \(mode.rawValue) (pending)", category: .ui)
    }

    public func setDateRanges(_ ranges: [DateRangeCriterion]) {
        replacePendingFilterCriteria(
            TimelineFilterStateSupport.settingDateRanges(ranges, in: pendingFilterCriteria)
        )
        Log.debug("[Filter] Set date ranges to \(pendingFilterCriteria.effectiveDateRanges) (pending)", category: .ui)
    }

    public func setDateRange(start: Date?, end: Date?) {
        if start == nil && end == nil {
            setDateRanges([])
        } else {
            setDateRanges([DateRangeCriterion(start: start, end: end)])
        }
    }

    public func beginCmdFQuickFilterLatencyTrace(
        bundleID: String,
        action: String,
        trigger: String,
        source: FrameSource
    ) {
        pendingCmdFQuickFilterLatencyTrace = nil
    }

    public func applyFilters(dismissPanel: Bool = true) {
        Log.debug("[Filter] applyFilters() called - pending.selectedApps=\(String(describing: pendingFilterCriteria.selectedApps)), current.selectedApps=\(String(describing: filterCriteria.selectedApps))", category: .ui)

        let result = filterStore.applyPendingFilters(
            dismissPanel: dismissPanel,
            invalidate: notifyFilterStateWillChange
        )

        let preparation = result.preparation
        let resultingCriteria = result.resultingCriteria
        let normalizedCurrentCriteria = preparation.normalizedCurrentCriteria
        let normalizedPendingCriteria = preparation.normalizedPendingCriteria

        if !preparation.requiresReload {
            if dismissPanel {
                filterStore.cancelSupportingDataLoad()
            }
            return
        }

        invalidatePeekCache()

        let timestampToPreserve = currentTimestamp
        let cmdFTrace = pendingCmdFQuickFilterLatencyTrace
        pendingCmdFQuickFilterLatencyTrace = nil
        logCmdFPlayheadState(
            "applyFilters.capture",
            trace: cmdFTrace,
            targetTimestamp: timestampToPreserve,
            extra: "pending={\(summarizeFiltersForLog(normalizedPendingCriteria))} current={\(summarizeFiltersForLog(normalizedCurrentCriteria))}"
        )

        Log.debug("[Filter] Applied filters - filterCriteria.selectedApps=\(String(describing: resultingCriteria.selectedApps))", category: .ui)
        logCmdFPlayheadState(
            "applyFilters.applied",
            trace: cmdFTrace,
            targetTimestamp: timestampToPreserve,
            extra: "applied={\(summarizeFiltersForLog(resultingCriteria))}"
        )

        DashboardViewModel.recordTimelineFilter(
            coordinator: coordinator,
            metadata: buildTimelineFilterMetricMetadata()
        )

        if dismissPanel {
            filterStore.cancelSupportingDataLoad()
        }

        saveFilterCriteria()

        Task {
            if let timestamp = timestampToPreserve {
                logCmdFPlayheadState("applyFilters.reloadDispatch", trace: cmdFTrace, targetTimestamp: timestamp)
                await reloadFramesAroundTimestamp(timestamp, cmdFTrace: cmdFTrace)
            } else {
                if let cmdFTrace {
                    Log.warning("[CmdFPerf][\(cmdFTrace.id)] No current timestamp available after action=\(cmdFTrace.action), falling back to loadMostRecentFrame()", category: .ui)
                }
                await loadMostRecentFrame()
                logCmdFPlayheadState("applyFilters.fallbackComplete", trace: cmdFTrace)
                if let cmdFTrace {
                    let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.recordLatency(
                        "timeline.cmdf.quick_filter.fallback_total_ms",
                        valueMs: totalElapsedMs,
                        category: .ui,
                        summaryEvery: 5,
                        warningThresholdMs: 300,
                        criticalThresholdMs: 700
                    )
                    Log.info("[CmdFPerf][\(cmdFTrace.id)] Fallback loadMostRecentFrame() complete total=\(String(format: "%.1f", totalElapsedMs))ms", category: .ui)
                }
            }
        }
    }

    public func clearPendingFilters() {
        filterStore.clearPendingCriteria(invalidate: notifyFilterStateWillChange)
        Log.debug("[Filter] Cleared pending filters", category: .ui)
    }

    public func clearAllFilters() {
        invalidatePeekCache()

        let timestampToPreserve = currentTimestamp
        let cmdFTrace = pendingCmdFQuickFilterLatencyTrace
        pendingCmdFQuickFilterLatencyTrace = nil
        logCmdFPlayheadState(
            "clearFilters.capture",
            trace: cmdFTrace,
            targetTimestamp: timestampToPreserve,
            extra: "current={\(summarizeFiltersForLog(filterCriteria))}"
        )

        clearFilterState()
        logCmdFPlayheadState("clearFilters.cleared", trace: cmdFTrace, targetTimestamp: timestampToPreserve)

        Task {
            if let timestamp = timestampToPreserve {
                logCmdFPlayheadState("clearFilters.reloadDispatch", trace: cmdFTrace, targetTimestamp: timestamp)
                await reloadFramesAroundTimestamp(timestamp, cmdFTrace: cmdFTrace)
            } else {
                if let cmdFTrace {
                    Log.warning("[CmdFPerf][\(cmdFTrace.id)] No current timestamp available after action=\(cmdFTrace.action), falling back to loadMostRecentFrame()", category: .ui)
                }
                await loadMostRecentFrame()
                logCmdFPlayheadState("clearFilters.fallbackComplete", trace: cmdFTrace)
                if let cmdFTrace {
                    let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.recordLatency(
                        "timeline.cmdf.quick_filter.fallback_total_ms",
                        valueMs: totalElapsedMs,
                        category: .ui,
                        summaryEvery: 5,
                        warningThresholdMs: 300,
                        criticalThresholdMs: 700
                    )
                    Log.info("[CmdFPerf][\(cmdFTrace.id)] Fallback loadMostRecentFrame() complete total=\(String(format: "%.1f", totalElapsedMs))ms", category: .ui)
                }
            }
        }
    }

    public func clearFiltersWithoutReload() {
        let wasFilterPanelVisible = isFilterPanelVisible
        guard filterStore.clearWithoutReload(invalidate: notifyFilterStateWillChange) else { return }

        invalidatePeekCache()
        saveFilterCriteria()

        if wasFilterPanelVisible {
            filterStore.cancelSupportingDataLoad()
        }

        Log.info("[Filter] Cleared filters without immediate reload", category: .ui)
    }

    func clearFilterState() {
        filterStore.clearCriteria(invalidate: notifyFilterStateWillChange)
        Log.debug("[Filter] Cleared all filters", category: .ui)
        saveFilterCriteria()
    }

    private func buildTimelineFilterMetricMetadata() -> TimelineFilterMetricMetadata {
        let effectiveDateRanges = filterCriteria.effectiveDateRanges
        return TimelineFilterMetricMetadata(
            hasAppFilter: !(filterCriteria.selectedApps?.isEmpty ?? true),
            hasWindowFilter: !(filterCriteria.windowNameFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            hasURLFilter: !(filterCriteria.browserUrlFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            hasStartDate: effectiveDateRanges.contains(where: { $0.start != nil }),
            hasEndDate: effectiveDateRanges.contains(where: { $0.end != nil })
        )
    }

    // MARK: - Peek Mode (View Full Context)

    public func peekContext() {
        guard filterCriteria.hasActiveFilters else {
            Log.debug("[Peek] peekContext() called but no active filters - ignoring", category: .ui)
            return
        }

        guard !frames.isEmpty else {
            Log.debug("[Peek] peekContext() called but no frames loaded - ignoring", category: .ui)
            return
        }

        let timestampToPreserve = currentTimestamp

        cachedFilteredState = TimelineStateSnapshot(
            filterCriteria: filterCriteria,
            frames: frames,
            currentIndex: currentIndex,
            hasMoreOlder: frameWindowStore.hasMoreOlder,
            hasMoreNewer: frameWindowStore.hasMoreNewer
        )
        Log.info("[Peek] Cached filtered state: \(frames.count) frames, index=\(currentIndex)", category: .ui)

        filterStore.clearCriteria(invalidate: notifyFilterStateWillChange)
        isPeeking = true

        Task {
            if let timestamp = timestampToPreserve {
                await reloadFramesAroundTimestamp(timestamp)
            } else {
                await loadMostRecentFrame()
            }
        }
    }

    public func exitPeek() {
        guard isPeeking else {
            Log.debug("[Peek] exitPeek() called but not in peek mode - ignoring", category: .ui)
            return
        }

        guard let filteredState = cachedFilteredState else {
            Log.warning("[Peek] exitPeek() called but no cached filtered state - clearing peek mode", category: .ui)
            isPeeking = false
            return
        }

        Log.info("[Peek] Restoring filtered state: \(filteredState.frames.count) frames, returning to index=\(filteredState.currentIndex)", category: .ui)
        restoreTimelineState(filteredState)
        isPeeking = false
        cachedFilteredState = nil
    }

    public func togglePeek() {
        if isPeeking {
            exitPeek()
        } else {
            peekContext()
        }
    }

    private func restoreTimelineState(_ snapshot: TimelineStateSnapshot) {
        let normalized = normalizedTimelineFilterCriteria(snapshot.filterCriteria)
        filterStore.replaceCriteria(normalized, invalidate: notifyFilterStateWillChange)
        frameWindowStore.restoreSnapshotState(
            frames: snapshot.frames,
            currentIndex: snapshot.currentIndex,
            hasMoreOlder: snapshot.hasMoreOlder,
            hasMoreNewer: snapshot.hasMoreNewer
        )
        frames = snapshot.frames
        currentIndex = snapshot.currentIndex
        refreshCurrentFramePresentation()
    }

    public func invalidatePeekCache() {
        cachedFilteredState = nil
        if isPeeking {
            isPeeking = false
            Log.debug("[Peek] Peek cache invalidated, exiting peek mode", category: .ui)
        }
    }

    func applyFilteredEmptyTimelineState(context: String) {
        let clearedFrameCount = frames.count
        frameWindowStore.applyFilteredEmptyState(context: context)
        selectedFrameIndex = nil
        frames = []
        clearCurrentImagePresentation()
        clearWaitingFallbackImage()
        clearPendingVideoPresentationState()
        setFramePresentationState(isNotReady: false, hasLoadError: false)
        Log.info(
            "[Filter] Entered filtered empty state context=\(context) clearedFrames=\(clearedFrameCount)",
            category: .ui
        )
    }

    func showNoResultsMessage() {
        showErrorWithAutoDismiss("No frames found matching the current filters. Clear filters to see all frames.")
    }

    // MARK: - Dialog Dismissal

    public enum DialogType {
        case filter
        case dateSearch
        case search
        case inFrameSearch
    }

    public func dismissOtherDialogs(except: DialogType? = nil) {
        if except != .filter && isFilterPanelVisible {
            let normalized = normalizedTimelineFilterCriteria(filterCriteria)
            filterStore.dismissPanel(
                appliedCriteria: normalized,
                invalidate: notifyFilterStateWillChange
            )
            filterStore.cancelSupportingDataLoad()
        }

        if except != .dateSearch && isDateSearchActive {
            isDateSearchActive = false
            dateSearchText = ""
        }

        if except != .search && isSearchOverlayVisible {
            isSearchOverlayVisible = false
        }

        if except != .inFrameSearch && isInFrameSearchVisible {
            closeInFrameSearch(clearQuery: true)
        }

        dismissContextMenu()
        dismissTimelineContextMenu()
        dismissRedactionTooltip()
    }

    public func dismissFilterPanel() {
        let normalized = normalizedTimelineFilterCriteria(filterCriteria)
        filterStore.dismissPanel(
            appliedCriteria: normalized,
            invalidate: notifyFilterStateWillChange
        )
        filterStore.cancelSupportingDataLoad()
    }

    public func openFilterPanel() {
        dismissOtherDialogs(except: .filter)
        showControlsIfHidden()
        let normalized = normalizedTimelineFilterCriteria(filterCriteria)
        filterStore.openPanel(
            appliedCriteria: normalized,
            invalidate: notifyFilterStateWillChange
        )
        startAvailableAppsForFilterLoadIfNeeded()
        scheduleFilterPanelSupportingDataLoad()
    }

    // MARK: - State Cache

    public func saveState() {
        Log.debug("[StateCache] saveState() called", category: .ui)
        searchViewModel.saveSearchResults()
        saveFilterCriteria()
    }

    func saveFilterCriteria() {
        let normalizedPendingCriteria = normalizedTimelineFilterCriteria(pendingFilterCriteria)
        if normalizedPendingCriteria != pendingFilterCriteria {
            filterStore.setPendingFilterCriteria(
                normalizedPendingCriteria,
                invalidate: notifyFilterStateWillChange
            )
        }

        Log.debug("[FilterCache] saveFilterCriteria() called - pending.selectedApps=\(String(describing: normalizedPendingCriteria.selectedApps)), pending.hasActiveFilters=\(normalizedPendingCriteria.hasActiveFilters)", category: .ui)
        switch filterStore.saveCriteriaCache(normalizedPendingCriteria) {
        case .saved:
            Log.debug("[FilterCache] Saved pending filter criteria with selectedApps=\(String(describing: normalizedPendingCriteria.selectedApps))", category: .ui)
        case .clearedInactive:
            Log.debug("[FilterCache] No active pending filters, clearing cache", category: .ui)
        case .failed(let error):
            Log.warning("[FilterCache] Failed to save filter criteria: \(error)", category: .ui)
        }
    }

    func restoreCachedFilterCriteria() {
        switch filterStore.restoreCriteriaCache() {
        case .missingSavedAt:
            Log.debug("[FilterCache] No saved filter cache found", category: .ui)
        case .missingCriteriaData:
            Log.debug("[FilterCache] No filter data in cache", category: .ui)
        case let .expired(elapsed):
            Log.info(
                "[FilterCache] Cache expired (elapsed: \(Int(elapsed))s, threshold: \(Int(TimelineFilterCacheSupport.defaultExpirationSeconds))s), clearing",
                category: .ui
            )
        case let .restored(restored, elapsed):
            let normalized = normalizedTimelineFilterCriteria(restored)
            filterStore.replaceCriteria(normalized, invalidate: notifyFilterStateWillChange)
            Log.debug("[FilterCache] Restored filter criteria (saved \(Int(elapsed))s ago) - selectedApps=\(String(describing: filterCriteria.selectedApps))", category: .ui)
        case .failed(let error):
            Log.warning("[FilterCache] Failed to restore filter criteria: \(error)", category: .ui)
        }
    }

    func clearCachedFilterCriteria() {
        filterStore.clearCriteriaCache()
    }
}
