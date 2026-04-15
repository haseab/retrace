import CoreGraphics
import Foundation
import App
import Shared

final class TimelineFilterStore {
    struct AvailableAppsLoadEnvironment {
        let rewindCacheContext: TimelineRewindAppBundleIDCacheContext
        let installedApps: () async -> [AppInfo]
        let distinctAppBundleIDs: (FrameSource?) async throws -> [String]
        let resolveApps: ([String]) async -> [AppInfo]
        let loadCachedRewindAppBundleIDs: (TimelineRewindAppBundleIDCacheContext) async -> [String]?
        let saveCachedRewindAppBundleIDs: ([String], TimelineRewindAppBundleIDCacheContext) async -> Void
        let removeCachedRewindAppBundleIDs: () async -> Void
        let invalidate: () -> Void
    }

    struct SupportingPanelDataLoadEnvironment {
        let needsTags: Bool
        let needsHiddenSegmentIDs: Bool
        let needsSegmentTagsMap: Bool
        let fetchAllTags: () async throws -> [Tag]
        let fetchHiddenSegmentIDs: () async throws -> Set<SegmentID>
        let fetchSegmentTagsMap: () async throws -> [Int64: Set<Int64>]
        let applyTags: ([Tag]) -> Void
        let applyHiddenSegmentIDs: (Set<SegmentID>) -> Void
        let applySegmentTagsMap: ([Int64: Set<Int64>]) -> Void
    }

    nonisolated private static let rewindAppBundleIDCacheVersion = 1

    nonisolated static var cachedRewindAppBundleIDsPath: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("timeline_rewind_app_bundle_ids.json")
    }

    private let sessionController = TimelineFilterSessionController()
    private let supportDataController = TimelineFilterSupportDataController()
    private let cache = TimelineFilterCacheSupport()

    var sessionState: TimelineFilterSessionState {
        sessionController.state
    }

    var supportDataState: TimelineFilterSupportDataState {
        supportDataController.state
    }

    var hiddenSegmentIDs: Set<SegmentID> {
        supportDataController.state.hiddenSegmentIDs
    }

    func saveCriteriaCache(_ criteria: FilterCriteria) -> TimelineFilterCacheSupport.SaveResult {
        cache.save(criteria: criteria)
    }

    func restoreCriteriaCache() -> TimelineFilterCacheSupport.RestoreResult {
        cache.restore()
    }

    func clearCriteriaCache() {
        cache.clear()
    }

    @discardableResult
    @MainActor
    private func updateSession<T>(
        invalidate: () -> Void,
        mutation: (TimelineFilterSessionController) -> T
    ) -> T {
        invalidate()
        return mutation(sessionController)
    }

    @MainActor
    func showDropdown(
        _ type: SimpleTimelineViewModel.FilterDropdownType,
        anchorFrame: CGRect,
        invalidate: () -> Void
    ) {
        updateSession(invalidate: invalidate) {
            $0.showDropdown(type, anchorFrame: anchorFrame)
        }
    }

    @MainActor
    func dismissDropdown(invalidate: () -> Void) {
        updateSession(invalidate: invalidate) { $0.dismissDropdown() }
    }

    @MainActor
    func setFilterAnchorFrames(
        _ frames: [SimpleTimelineViewModel.FilterDropdownType: CGRect],
        activeDropdown: SimpleTimelineViewModel.FilterDropdownType,
        currentType: SimpleTimelineViewModel.FilterDropdownType,
        anchorFrame: CGRect,
        invalidate: () -> Void
    ) {
        updateSession(invalidate: invalidate) {
            $0.setFilterAnchorFrames(frames)
            if activeDropdown == currentType {
                $0.setFilterDropdownAnchorFrame(anchorFrame)
            }
        }
    }

    @MainActor
    func setDateRangeCalendarEditing(
        _ isEditing: Bool,
        invalidate: () -> Void
    ) {
        updateSession(invalidate: invalidate) { $0.setDateRangeCalendarEditing(isEditing) }
    }

    @MainActor
    func setFilterCriteria(
        _ criteria: FilterCriteria,
        invalidate: () -> Void
    ) {
        updateSession(invalidate: invalidate) { $0.setFilterCriteria(criteria) }
    }

    @MainActor
    func setPanelVisible(
        _ isVisible: Bool,
        invalidate: () -> Void
    ) {
        updateSession(invalidate: invalidate) { $0.setPanelVisible(isVisible) }
    }

    @MainActor
    func setPendingFilterCriteria(
        _ criteria: FilterCriteria,
        invalidate: () -> Void
    ) {
        updateSession(invalidate: invalidate) { $0.setPendingFilterCriteria(criteria) }
    }

    @MainActor
    func replaceCriteria(
        _ criteria: FilterCriteria,
        invalidate: () -> Void
    ) {
        updateSession(invalidate: invalidate) { $0.replaceCriteria(criteria) }
    }

    @MainActor
    func clearCriteria(invalidate: () -> Void) {
        updateSession(invalidate: invalidate) { $0.clearCriteria() }
    }

    @MainActor
    func clearPendingCriteria(invalidate: () -> Void) {
        updateSession(invalidate: invalidate) { $0.clearPendingCriteria() }
    }

    @MainActor
    func dismissPanel(
        appliedCriteria: FilterCriteria,
        invalidate: () -> Void
    ) {
        updateSession(invalidate: invalidate) {
            $0.dismissPanel(appliedCriteria: appliedCriteria)
        }
    }

    @MainActor
    func openPanel(
        appliedCriteria: FilterCriteria,
        invalidate: () -> Void
    ) {
        updateSession(invalidate: invalidate) {
            $0.openPanel(appliedCriteria: appliedCriteria)
        }
    }

    @MainActor
    func dismissFilterUI(invalidate: () -> Void) {
        updateSession(invalidate: invalidate) { $0.dismissFilterUI() }
    }

    @MainActor
    func applyPendingFilters(
        dismissPanel: Bool,
        invalidate: () -> Void
    ) -> TimelineFilterSessionApplyResult {
        updateSession(invalidate: invalidate) {
            $0.applyPendingFilters(dismissPanel: dismissPanel)
        }
    }

    @MainActor
    func clearWithoutReload(invalidate: () -> Void) -> Bool {
        updateSession(invalidate: invalidate) { $0.clearWithoutReload() }
    }

    @MainActor
    func consumeRequiresFullReloadOnNextRefresh(invalidate: () -> Void) -> Bool {
        updateSession(invalidate: invalidate) { $0.consumeRequiresFullReloadOnNextRefresh() }
    }

    nonisolated static func currentRewindAppBundleIDCacheContext() -> TimelineRewindAppBundleIDCacheContext {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return TimelineRewindAppBundleIDCacheContext(
            cutoffDate: ServiceContainer.rewindCutoffDate(in: defaults),
            effectiveRewindDatabasePath: normalizedFilesystemPath(AppPaths.rewindDBPath),
            useRewindData: defaults.bool(forKey: "useRewindData")
        )
    }

    nonisolated static func loadCachedRewindAppBundleIDs(
        matching context: TimelineRewindAppBundleIDCacheContext,
        from fileURL: URL? = nil
    ) async -> [String]? {
        let url = fileURL ?? cachedRewindAppBundleIDsPath

        let readResult = await Task.detached(priority: .utility) { () -> TimelineRewindAppBundleIDCacheReadResult in
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .cacheMiss
            }

            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let payload = try JSONDecoder().decode(TimelineRewindAppBundleIDCachePayload.self, from: data)

                guard payload.version == Self.rewindAppBundleIDCacheVersion else {
                    return .invalidate("version mismatch")
                }

                guard payload.context == context else {
                    var mismatches: [String] = []
                    if payload.context.cutoffDate != context.cutoffDate {
                        mismatches.append("cutoffDate")
                    }
                    if payload.context.effectiveRewindDatabasePath != context.effectiveRewindDatabasePath {
                        mismatches.append("effectiveRewindDatabasePath")
                    }
                    if payload.context.useRewindData != context.useRewindData {
                        mismatches.append("useRewindData")
                    }

                    let mismatchDescription = mismatches.isEmpty ? "context mismatch" : "context mismatch: \(mismatches.joined(separator: ", "))"
                    return .invalidate(mismatchDescription)
                }

                return .cacheHit(Self.normalizedRewindAppBundleIDs(payload.bundleIDs))
            } catch {
                return .invalidate("decode failed: \(error.localizedDescription)")
            }
        }.value

        switch readResult {
        case .cacheHit(let bundleIDs):
            return bundleIDs
        case .cacheMiss:
            return nil
        case .invalidate(let reason):
            Log.info("[Filter] Invalidating Rewind app bundle ID cache (\(reason))", category: .ui)
            await removeCachedRewindAppBundleIDs(at: url)
            return nil
        }
    }

    nonisolated static func saveCachedRewindAppBundleIDs(
        _ bundleIDs: [String],
        context: TimelineRewindAppBundleIDCacheContext,
        to fileURL: URL? = nil
    ) async {
        let url = fileURL ?? cachedRewindAppBundleIDsPath
        let payload = TimelineRewindAppBundleIDCachePayload(
            version: rewindAppBundleIDCacheVersion,
            bundleIDs: normalizedRewindAppBundleIDs(bundleIDs),
            context: context
        )

        do {
            try await Task.detached(priority: .utility) {
                let directoryURL = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: .atomic)
            }.value
        } catch {
            Log.error("[Filter] Failed to save cached Rewind app bundle IDs: \(error)", category: .ui)
        }
    }

    nonisolated static func removeCachedRewindAppBundleIDs(at fileURL: URL? = nil) async {
        let url = fileURL ?? cachedRewindAppBundleIDsPath
        do {
            try await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                try FileManager.default.removeItem(at: url)
            }.value
        } catch {
            Log.error("[Filter] Failed to remove cached Rewind app bundle IDs: \(error)", category: .ui)
        }
    }

    @MainActor
    func loadAvailableAppsForFilter(environment: AvailableAppsLoadEnvironment) async {
        guard !supportDataController.state.isLoadingAppsForFilter else {
            Log.debug("[Filter] loadAvailableAppsForFilter skipped - already loading", category: .ui)
            return
        }

        let loadDecision = supportDataController.availableAppsLoadDecision(
            rewindCacheContext: environment.rewindCacheContext
        )
        guard case let .start(loadPlan) = loadDecision else {
            Log.debug(
                "[Filter] loadAvailableAppsForFilter skipped - already have \(supportDataController.state.availableAppsForFilter.count) apps",
                category: .ui
            )
            return
        }

        updateSupportData(invalidate: environment.invalidate) {
            $0.setLoadingAppsForFilter(true)
            $0.setRefreshingRewindAppsForFilter(false)
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            updateSupportData(invalidate: environment.invalidate) {
                $0.setLoadingAppsForFilter(false)
                $0.setRefreshingRewindAppsForFilter(false)
            }
        }

        if loadPlan.shouldResetHistoricalApps {
            updateSupportData(invalidate: environment.invalidate) {
                $0.setOtherAppsForFilter([])
            }
        }

        let installed: [AppInfo]
        if loadPlan.needsInstalledApps {
            installed = await environment.installedApps()
        } else {
            installed = supportDataController.state.availableAppsForFilter.map {
                AppInfo(bundleID: $0.bundleID, name: $0.name)
            }
        }
        let installedBundleIDs = Set(installed.map(\.bundleID))
        let allApps = installed.map { (bundleID: $0.bundleID, name: $0.name) }
        Log.info(
            "[Filter] Phase 1: Loaded \(allApps.count) installed apps in \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms",
            category: .ui
        )

        guard !Task.isCancelled else { return }

        if loadPlan.needsInstalledApps {
            updateSupportData(invalidate: environment.invalidate) {
                $0.setAvailableAppsForFilter(
                    allApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                )
            }
            supportDataController.markInstalledAppsLoaded()
        }

        if loadPlan.needsHistoricalApps {
            let historicalApps = await loadHistoricalAppsForFilter(
                installedBundleIDs: installedBundleIDs,
                environment: environment
            )
            guard !Task.isCancelled else { return }
            updateSupportData(invalidate: environment.invalidate) {
                $0.setOtherAppsForFilter(historicalApps)
            }
            supportDataController.markHistoricalAppsLoaded(
                rewindCacheContext: loadPlan.rewindCacheContext
            )
            if !historicalApps.isEmpty {
                Log.info(
                    "[Filter] Phase 2: Added \(historicalApps.count) historical apps to otherAppsForFilter",
                    category: .ui
                )
            }
        }

        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        Log.info(
            "[Filter] Total: \(supportDataController.state.availableAppsForFilter.count) installed + \(supportDataController.state.otherAppsForFilter.count) other apps loaded in \(Int(totalTime * 1000))ms",
            category: .ui
        )
    }

    @MainActor
    func startAvailableAppsLoadIfNeeded(
        rewindCacheContext: TimelineRewindAppBundleIDCacheContext,
        action: @escaping @MainActor () async -> Void
    ) {
        supportDataController.startAvailableAppsLoadIfNeeded(
            rewindCacheContext: rewindCacheContext,
            action: action
        )
    }

    @MainActor
    func scheduleSupportingDataLoad(
        delay: Duration = .milliseconds(200),
        skip: Bool = false,
        action: @escaping @MainActor () async -> Void
    ) {
        supportDataController.scheduleSupportingDataLoad(
            delay: delay,
            skip: skip,
            action: action
        )
    }

    func cancelSupportingDataLoad() {
        supportDataController.cancelSupportingDataLoad()
    }

    func cancelPendingWork() {
        supportDataController.cancelPendingWork()
    }

    func setHiddenSegmentIDs(
        _ segmentIDs: Set<SegmentID>,
        invalidate: () -> Void
    ) {
        updateSupportData(invalidate: invalidate) {
            $0.setHiddenSegmentIDs(segmentIDs)
        }
    }

    func insertHiddenSegmentID(
        _ segmentID: SegmentID,
        invalidate: () -> Void
    ) {
        updateSupportData(invalidate: invalidate) {
            $0.insertHiddenSegmentID(segmentID)
        }
    }

    func removeHiddenSegmentID(
        _ segmentID: SegmentID,
        invalidate: () -> Void
    ) {
        updateSupportData(invalidate: invalidate) {
            $0.removeHiddenSegmentID(segmentID)
        }
    }

    @MainActor
    func loadSupportingPanelDataIfNeeded(
        environment: SupportingPanelDataLoadEnvironment
    ) async {
        guard environment.needsTags
            || environment.needsHiddenSegmentIDs
            || environment.needsSegmentTagsMap else {
            return
        }

        var loadedTags: [Tag]?
        var loadedHiddenSegmentIDs: Set<SegmentID>?
        var loadedSegmentTagsMap: [Int64: Set<Int64>]?

        if environment.needsTags {
            do {
                loadedTags = try await environment.fetchAllTags()
            } catch {
                Log.error("[Filter] Failed to load tags: \(error)", category: .ui)
            }
        }

        if environment.needsHiddenSegmentIDs {
            do {
                loadedHiddenSegmentIDs = try await environment.fetchHiddenSegmentIDs()
            } catch {
                Log.error("[Filter] Failed to load hidden segments: \(error)", category: .ui)
            }
        }

        if environment.needsSegmentTagsMap {
            do {
                loadedSegmentTagsMap = try await environment.fetchSegmentTagsMap()
            } catch {
                Log.error("[Filter] Failed to load segment tags map: \(error)", category: .ui)
            }
        }

        if let loadedTags {
            environment.applyTags(loadedTags)
        }

        if let loadedHiddenSegmentIDs {
            environment.applyHiddenSegmentIDs(loadedHiddenSegmentIDs)
        }

        if let loadedSegmentTagsMap {
            environment.applySegmentTagsMap(loadedSegmentTagsMap)
        }
    }

    @MainActor
    func loadSupportingPanelDataIfNeeded(
        commentsStore: TimelineCommentsStore,
        fetchAllTags: @escaping () async throws -> [Tag],
        fetchHiddenSegmentIDs: @escaping () async throws -> Set<SegmentID>,
        fetchSegmentTagsMap: @escaping () async throws -> [Int64: Set<Int64>],
        invalidateComments: @escaping () -> Void,
        invalidateFilters: @escaping () -> Void,
        didUpdateAvailableTags: @escaping () -> Void,
        didUpdateSegmentTagsMap: @escaping () -> Void
    ) async {
        await loadSupportingPanelDataIfNeeded(
            environment: SupportingPanelDataLoadEnvironment(
                needsTags: !commentsStore.tagIndicatorState.hasLoadedAvailableTags,
                needsHiddenSegmentIDs: hiddenSegmentIDs.isEmpty,
                needsSegmentTagsMap: !commentsStore.tagIndicatorState.hasLoadedSegmentTagsMap,
                fetchAllTags: fetchAllTags,
                fetchHiddenSegmentIDs: fetchHiddenSegmentIDs,
                fetchSegmentTagsMap: fetchSegmentTagsMap,
                applyTags: { tags in
                    commentsStore.setAvailableTags(tags, invalidate: invalidateComments)
                    didUpdateAvailableTags()
                },
                applyHiddenSegmentIDs: { hiddenSegmentIDs in
                    self.setHiddenSegmentIDs(hiddenSegmentIDs, invalidate: invalidateFilters)
                },
                applySegmentTagsMap: { segmentTagsMap in
                    commentsStore.setSegmentTagsMap(segmentTagsMap, invalidate: invalidateComments)
                    didUpdateSegmentTagsMap()
                    Log.debug("[Filter] Loaded tags for \(segmentTagsMap.count) segments", category: .ui)
                }
            )
        )
    }

    private func updateSupportData(
        invalidate: () -> Void,
        _ mutation: (TimelineFilterSupportDataController) -> Void
    ) {
        invalidate()
        mutation(supportDataController)
    }

    @MainActor
    private func loadHistoricalAppsForFilter(
        installedBundleIDs: Set<String>,
        environment: AvailableAppsLoadEnvironment
    ) async -> [(bundleID: String, name: String)] {
        async let nativeBundleIDsTask = environment.distinctAppBundleIDs(.native)

        var rewindBundleIDs: [String] = []
        if environment.rewindCacheContext.useRewindData {
            if let cachedBundleIDs = await environment.loadCachedRewindAppBundleIDs(environment.rewindCacheContext) {
                rewindBundleIDs = cachedBundleIDs
                Log.info("[Filter] Loaded \(cachedBundleIDs.count) Rewind app bundle IDs from cache", category: .ui)
            } else {
                updateSupportData(invalidate: environment.invalidate) {
                    $0.setRefreshingRewindAppsForFilter(true)
                }
                defer {
                    updateSupportData(invalidate: environment.invalidate) {
                        $0.setRefreshingRewindAppsForFilter(false)
                    }
                }

                do {
                    rewindBundleIDs = try await environment.distinctAppBundleIDs(.rewind)
                    await environment.saveCachedRewindAppBundleIDs(
                        rewindBundleIDs,
                        environment.rewindCacheContext
                    )
                    Log.info("[Filter] Cached \(rewindBundleIDs.count) Rewind app bundle IDs", category: .ui)
                } catch {
                    Log.error("[Filter] Failed to load Rewind app bundle IDs: \(error)", category: .ui)
                }
            }
        } else {
            await environment.removeCachedRewindAppBundleIDs()
        }

        var nativeBundleIDs: [String] = []
        do {
            nativeBundleIDs = try await nativeBundleIDsTask
        } catch {
            Log.error("[Filter] Failed to load native app bundle IDs: \(error)", category: .ui)
        }

        let bundleIDs = Array(Set(nativeBundleIDs).union(rewindBundleIDs)).sorted()
        guard !bundleIDs.isEmpty else {
            return []
        }

        let dbApps = await environment.resolveApps(bundleIDs)
        return dbApps
            .filter { !installedBundleIDs.contains($0.bundleID) }
            .map { (bundleID: $0.bundleID, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func normalizedFilesystemPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let resolved = NSString(string: expanded).resolvingSymlinksInPath
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
    }

    nonisolated private static func normalizedRewindAppBundleIDs(_ bundleIDs: [String]) -> [String] {
        Array(Set(bundleIDs)).sorted()
    }
}
