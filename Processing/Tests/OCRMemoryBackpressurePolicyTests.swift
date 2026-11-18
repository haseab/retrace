import XCTest
@testable import Processing

final class OCRMemoryBackpressurePolicyTests: XCTestCase {
    func testHysteresisPausesAndResumesAtDifferentThresholds() {
        let policy = OCRMemoryBackpressurePolicy(
            enabled: true,
            pauseThresholdBytes: 100,
            resumeThresholdBytes: 60,
            pollIntervalNs: 1_000_000_000
        )

        XCTAssertFalse(policy.shouldPause(footprintBytes: 99, currentlyPaused: false))
        XCTAssertTrue(policy.shouldPause(footprintBytes: 100, currentlyPaused: false))
        XCTAssertTrue(policy.shouldPause(footprintBytes: 80, currentlyPaused: true))
        XCTAssertFalse(policy.shouldPause(footprintBytes: 59, currentlyPaused: true))
    }

    func testDefaultsDisableBackpressureForReferenceDisplaySize() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.reference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: OCRMemoryBackpressurePolicy.referenceDisplayPixelCount
        )

        XCTAssertFalse(policy.enabled)
        XCTAssertEqual(policy.pauseThresholdBytes, OCRMemoryBackpressurePolicy.defaultPauseThresholdBytes)
        XCTAssertEqual(policy.resumeThresholdBytes, OCRMemoryBackpressurePolicy.defaultResumeThresholdBytes)
        XCTAssertEqual(policy.pollIntervalNs, 1_000_000_000)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsScaleUpForUltraWideDisplays() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.ultrawide.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: 5_120 * 1_440
        )

        XCTAssertEqual(policy.pauseThresholdBytes, 2_172 * 1024 * 1024)
        XCTAssertEqual(policy.resumeThresholdBytes, 2_028 * 1024 * 1024)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsClampResumeBelowPauseThreshold() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(900, forKey: OCRMemoryBackpressurePolicy.pauseThresholdDefaultsKey)
        defaults.set(950, forKey: OCRMemoryBackpressurePolicy.resumeThresholdDefaultsKey)
        defaults.set(false, forKey: OCRMemoryBackpressurePolicy.enabledDefaultsKey)
        defaults.set(250, forKey: OCRMemoryBackpressurePolicy.pollIntervalDefaultsKey)

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: 5_120 * 1_440
        )

        XCTAssertFalse(policy.enabled)
        XCTAssertEqual(policy.pauseThresholdBytes, 900 * 1024 * 1024)
        XCTAssertEqual(policy.resumeThresholdBytes, 899 * 1024 * 1024)
        XCTAssertEqual(policy.pollIntervalNs, 250 * 1_000_000)

        defaults.removePersistentDomain(forName: suiteName)
    }
}
