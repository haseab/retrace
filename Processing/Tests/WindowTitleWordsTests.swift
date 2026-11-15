import XCTest
import Shared

final class WindowTitleWordsTests: XCTestCase {
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
}
