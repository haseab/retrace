import XCTest
import Shared
@testable import Processing

final class WindowTitleValidatorTests: XCTestCase {
    // Actual OCR/title pairs from captured BB frames (no conversation content).
    func testRecordedOCRSpellingErrorsAndRealTitleMismatches() {
        XCTAssertTrue(WindowTitleWords.matches(
            "Validate OCR output with accessibility API",
            "Valldate OCR output with accessibllity API"))
        XCTAssertTrue(WindowTitleWords.matches(
            "Validate OCR output with accessibility API",
            "Valldate OCR output with accessibility APl"))
        XCTAssertFalse(WindowTitleWords.matches(
            "Validate OCR output with accessibility API", "Plan full Limitless data export"))
        XCTAssertFalse(WindowTitleWords.matches(
            "Build Slack notification and unread tracker", "Verify host machine for hasbook-bro"))
        XCTAssertTrue(WindowTitleWords.matches(
            "Agents - Configure macOS remote access permissions", "Configure macOS remote access permissions"))
        // A known conservative false rejection: short words remain exact.
        XCTAssertFalse(WindowTitleWords.matches(
            "Check for duplicate tasks and ensure", "Check tor dupllcate tasks and ensure"))
    }
    func testRecordedMismatchIsNotConfirmedBySidebarOrConversationMention() {
        let area = CGRect(x: 0.2, y: 0.025, width: 0.65, height: 0.025)
        let observation = WindowTitleObservation(pid: 31234, windowID: 3933,
            bounds: CGRect(x: 0, y: 30, width: 2560, height: 1410),
            title: "Agents - Validate OCR output with accessibility API", titleRegion: area)
        let id = FrameID(value: 1)
        let text = ExtractedText(frameID: id, timestamp: Date(), regions: [
            TextRegion(frameID: id, text: "Plan full Limitless data export",
                       bounds: CGRect(x: 716.8, y: 43.92, width: 307.2, height: 18)),
            TextRegion(frameID: id, text: observation.title,
                       bounds: CGRect(x: 51.2, y: 720, width: 384, height: 21.6))
        ])
        XCTAssertEqual(WindowTitleValidator.validate(.init(before: observation, after: observation), text: text, width: 2560, height: 1440).outcome,
                       "ocr_recovered")
    }
}
