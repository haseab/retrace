import XCTest
import Shared
@testable import Retrace

@MainActor
final class TimelineFilterStoreSupportDataTests: XCTestCase {
    func testLoadAvailableAppsForFilterSkipsDuplicateLoadWhenInstalledAndHistoricalAppsAreCurrent() async {
        let store = TimelineFilterStore()
        let context = makeContext()
        var installedAppsCallCount = 0
        var distinctBundleIDSources: [FrameSource?] = []

        await store.loadAvailableAppsForFilter(
            environment: makeEnvironment(
                rewindCacheContext: context,
                installedApps: {
                    installedAppsCallCount += 1
                    return [AppInfo(bundleID: "com.apple.Safari", name: "Safari")]
                },
                distinctAppBundleIDs: { source in
                    distinctBundleIDSources.append(source)
                    switch source {
                    case .native:
                        return ["com.apple.Safari", "com.apple.Notes"]
                    case .rewind:
                        return ["com.apple.Maps"]
                    case .none:
                        return []
                    default:
                        return []
                    }
                }
            )
        )

        await store.loadAvailableAppsForFilter(
            environment: makeEnvironment(
                rewindCacheContext: context,
                installedApps: {
                    installedAppsCallCount += 1
                    return []
                },
                distinctAppBundleIDs: { source in
                    distinctBundleIDSources.append(source)
                    return []
                }
            )
        )

        XCTAssertEqual(installedAppsCallCount, 1)
        XCTAssertEqual(distinctBundleIDSources.count, 2)
        XCTAssertEqual(distinctBundleIDSources.filter { $0 == .native }.count, 1)
        XCTAssertEqual(distinctBundleIDSources.filter { $0 == .rewind }.count, 1)
        XCTAssertEqual(store.supportDataState.availableAppsForFilter.map(\.name), ["Safari"])
        XCTAssertEqual(store.supportDataState.otherAppsForFilter.map(\.name), ["Maps", "Notes"])
    }

    func testLoadAvailableAppsForFilterReloadsHistoricalAppsWhenContextChanges() async {
        let store = TimelineFilterStore()
        let oldContext = makeContext(cutoffDate: Date(timeIntervalSince1970: 100))
        let newContext = makeContext(cutoffDate: Date(timeIntervalSince1970: 200))
        var installedAppsCallCount = 0
        var distinctBundleIDSources: [FrameSource?] = []

        await store.loadAvailableAppsForFilter(
            environment: makeEnvironment(
                rewindCacheContext: oldContext,
                installedApps: {
                    installedAppsCallCount += 1
                    return [AppInfo(bundleID: "com.apple.Safari", name: "Safari")]
                },
                distinctAppBundleIDs: { source in
                    distinctBundleIDSources.append(source)
                    switch source {
                    case .native:
                        return ["com.apple.Safari"]
                    case .rewind:
                        return ["com.apple.Maps"]
                    case .none:
                        return []
                    default:
                        return []
                    }
                }
            )
        )

        await store.loadAvailableAppsForFilter(
            environment: makeEnvironment(
                rewindCacheContext: newContext,
                installedApps: {
                    installedAppsCallCount += 1
                    return [AppInfo(bundleID: "com.apple.Safari", name: "Safari")]
                },
                distinctAppBundleIDs: { source in
                    distinctBundleIDSources.append(source)
                    switch source {
                    case .native:
                        return ["com.apple.Safari"]
                    case .rewind:
                        return ["com.apple.Maps", "com.apple.Notes"]
                    case .none:
                        return []
                    default:
                        return []
                    }
                }
            )
        )

        XCTAssertEqual(installedAppsCallCount, 1)
        XCTAssertEqual(distinctBundleIDSources.count, 4)
        XCTAssertEqual(distinctBundleIDSources.filter { $0 == .native }.count, 2)
        XCTAssertEqual(distinctBundleIDSources.filter { $0 == .rewind }.count, 2)
        XCTAssertEqual(store.supportDataState.availableAppsForFilter.map(\.name), ["Safari"])
        XCTAssertEqual(store.supportDataState.otherAppsForFilter.map(\.name), ["Maps", "Notes"])
    }

    func testStartAvailableAppsLoadIfNeededCoalescesDuplicateTaskStarts() async {
        let store = TimelineFilterStore()
        let context = makeContext()
        var invocationCount = 0
        let gate = SharedAsyncTestGate()

        store.startAvailableAppsLoadIfNeeded(rewindCacheContext: context) {
            invocationCount += 1
            await gate.enterAndWait()
        }
        store.startAvailableAppsLoadIfNeeded(rewindCacheContext: context) {
            invocationCount += 1
        }

        await gate.waitUntilEntered()
        XCTAssertEqual(invocationCount, 1)

        await gate.release()
        await Task.yield()

        XCTAssertEqual(invocationCount, 1)
    }

    func testScheduleSupportingDataLoadCancelsPreviousTaskAndRunsLatestAction() async {
        let store = TimelineFilterStore()
        var events: [String] = []

        store.scheduleSupportingDataLoad(delay: .milliseconds(50)) {
            events.append("first")
        }
        store.scheduleSupportingDataLoad(delay: .zero) {
            events.append("second")
        }

        await waitUntil { events == ["second"] }
        XCTAssertEqual(events, ["second"])
    }

    private func makeEnvironment(
        rewindCacheContext: TimelineRewindAppBundleIDCacheContext,
        installedApps: @escaping () async -> [AppInfo],
        distinctAppBundleIDs: @escaping (FrameSource?) async throws -> [String]
    ) -> TimelineFilterStore.AvailableAppsLoadEnvironment {
        TimelineFilterStore.AvailableAppsLoadEnvironment(
            rewindCacheContext: rewindCacheContext,
            installedApps: installedApps,
            distinctAppBundleIDs: distinctAppBundleIDs,
            resolveApps: { bundleIDs in
                bundleIDs.map { AppInfo(bundleID: $0, name: $0.split(separator: ".").last.map(String.init)?.capitalized ?? $0) }
            },
            loadCachedRewindAppBundleIDs: { _ in nil },
            saveCachedRewindAppBundleIDs: { _, _ in },
            removeCachedRewindAppBundleIDs: {},
            invalidate: {}
        )
    }

    private func makeContext(
        cutoffDate: Date = Date(timeIntervalSince1970: 123),
        effectiveRewindDatabasePath: String = "/tmp/rewind/db-enc.sqlite3",
        useRewindData: Bool = true
    ) -> TimelineRewindAppBundleIDCacheContext {
        .init(
            cutoffDate: cutoffDate,
            effectiveRewindDatabasePath: effectiveRewindDatabasePath,
            useRewindData: useRewindData
        )
    }

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
