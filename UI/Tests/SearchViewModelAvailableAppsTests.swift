import App
import Shared
import XCTest
@testable import Retrace

@MainActor
final class SearchViewModelAvailableAppsTests: XCTestCase {
    func testAvailableAppsDeduplicatesDuplicateBundleIDsAndPrefersInstalledEntries() {
        let viewModel = SearchViewModel(coordinator: AppCoordinator())
        viewModel.installedApps = [
            AppInfo(bundleID: "com.apple.Safari", name: "Safari"),
            AppInfo(bundleID: "com.google.Chrome", name: "Chrome")
        ]
        viewModel.otherApps = [
            AppInfo(bundleID: "com.apple.Safari", name: "Safari (DB)"),
            AppInfo(bundleID: "com.microsoft.edgemac", name: "Edge")
        ]

        XCTAssertEqual(
            viewModel.availableApps.map(\.bundleID),
            ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac"]
        )
        XCTAssertEqual(
            viewModel.availableApps.first(where: { $0.bundleID == "com.apple.Safari" })?.name,
            "Safari"
        )
    }

    func testTimelineRewindAppBundleIDsCacheReturnsValuesWhenContextMatches() async {
        let cacheURL = makeTimelineRewindCacheURL()
        let context = makeRewindCacheContext()

        await SimpleTimelineViewModel.saveCachedRewindAppBundleIDs(
            ["com.rewind.b", "com.rewind.a", "com.rewind.b"],
            context: context,
            to: cacheURL
        )

        let loadedBundleIDs = await SimpleTimelineViewModel.loadCachedRewindAppBundleIDs(
            matching: context,
            from: cacheURL
        )

        XCTAssertEqual(loadedBundleIDs, ["com.rewind.a", "com.rewind.b"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        await SimpleTimelineViewModel.removeCachedRewindAppBundleIDs(at: cacheURL)
    }

    func testTimelineRewindAppBundleIDsCacheInvalidatesWhenCutoffChanges() async {
        let cacheURL = makeTimelineRewindCacheURL()
        let cachedContext = makeRewindCacheContext(cutoffDate: Date(timeIntervalSince1970: 100))
        let liveContext = makeRewindCacheContext(cutoffDate: Date(timeIntervalSince1970: 200))

        await SimpleTimelineViewModel.saveCachedRewindAppBundleIDs(
            ["com.rewind.a"],
            context: cachedContext,
            to: cacheURL
        )

        let loadedBundleIDs = await SimpleTimelineViewModel.loadCachedRewindAppBundleIDs(
            matching: liveContext,
            from: cacheURL
        )

        XCTAssertNil(loadedBundleIDs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testTimelineRewindAppBundleIDsCacheInvalidatesWhenPathChanges() async {
        let cacheURL = makeTimelineRewindCacheURL()
        let cachedContext = makeRewindCacheContext(effectiveRewindDatabasePath: "/tmp/rewind-a/db-enc.sqlite3")
        let liveContext = makeRewindCacheContext(effectiveRewindDatabasePath: "/tmp/rewind-b/db-enc.sqlite3")

        await SimpleTimelineViewModel.saveCachedRewindAppBundleIDs(
            ["com.rewind.a"],
            context: cachedContext,
            to: cacheURL
        )

        let loadedBundleIDs = await SimpleTimelineViewModel.loadCachedRewindAppBundleIDs(
            matching: liveContext,
            from: cacheURL
        )

        XCTAssertNil(loadedBundleIDs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testTimelineRewindAppBundleIDsCacheInvalidatesWhenRewindIsDisabled() async {
        let cacheURL = makeTimelineRewindCacheURL()
        let cachedContext = makeRewindCacheContext(useRewindData: true)
        let liveContext = makeRewindCacheContext(useRewindData: false)

        await SimpleTimelineViewModel.saveCachedRewindAppBundleIDs(
            ["com.rewind.a"],
            context: cachedContext,
            to: cacheURL
        )

        let loadedBundleIDs = await SimpleTimelineViewModel.loadCachedRewindAppBundleIDs(
            matching: liveContext,
            from: cacheURL
        )

        XCTAssertNil(loadedBundleIDs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testOpenFilterPanelStartsAppLoadingImmediatelyBeforeSupportingDataDelay() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let installedApps = [AppInfo(bundleID: "com.apple.Safari", name: "Safari")]
        var nativeContinuation: CheckedContinuation<[String], Never>?

        viewModel.test_availableAppsForFilterHooks.getInstalledApps = {
            installedApps
        }
        viewModel.test_availableAppsForFilterHooks.getDistinctAppBundleIDs = { source in
            switch source {
            case .native:
                return await withCheckedContinuation { continuation in
                    nativeContinuation = continuation
                }
            case .rewind, nil, .screenMemory, .timeScroll, .pensieve, .unknown:
                return []
            }
        }
        viewModel.test_availableAppsForFilterHooks.resolveAllBundleIDs = { _ in [] }
        viewModel.test_availableAppsForFilterHooks.skipSupportingPanelDataLoad = true

        viewModel.openFilterPanel()
        await Task.yield()
        await Task.yield()
        await waitUntil { nativeContinuation != nil && viewModel.isLoadingAppsForFilter }

        XCTAssertTrue(viewModel.isFilterPanelVisible)
        XCTAssertTrue(viewModel.isLoadingAppsForFilter)
        XCTAssertEqual(viewModel.availableAppsForFilter.map(\.bundleID), ["com.apple.Safari"])
        XCTAssertTrue(viewModel.otherAppsForFilter.isEmpty)

        guard let nativeContinuation else {
            return XCTFail("Expected native app query continuation")
        }
        nativeContinuation.resume(returning: [])
        await waitUntil { !viewModel.isLoadingAppsForFilter }
    }

    func testLoadAvailableAppsForFilterShowsRewindRefreshStateWhileLiveQueryRuns() async {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let previousUseRewindData = defaults.object(forKey: "useRewindData")
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let installedApps = [AppInfo(bundleID: "com.apple.Safari", name: "Safari")]
        var rewindContinuation: CheckedContinuation<[String], Never>?

        defaults.set(true, forKey: "useRewindData")
        await SimpleTimelineViewModel.removeCachedRewindAppBundleIDs()
        defer {
            if let previousUseRewindData {
                defaults.set(previousUseRewindData, forKey: "useRewindData")
            } else {
                defaults.removeObject(forKey: "useRewindData")
            }
            Task {
                await SimpleTimelineViewModel.removeCachedRewindAppBundleIDs()
            }
        }

        viewModel.test_availableAppsForFilterHooks.getInstalledApps = {
            installedApps
        }
        viewModel.test_availableAppsForFilterHooks.getDistinctAppBundleIDs = { source in
            switch source {
            case .native:
                return []
            case .rewind:
                return await withCheckedContinuation { continuation in
                    rewindContinuation = continuation
                }
            case nil, .screenMemory, .timeScroll, .pensieve, .unknown:
                return []
            }
        }
        viewModel.test_availableAppsForFilterHooks.resolveAllBundleIDs = { _ in [] }

        let loadTask = Task {
            await viewModel.loadAvailableAppsForFilter()
        }

        await Task.yield()
        await Task.yield()
        await waitUntil { rewindContinuation != nil && viewModel.isRefreshingRewindAppsForFilter }

        XCTAssertEqual(viewModel.availableAppsForFilter.map(\.bundleID), ["com.apple.Safari"])
        XCTAssertTrue(viewModel.isLoadingAppsForFilter)
        XCTAssertTrue(viewModel.isRefreshingRewindAppsForFilter)
        XCTAssertTrue(viewModel.otherAppsForFilter.isEmpty)

        guard let rewindContinuation else {
            return XCTFail("Expected Rewind app query continuation")
        }
        rewindContinuation.resume(returning: [])
        await loadTask.value

        XCTAssertFalse(viewModel.isLoadingAppsForFilter)
        XCTAssertFalse(viewModel.isRefreshingRewindAppsForFilter)
    }

    private func makeTimelineRewindCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("timeline_rewind_app_bundle_ids.json")
    }

    private func makeRewindCacheContext(
        cutoffDate: Date = Date(timeIntervalSince1970: 123),
        effectiveRewindDatabasePath: String = "/tmp/rewind/db-enc.sqlite3",
        useRewindData: Bool = true
    ) -> SimpleTimelineViewModel.RewindAppBundleIDCacheContext {
        .init(
            cutoffDate: cutoffDate,
            effectiveRewindDatabasePath: effectiveRewindDatabasePath,
            useRewindData: useRewindData
        )
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
