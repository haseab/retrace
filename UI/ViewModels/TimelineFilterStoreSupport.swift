import CoreGraphics
import Foundation
import App
import Shared

struct TimelineFilterSessionState {
    var filterCriteria: FilterCriteria = .none
    var pendingFilterCriteria: FilterCriteria = .none
    var isFilterPanelVisible = false
    var isFilterDropdownOpen = false
    var isDateRangeCalendarEditing = false
    var activeFilterDropdown: SimpleTimelineViewModel.FilterDropdownType = .none
    var filterDropdownAnchorFrame: CGRect = .zero
    var filterAnchorFrames: [SimpleTimelineViewModel.FilterDropdownType: CGRect] = [:]
    var requiresFullReloadOnNextRefresh = false
}

struct TimelineFilterSessionApplyResult {
    let preparation: TimelineFilterApplyPreparation
    let resultingCriteria: FilterCriteria

    var requiresReload: Bool {
        preparation.requiresReload
    }
}

struct TimelineFilterSupportDataState {
    var availableAppsForFilter: [(bundleID: String, name: String)] = []
    var otherAppsForFilter: [(bundleID: String, name: String)] = []
    var isLoadingAppsForFilter = false
    var isRefreshingRewindAppsForFilter = false
    var hiddenSegmentIDs: Set<SegmentID> = []
}

final class TimelineFilterSessionController {
    private(set) var state = TimelineFilterSessionState()

    func setFilterCriteria(_ criteria: FilterCriteria) {
        state.filterCriteria = criteria
    }

    func setPendingFilterCriteria(_ criteria: FilterCriteria) {
        state.pendingFilterCriteria = criteria
    }

    func replaceCriteria(_ criteria: FilterCriteria) {
        state.filterCriteria = criteria
        state.pendingFilterCriteria = criteria
    }

    func clearCriteria() {
        replaceCriteria(.none)
    }

    func clearPendingCriteria() {
        state.pendingFilterCriteria = .none
    }

    func setPanelVisible(_ isVisible: Bool) {
        state.isFilterPanelVisible = isVisible
    }

    func setFilterDropdownOpen(_ isOpen: Bool) {
        state.isFilterDropdownOpen = isOpen
    }

    func setDateRangeCalendarEditing(_ isEditing: Bool) {
        state.isDateRangeCalendarEditing = isEditing
    }

    func setActiveFilterDropdown(_ dropdown: SimpleTimelineViewModel.FilterDropdownType) {
        state.activeFilterDropdown = dropdown
    }

    func setFilterDropdownAnchorFrame(_ frame: CGRect) {
        state.filterDropdownAnchorFrame = frame
    }

    func setFilterAnchorFrames(_ frames: [SimpleTimelineViewModel.FilterDropdownType: CGRect]) {
        state.filterAnchorFrames = frames
    }

    func showDropdown(_ type: SimpleTimelineViewModel.FilterDropdownType, anchorFrame: CGRect) {
        applyDropdownState(
            TimelineFilterStateSupport.showingDropdown(
                type: type,
                anchorFrame: anchorFrame,
                filterAnchorFrames: state.filterAnchorFrames,
                isDateRangeCalendarEditing: state.isDateRangeCalendarEditing
            )
        )
    }

    func dismissDropdown() {
        applyDropdownState(
            TimelineFilterStateSupport.dismissingDropdown(
                anchorFrame: state.filterDropdownAnchorFrame,
                filterAnchorFrames: state.filterAnchorFrames
            )
        )
    }

    func openPanel(appliedCriteria: FilterCriteria) {
        dismissDropdown()
        replaceCriteria(appliedCriteria)
        state.isFilterPanelVisible = true
    }

    func dismissPanel(appliedCriteria: FilterCriteria) {
        replaceCriteria(appliedCriteria)
        dismissDropdown()
        state.isFilterPanelVisible = false
    }

    func dismissFilterUI() {
        dismissDropdown()
        state.isFilterPanelVisible = false
    }

    func applyPendingFilters(dismissPanel shouldDismissPanel: Bool) -> TimelineFilterSessionApplyResult {
        let preparation = TimelineFilterStateSupport.prepareApply(
            current: state.filterCriteria,
            pending: state.pendingFilterCriteria
        )

        state.filterCriteria = preparation.normalizedCurrentCriteria
        state.pendingFilterCriteria = preparation.normalizedPendingCriteria

        let resultingCriteria: FilterCriteria
        if preparation.requiresReload {
            resultingCriteria = preparation.normalizedPendingCriteria
            replaceCriteria(resultingCriteria)
        } else {
            resultingCriteria = preparation.normalizedCurrentCriteria
        }

        if shouldDismissPanel {
            dismissPanel(appliedCriteria: resultingCriteria)
        }

        return TimelineFilterSessionApplyResult(
            preparation: preparation,
            resultingCriteria: resultingCriteria
        )
    }

    @discardableResult
    func clearWithoutReload() -> Bool {
        guard state.filterCriteria.hasActiveFilters || state.pendingFilterCriteria.hasActiveFilters else {
            return false
        }

        clearCriteria()
        state.requiresFullReloadOnNextRefresh = true
        dismissFilterUI()
        return true
    }

    func consumeRequiresFullReloadOnNextRefresh() -> Bool {
        let requiresFullReload = state.requiresFullReloadOnNextRefresh
        state.requiresFullReloadOnNextRefresh = false
        return requiresFullReload
    }

    private func applyDropdownState(_ dropdownState: TimelineFilterDropdownState) {
        state.filterDropdownAnchorFrame = dropdownState.filterDropdownAnchorFrame
        state.filterAnchorFrames = dropdownState.filterAnchorFrames
        state.activeFilterDropdown = dropdownState.activeFilterDropdown
        state.isFilterDropdownOpen = dropdownState.isFilterDropdownOpen
        state.isDateRangeCalendarEditing = dropdownState.isDateRangeCalendarEditing
    }
}

struct TimelineFilterApplyPreparation: Equatable {
    let normalizedCurrentCriteria: FilterCriteria
    let normalizedPendingCriteria: FilterCriteria

    var requiresReload: Bool {
        normalizedCurrentCriteria != normalizedPendingCriteria
    }
}

struct TimelineFilterDropdownState: Equatable {
    let activeFilterDropdown: SimpleTimelineViewModel.FilterDropdownType
    let filterDropdownAnchorFrame: CGRect
    let filterAnchorFrames: [SimpleTimelineViewModel.FilterDropdownType: CGRect]
    let isFilterDropdownOpen: Bool
    let isDateRangeCalendarEditing: Bool
}

struct TimelineFilterCacheSupport {
    enum SaveResult {
        case saved
        case clearedInactive
        case failed(Error)
    }

    enum RestoreResult {
        case missingSavedAt
        case missingCriteriaData
        case expired(elapsedSeconds: TimeInterval)
        case restored(FilterCriteria, elapsedSeconds: TimeInterval)
        case failed(Error)
    }

    static let defaultCriteriaKey = "timeline.cachedFilterCriteria"
    static let defaultSavedAtKey = "timeline.cachedFilterSavedAt"
    static let defaultExpirationSeconds: TimeInterval = 120

    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Date
    private let criteriaKey: String
    private let savedAtKey: String
    private let expirationSeconds: TimeInterval

    init(
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        criteriaKey: String = Self.defaultCriteriaKey,
        savedAtKey: String = Self.defaultSavedAtKey,
        expirationSeconds: TimeInterval = Self.defaultExpirationSeconds
    ) {
        self.userDefaults = userDefaults
        self.now = now
        self.criteriaKey = criteriaKey
        self.savedAtKey = savedAtKey
        self.expirationSeconds = expirationSeconds
    }

    func save(criteria: FilterCriteria) -> SaveResult {
        guard criteria.hasActiveFilters else {
            clear()
            return .clearedInactive
        }

        do {
            let data = try JSONEncoder().encode(criteria)
            userDefaults.set(data, forKey: criteriaKey)
            userDefaults.set(now().timeIntervalSince1970, forKey: savedAtKey)
            return .saved
        } catch {
            return .failed(error)
        }
    }

    func restore() -> RestoreResult {
        let savedAt = userDefaults.double(forKey: savedAtKey)
        guard savedAt > 0 else {
            return .missingSavedAt
        }

        let elapsed = now().timeIntervalSince(Date(timeIntervalSince1970: savedAt))
        guard elapsed < expirationSeconds else {
            clear()
            return .expired(elapsedSeconds: elapsed)
        }

        guard let data = userDefaults.data(forKey: criteriaKey) else {
            return .missingCriteriaData
        }

        do {
            let criteria = try JSONDecoder().decode(FilterCriteria.self, from: data)
            return .restored(criteria, elapsedSeconds: elapsed)
        } catch {
            return .failed(error)
        }
    }

    func clear() {
        userDefaults.removeObject(forKey: criteriaKey)
        userDefaults.removeObject(forKey: savedAtKey)
    }
}

struct TimelineRewindAppBundleIDCacheContext: Codable, Equatable {
    let cutoffDate: Date
    let effectiveRewindDatabasePath: String
    let useRewindData: Bool
}

struct TimelineRewindAppBundleIDCachePayload: Codable {
    let version: Int
    let bundleIDs: [String]
    let context: TimelineRewindAppBundleIDCacheContext
}

enum TimelineRewindAppBundleIDCacheReadResult {
    case cacheHit([String])
    case cacheMiss
    case invalidate(String)
}

enum TimelineFilterStateSupport {
    static func normalizedCriteria(_ criteria: FilterCriteria) -> FilterCriteria {
        var normalized = criteria
        normalized.selectedSources = nil
        return normalized
    }

    static func prepareApply(current: FilterCriteria, pending: FilterCriteria) -> TimelineFilterApplyPreparation {
        TimelineFilterApplyPreparation(
            normalizedCurrentCriteria: normalizedCriteria(current),
            normalizedPendingCriteria: normalizedCriteria(pending)
        )
    }

    static func toggledApp(_ bundleID: String, in criteria: FilterCriteria) -> FilterCriteria {
        var updated = criteria
        var apps = updated.selectedApps ?? Set<String>()
        if apps.contains(bundleID) {
            apps.remove(bundleID)
        } else {
            apps.insert(bundleID)
        }
        updated.selectedApps = apps.isEmpty ? nil : apps
        return updated
    }

    static func toggledTag(_ tagID: Int64, in criteria: FilterCriteria) -> FilterCriteria {
        var updated = criteria
        var tags = updated.selectedTags ?? Set<Int64>()
        if tags.contains(tagID) {
            tags.remove(tagID)
        } else {
            tags.insert(tagID)
        }
        updated.selectedTags = tags.isEmpty ? nil : tags
        return updated
    }

    static func settingHiddenFilter(_ mode: HiddenFilter, in criteria: FilterCriteria) -> FilterCriteria {
        var updated = criteria
        updated.hiddenFilter = mode
        return updated
    }

    static func settingCommentFilter(_ mode: CommentFilter, in criteria: FilterCriteria) -> FilterCriteria {
        var updated = criteria
        updated.commentFilter = mode
        return updated
    }

    static func settingAppFilterMode(_ mode: AppFilterMode, in criteria: FilterCriteria) -> FilterCriteria {
        var updated = criteria
        updated.appFilterMode = mode
        return updated
    }

    static func settingTagFilterMode(_ mode: TagFilterMode, in criteria: FilterCriteria) -> FilterCriteria {
        var updated = criteria
        updated.tagFilterMode = mode
        return updated
    }

    static func settingDateRanges(_ ranges: [DateRangeCriterion], in criteria: FilterCriteria) -> FilterCriteria {
        var updated = criteria
        let sanitizedRanges = Array(ranges.filter(\.hasBounds).prefix(5))
        updated.dateRanges = sanitizedRanges
        if let first = sanitizedRanges.first {
            updated.startDate = first.start
            updated.endDate = first.end
        } else {
            updated.startDate = nil
            updated.endDate = nil
        }
        return updated
    }

    static func summarizeFiltersForLog(_ filters: FilterCriteria) -> String {
        let appCount = filters.selectedApps?.count ?? 0
        let tagCount = filters.selectedTags?.count ?? 0
        let hasWindowFilter = !(filters.windowNameFilter?.isEmpty ?? true)
        let hasURLFilter = !(filters.browserUrlFilter?.isEmpty ?? true)
        let hasDateRange = !filters.effectiveDateRanges.isEmpty

        return "active=\(filters.hasActiveFilters) count=\(filters.activeFilterCount) apps=\(appCount) tags=\(tagCount) appMode=\(filters.appFilterMode.rawValue) hidden=\(filters.hiddenFilter.rawValue) comments=\(filters.commentFilter.rawValue) window=\(hasWindowFilter) url=\(hasURLFilter) date=\(hasDateRange)"
    }

    static func showingDropdown(
        type: SimpleTimelineViewModel.FilterDropdownType,
        anchorFrame: CGRect,
        filterAnchorFrames: [SimpleTimelineViewModel.FilterDropdownType: CGRect],
        isDateRangeCalendarEditing: Bool
    ) -> TimelineFilterDropdownState {
        var updatedAnchorFrames = filterAnchorFrames
        updatedAnchorFrames[type] = anchorFrame
        return TimelineFilterDropdownState(
            activeFilterDropdown: type,
            filterDropdownAnchorFrame: anchorFrame,
            filterAnchorFrames: updatedAnchorFrames,
            isFilterDropdownOpen: type != .none && type != .advanced,
            isDateRangeCalendarEditing: type == .dateRange ? isDateRangeCalendarEditing : false
        )
    }

    static func dismissingDropdown(
        anchorFrame: CGRect,
        filterAnchorFrames: [SimpleTimelineViewModel.FilterDropdownType: CGRect]
    ) -> TimelineFilterDropdownState {
        TimelineFilterDropdownState(
            activeFilterDropdown: .none,
            filterDropdownAnchorFrame: anchorFrame,
            filterAnchorFrames: filterAnchorFrames,
            isFilterDropdownOpen: false,
            isDateRangeCalendarEditing: false
        )
    }
}

final class TimelineFilterSupportDataController {
    struct AvailableAppsLoadPlan: Equatable {
        let rewindCacheContext: TimelineRewindAppBundleIDCacheContext
        let needsInstalledApps: Bool
        let needsHistoricalApps: Bool

        var shouldResetHistoricalApps: Bool {
            needsHistoricalApps && hasLoadedHistoricalAppsForFilter
        }

        fileprivate let hasLoadedHistoricalAppsForFilter: Bool
    }

    enum AvailableAppsLoadDecision: Equatable {
        case start(AvailableAppsLoadPlan)
        case skipAlreadyLoaded
    }

    private(set) var state = TimelineFilterSupportDataState()
    private var hasLoadedInstalledAppsForFilter = false
    private var hasLoadedHistoricalAppsForFilter = false
    private var lastHistoricalAppsForFilterContext: TimelineRewindAppBundleIDCacheContext?
    private var availableAppsForFilterLoadTask: Task<Void, Never>?
    private var filterPanelSupportingDataLoadTask: Task<Void, Never>?

    var hasPendingAvailableAppsLoad: Bool {
        availableAppsForFilterLoadTask != nil
    }

    var hasPendingSupportingDataLoad: Bool {
        filterPanelSupportingDataLoadTask != nil
    }

    func setLoadingAppsForFilter(_ isLoading: Bool) {
        state.isLoadingAppsForFilter = isLoading
    }

    func setRefreshingRewindAppsForFilter(_ isRefreshing: Bool) {
        state.isRefreshingRewindAppsForFilter = isRefreshing
    }

    func setAvailableAppsForFilter(_ apps: [(bundleID: String, name: String)]) {
        state.availableAppsForFilter = apps
    }

    func setOtherAppsForFilter(_ apps: [(bundleID: String, name: String)]) {
        state.otherAppsForFilter = apps
    }

    func setHiddenSegmentIDs(_ segmentIDs: Set<SegmentID>) {
        state.hiddenSegmentIDs = segmentIDs
    }

    func insertHiddenSegmentID(_ segmentID: SegmentID) {
        state.hiddenSegmentIDs.insert(segmentID)
    }

    func removeHiddenSegmentID(_ segmentID: SegmentID) {
        state.hiddenSegmentIDs.remove(segmentID)
    }

    func availableAppsLoadDecision(
        rewindCacheContext: TimelineRewindAppBundleIDCacheContext
    ) -> AvailableAppsLoadDecision {
        let needsInstalledApps = !hasLoadedInstalledAppsForFilter
        let needsHistoricalApps = !hasLoadedHistoricalAppsForFilter || lastHistoricalAppsForFilterContext != rewindCacheContext
        guard needsInstalledApps || needsHistoricalApps else {
            return .skipAlreadyLoaded
        }

        return .start(
            AvailableAppsLoadPlan(
                rewindCacheContext: rewindCacheContext,
                needsInstalledApps: needsInstalledApps,
                needsHistoricalApps: needsHistoricalApps,
                hasLoadedHistoricalAppsForFilter: hasLoadedHistoricalAppsForFilter
            )
        )
    }

    func markInstalledAppsLoaded() {
        hasLoadedInstalledAppsForFilter = true
    }

    func markHistoricalAppsLoaded(
        rewindCacheContext: TimelineRewindAppBundleIDCacheContext
    ) {
        hasLoadedHistoricalAppsForFilter = true
        lastHistoricalAppsForFilterContext = rewindCacheContext
    }

    func startAvailableAppsLoadIfNeeded(
        rewindCacheContext: TimelineRewindAppBundleIDCacheContext,
        action: @escaping @MainActor () async -> Void
    ) {
        guard case .start = availableAppsLoadDecision(rewindCacheContext: rewindCacheContext) else { return }
        guard availableAppsForFilterLoadTask == nil else { return }

        availableAppsForFilterLoadTask = Task { @MainActor [weak self] in
            defer { self?.availableAppsForFilterLoadTask = nil }
            await action()
        }
    }

    func cancelAvailableAppsLoad() {
        availableAppsForFilterLoadTask?.cancel()
        availableAppsForFilterLoadTask = nil
    }

    func scheduleSupportingDataLoad(
        delay: Duration = .milliseconds(200),
        skip: Bool = false,
        action: @escaping @MainActor () async -> Void
    ) {
        guard !skip else { return }

        filterPanelSupportingDataLoadTask?.cancel()
        filterPanelSupportingDataLoadTask = Task { @MainActor [weak self] in
            defer { self?.filterPanelSupportingDataLoadTask = nil }
            try? await Task.sleep(for: delay, clock: .continuous)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    func cancelSupportingDataLoad() {
        filterPanelSupportingDataLoadTask?.cancel()
        filterPanelSupportingDataLoadTask = nil
    }

    func cancelPendingWork() {
        cancelAvailableAppsLoad()
        cancelSupportingDataLoad()
    }
}
