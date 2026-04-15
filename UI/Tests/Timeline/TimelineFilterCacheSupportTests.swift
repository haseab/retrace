import XCTest
import Shared
@testable import Retrace

final class TimelineFilterCacheSupportTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var currentNow = Date(timeIntervalSince1970: 1_700_500_000)

    override func setUp() {
        super.setUp()
        suiteName = "TimelineFilterCacheSupportTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
        currentNow = Date(timeIntervalSince1970: 1_700_500_000)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSaveWritesCriteriaAndTimestampWhenFiltersAreActive() throws {
        let support = makeSupport()
        let criteria = FilterCriteria(selectedApps: Set(["com.apple.Safari"]))

        let result = support.save(criteria: criteria)

        guard case .saved = result else {
            return XCTFail("Expected active filters to be saved")
        }

        let savedData = try XCTUnwrap(
            userDefaults.data(forKey: TimelineFilterCacheSupport.defaultCriteriaKey)
        )
        let restoredCriteria = try JSONDecoder().decode(FilterCriteria.self, from: savedData)

        XCTAssertEqual(restoredCriteria, criteria)
        XCTAssertEqual(
            userDefaults.double(forKey: TimelineFilterCacheSupport.defaultSavedAtKey),
            currentNow.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testSaveClearsPersistedCacheWhenFiltersAreInactive() {
        let support = makeSupport()
        userDefaults.set(Data([0x01]), forKey: TimelineFilterCacheSupport.defaultCriteriaKey)
        userDefaults.set(currentNow.timeIntervalSince1970, forKey: TimelineFilterCacheSupport.defaultSavedAtKey)

        let result = support.save(criteria: .none)

        guard case .clearedInactive = result else {
            return XCTFail("Expected inactive filters to clear the cache")
        }

        XCTAssertNil(userDefaults.data(forKey: TimelineFilterCacheSupport.defaultCriteriaKey))
        XCTAssertEqual(userDefaults.double(forKey: TimelineFilterCacheSupport.defaultSavedAtKey), 0)
    }

    func testRestoreReturnsFreshCriteriaAndElapsedSeconds() {
        let support = makeSupport()
        let criteria = FilterCriteria(
            selectedApps: Set(["com.apple.Safari"]),
            selectedTags: Set([7])
        )
        _ = support.save(criteria: criteria)
        currentNow = currentNow.addingTimeInterval(45)

        let result = support.restore()

        guard case let .restored(restoredCriteria, elapsedSeconds) = result else {
            return XCTFail("Expected fresh cache to restore")
        }

        XCTAssertEqual(restoredCriteria, criteria)
        XCTAssertEqual(elapsedSeconds, 45, accuracy: 0.001)
    }

    func testRestoreClearsExpiredCache() {
        let support = makeSupport(expirationSeconds: 120)
        let criteria = FilterCriteria(selectedApps: Set(["com.apple.Safari"]))
        _ = support.save(criteria: criteria)
        currentNow = currentNow.addingTimeInterval(121)

        let result = support.restore()

        guard case let .expired(elapsedSeconds) = result else {
            return XCTFail("Expected expired cache result")
        }

        XCTAssertEqual(elapsedSeconds, 121, accuracy: 0.001)
        XCTAssertNil(userDefaults.data(forKey: TimelineFilterCacheSupport.defaultCriteriaKey))
        XCTAssertEqual(userDefaults.double(forKey: TimelineFilterCacheSupport.defaultSavedAtKey), 0)
    }

    func testRestoreReportsMissingPayloadWithoutClearingTimestamp() {
        let support = makeSupport()
        userDefaults.set(currentNow.timeIntervalSince1970, forKey: TimelineFilterCacheSupport.defaultSavedAtKey)

        let result = support.restore()

        guard case .missingCriteriaData = result else {
            return XCTFail("Expected missing payload result when only savedAt exists")
        }

        XCTAssertEqual(
            userDefaults.double(forKey: TimelineFilterCacheSupport.defaultSavedAtKey),
            currentNow.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    private func makeSupport(expirationSeconds: TimeInterval = TimelineFilterCacheSupport.defaultExpirationSeconds)
        -> TimelineFilterCacheSupport
    {
        TimelineFilterCacheSupport(
            userDefaults: userDefaults,
            now: { [unowned self] in self.currentNow },
            expirationSeconds: expirationSeconds
        )
    }
}
