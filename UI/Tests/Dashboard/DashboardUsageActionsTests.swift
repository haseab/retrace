import XCTest
import Shared
import App
@testable import Retrace

@MainActor
final class DashboardUsageActionsTests: XCTestCase {
    func testBulkTargetsUseDatabaseMetadataAndExactRange() async throws {
        let (model, coordinator, database, start) = try await fixture()
        let app = AppUsageData(appBundleID: "com.google.Chrome", appName: "Chrome", duration: 10, uniqueItemCount: 3, percentage: 1)
        let website = DashboardUsageTarget.website(app: app, domain: "example.com")
        let siteFrames = try await model.prepareUsageAction(target: website, action: .hide)
        XCTAssertEqual(siteFrames.frames.count, 3)
        XCTAssertEqual(siteFrames.segmentIDs.count, 2)

        let tab = WindowUsageData(windowName: "Same title", browserUrl: "https://example.com/a", duration: 5, percentage: 1)
        let tabPlan = try await model.prepareUsageAction(target: .tab(app: app, window: tab), action: .hide)
        XCTAssertEqual(tabPlan.frames.count, 2)
        try await coordinator.hideSegments(segmentIds: tabPlan.segmentIDs)
        let remaining = try await model.prepareUsageAction(target: website, action: .delete)
        XCTAssertEqual(remaining.frames.count, 1, "Hidden segments must not be swept into a dashboard delete")
        XCTAssertEqual(remaining.frames.first?.metadata.browserURL, "https://example.com/b")
        let other = try await database.getFrames(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(100), limit: 100)
        XCTAssertEqual(other.count, 7, "Preparing and hiding must preserve recordings")
    }

    func testAppTargetIncludesAllRowsAndCancelDoesNotMutate() async throws {
        let (model, _, database, start) = try await fixture()
        let app = AppUsageData(appBundleID: "com.google.Chrome", appName: "Chrome", duration: 10, uniqueItemCount: 3, percentage: 1)
        let plan = try await model.prepareUsageAction(target: .app(app), action: .delete)
        XCTAssertEqual(plan.frames.count, 5)
        XCTAssertTrue(plan.frames.allSatisfy { $0.timestamp >= start && $0.timestamp <= start.addingTimeInterval(10) })
        let hidden = try await database.getHiddenSegmentIds()
        XCTAssertTrue(hidden.isEmpty)
        let frames = try await database.getFrames(from: start, to: start.addingTimeInterval(10), limit: 100)
        XCTAssertEqual(frames.count, 6)
    }

    func testConfirmedDeletePreservesSiblingTabsOtherAppsAndOutsideRange() async throws {
        let (model, _, database, start) = try await fixture()
        let app = AppUsageData(appBundleID: "com.google.Chrome", appName: "Chrome", duration: 10, uniqueItemCount: 3, percentage: 1)
        let tab = WindowUsageData(windowName: "Same title", browserUrl: "https://example.com/a", duration: 5, percentage: 1)
        let plan = try await model.prepareUsageAction(target: .tab(app: app, window: tab), action: .delete)
        _ = try await model.applyUsageAction(plan)
        let remaining = try await database.getFrames(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(100), limit: 100)
        XCTAssertEqual(remaining.count, 5)
        XCTAssertTrue(remaining.contains { $0.timestamp < start })
        XCTAssertTrue(remaining.contains { $0.metadata.appBundleID == "com.apple.Safari" })
        XCTAssertTrue(remaining.contains { $0.metadata.browserURL == "https://example.com/b" })
    }

    func testAppBulkActionIsNotLimitedToVisibleDashboardRows() async throws {
        let (model, coordinator, database, start) = try await fixture()
        for index in 0..<35 {
            let id = try await database.insertSegment(bundleID: "com.google.Chrome", startDate: start, endDate: start.addingTimeInterval(10), windowName: "Window \(index)", browserUrl: nil, type: 0)
            _ = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: start.addingTimeInterval(6), segmentID: AppSegmentID(value: id), frameIndexInSegment: 0, metadata: FrameMetadata()))
        }
        let app = AppUsageData(appBundleID: "com.google.Chrome", appName: "Chrome", duration: 10, uniqueItemCount: 38, percentage: 1)
        await model.loadStatistics(reason: "test_warm_historical_cache")
        XCTAssertTrue(model.weeklyAppUsage.contains { $0.appBundleID == app.appBundleID })
        let plan = try await model.prepareUsageAction(target: .app(app), action: .hide)
        XCTAssertEqual(plan.segmentIDs.count, 39)
        _ = try await model.applyUsageAction(plan)
        let hidden = try await coordinator.getHiddenSegmentIds()
        XCTAssertEqual(hidden, Set(plan.segmentIDs))
        XCTAssertFalse(model.weeklyAppUsage.contains { $0.appBundleID == app.appBundleID }, "Historical dashboard snapshots must be invalidated")
        let afterHide = try await model.prepareUsageAction(target: .app(app), action: .delete)
        XCTAssertTrue(afterHide.frames.isEmpty)
    }

    func testChunkBoundaryIsSelectedOnceAndEndIsInclusive() async throws {
        let (model, coordinator, database, start) = try await fixture()
        let boundary = start.addingTimeInterval(24 * 60 * 60)
        let id = try await database.insertSegment(bundleID: "com.google.Chrome", startDate: boundary, endDate: boundary, windowName: nil, browserUrl: nil, type: 0)
        let frameID = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: boundary, segmentID: AppSegmentID(value: id), frameIndexInSegment: 0, metadata: FrameMetadata()))
        let frames = try await coordinator.getDashboardUsageActionFrames(bundleID: "com.google.Chrome", from: start, to: boundary.addingTimeInterval(1))
        XCTAssertEqual(frames.filter { $0.id.value == frameID }.count, 1)
        model.appUsageRangeEnd = boundary
        let app = AppUsageData(appBundleID: "com.google.Chrome", appName: "Chrome", duration: 10, uniqueItemCount: 3, percentage: 1)
        let plan = try await model.prepareUsageAction(target: .app(app), action: .delete)
        XCTAssertTrue(plan.frames.contains { $0.id.value == frameID })
    }

    func testDeleteBatchesMoreThanSQLiteVariableLimit() async throws {
        let (model, _, database, start) = try await fixture()
        let id = try await database.insertSegment(bundleID: "com.google.Chrome", startDate: start, endDate: start.addingTimeInterval(10), windowName: "Large batch", browserUrl: nil, type: 0)
        for index in 0..<1_100 {
            _ = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: start.addingTimeInterval(6 + Double(index) / 1_000), segmentID: AppSegmentID(value: id), frameIndexInSegment: 0, metadata: FrameMetadata()))
        }
        let app = AppUsageData(appBundleID: "com.google.Chrome", appName: "Chrome", duration: 10, uniqueItemCount: 4, percentage: 1)
        let plan = try await model.prepareUsageAction(target: .app(app), action: .delete)
        XCTAssertEqual(plan.frames.count, 1_105)
        _ = try await model.applyUsageAction(plan)
        let remaining = try await database.getFrames(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(100), limit: 2_000)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains { $0.timestamp < start })
        XCTAssertTrue(remaining.contains { $0.metadata.appBundleID == "com.apple.Safari" })
    }

    func testWindowFallbacksAndWebsitePortsMatchDashboardGroups() async throws {
        let (model, _, database, start) = try await fixture()
        let rows: [(String, String?, String)] = [
            ("com.google.Chrome", "", "Same title"),
            ("com.google.Chrome", "https://example.com:8443/a", "Same title"),
            ("com.editor", "https://example.com/a", "Editor"),
            ("com.editor", "https://example.com/b", "Editor")
        ]
        for (bundleID, url, title) in rows {
            let id = try await database.insertSegment(bundleID: bundleID, startDate: start, endDate: start.addingTimeInterval(10), windowName: title, browserUrl: url, type: 0)
            _ = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: start.addingTimeInterval(6), segmentID: AppSegmentID(value: id), frameIndexInSegment: 0, metadata: FrameMetadata()))
        }
        let chrome = AppUsageData(appBundleID: "com.google.Chrome", appName: "Chrome", duration: 10, uniqueItemCount: 4, percentage: 1)
        let port = try await model.prepareUsageAction(target: .website(app: chrome, domain: "example.com:8443"), action: .delete)
        XCTAssertEqual(port.frames.count, 1)
        let fallback = try await model.prepareUsageAction(target: .window(app: chrome, window: WindowUsageData(windowName: "Same title", isWebsite: false, duration: 1, percentage: 1)), action: .delete)
        XCTAssertEqual(fallback.frames.count, 1, "Browser fallback groups include empty URLs and exclude website tabs")
        let editor = AppUsageData(appBundleID: "com.editor", appName: "Editor", duration: 1, uniqueItemCount: 1, percentage: 1)
        let window = try await model.prepareUsageAction(target: .window(app: editor, window: WindowUsageData(windowName: "Editor", isWebsite: false, duration: 1, percentage: 1)), action: .delete)
        XCTAssertEqual(window.frames.count, 2, "Non-browser window groups do not distinguish URLs")
    }

    private func fixture() async throws -> (DashboardViewModel, AppCoordinator, any DatabaseProtocol, Date) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let services = ServiceContainer(databasePath: root.appendingPathComponent("test.db").path, storageConfig: StorageConfig(storageRootPath: root.path))
        let database = await services.database
        try await database.initialize()
        addTeardownBlock {
            try await database.close()
            try FileManager.default.removeItem(at: root)
        }
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let rows: [(String, String?, String?, [Double])] = [
            ("com.google.Chrome", "Same title", "https://example.com/a", [-1, 0, 1]),
            ("com.google.Chrome", "Same title", "https://example.com/b", [2]),
            ("com.google.Chrome", "Same title", "https://notexample.com/a", [3]),
            ("com.google.Chrome", nil, nil, [4]),
            ("com.apple.Safari", "Same title", "https://example.com/a", [5])
        ]
        for (bundleID, title, url, offsets) in rows {
            let id = try await database.insertSegment(bundleID: bundleID, startDate: start.addingTimeInterval(-1), endDate: start.addingTimeInterval(20), windowName: title, browserUrl: url, type: 0)
            for offset in offsets {
                _ = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: start.addingTimeInterval(offset), segmentID: AppSegmentID(value: id), frameIndexInSegment: 0, metadata: FrameMetadata()))
            }
        }
        let coordinator = AppCoordinator(services: services)
        let model = DashboardViewModel(coordinator: coordinator)
        model.isDefaultAppUsageRangeSelected = false
        model.appUsageRangeStart = start
        model.appUsageRangeEnd = start.addingTimeInterval(10)
        return (model, coordinator, database, start)
    }
}
