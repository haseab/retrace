import XCTest
import Shared
@testable import Processing

/// Locks in that Vision's language-correction pass stays off unless explicitly enabled.
///
/// Correction cost 27.9% of region-OCR time (1778.4 ms -> 1283.0 ms per frame on a
/// 3440x1440 text-dense frame) and bought nothing measurable: search-token recall was
/// identical (35/36 on code/terminal/URL content, 36/36 on prose) and it recognised
/// *less* text. Region OCR is the production path -- the live log shows 1,121 of 1,255
/// frames going through it at a mean of 655.8 ms.
final class OCRLanguageCorrectionConfigTests: XCTestCase {
    func testLanguageCorrectionIsOffByDefault() {
        XCTAssertFalse(ProcessingConfig.default.ocrLanguageCorrectionEnabled)
        XCTAssertFalse(ProcessingConfig().ocrLanguageCorrectionEnabled)
    }

    func testFullFrameRequestConfigDefaultsToNoCorrection() {
        let config = VisionOCR.fullFrameRecognitionRequestConfig()
        XCTAssertFalse(config.usesLanguageCorrection)
    }

    /// Both Vision paths must honour the flag. Before this change the full-frame path
    /// hardcoded `false` while the region path passed `ocrAccuracyLevel == .accurate`,
    /// i.e. always `true` -- so the hot path silently paid for correction the other
    /// path had already decided it did not need.
    func testBothRecognitionPathsPropagateTheFlag() {
        for enabled in [true, false] {
            XCTAssertEqual(
                VisionOCR.fullFrameRecognitionRequestConfig(
                    usesLanguageCorrection: enabled
                ).usesLanguageCorrection,
                enabled
            )
            XCTAssertEqual(
                VisionOCR.regionRecognitionRequestConfig(
                    regionOfInterest: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                    usesLanguageCorrection: enabled
                ).usesLanguageCorrection,
                enabled
            )
        }
    }

    /// Regression guard: `ProcessingConfig` is rebuilt positionally in AppCoordinator when
    /// power settings change. Omitting the new field there would silently reset an opted-in
    /// user back to the default on the next power-state change.
    func testRebuildingConfigPreservesLanguageCorrection() {
        let opted = ProcessingConfig(
            accessibilityEnabled: false,
            ocrAccuracyLevel: .accurate,
            recognitionLanguages: ["en-US"],
            minimumConfidence: 0.5,
            preferBackgroundProcessing: false,
            ocrLanguageCorrectionEnabled: true
        )

        let rebuilt = ProcessingConfig(
            accessibilityEnabled: opted.accessibilityEnabled,
            ocrAccuracyLevel: opted.ocrAccuracyLevel,
            recognitionLanguages: opted.recognitionLanguages,
            minimumConfidence: opted.minimumConfidence,
            preferBackgroundProcessing: true,
            ocrLanguageCorrectionEnabled: opted.ocrLanguageCorrectionEnabled
        )

        XCTAssertTrue(rebuilt.ocrLanguageCorrectionEnabled)
    }
}
