import XCTest
import Foundation
import CoreGraphics
import Shared

final class PrivacyProtectionTests: XCTestCase {
    func testLogInterpolationRedactsStringsCollectionsURLsAndErrors() {
        let secret = "PRIVATE_CANARY_7c369"
        let url = URL(string: "https://example.test/?token=\(secret)")!
        let message: PrivacyLogMessage = "Search \(secret) URL \(url) matches \([secret]) count=\(3) success=\(true)"
        XCTAssertFalse(message.text.contains(secret))
        XCTAssertFalse(message.text.contains("example.test"))
        XCTAssertTrue(message.text.contains("count=3 success=true"))
        XCTAssertEqual(PrivacyLogMessage(redacting: secret).text, "[private message]")
    }

    func testLegacyKeywordSettingsEnablePreviewProtection() {
        let suite = "retrace-privacy-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for raw in ["secret,email", "secret\nemail", "[\"secret\",\"email\"]"] {
            defaults.set(raw, forKey: "phraseLevelRedactionPhrases")
            XCTAssertTrue(PhraseRedactionMode.isEnabled(in: defaults))
            XCTAssertEqual(PhraseRedactionMode.configuredPhrases(in: defaults), ["secret", "email"])
        }
        defaults.set(false, forKey: "phraseLevelRedactionEnabled")
        XCTAssertFalse(PhraseRedactionMode.isEnabled(in: defaults))
    }

    func testPermanentRedactionDestroysEveryPixelIncludingTinyPatches() {
        for (width, height) in [(1, 1), (16, 16), (32, 16), (61, 23)] {
            var bytes = Data(repeating: 123, count: width * height * 4)
            XCTAssertTrue(ReversibleOCRScrambler.permanentlyRedactPatchBGRA(
                &bytes, width: width, height: height, bytesPerRow: width * 4
            ))
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                XCTAssertEqual(Array(bytes[offset..<(offset + 4)]), [0, 0, 0, 255])
            }
        }
    }

    func testPermanentMarkerCannotBeDecryptedAndSurvivesSettingChanges() {
        XCTAssertEqual(PhraseRedactionMode(storedText: PhraseRedactionMode.permanentTextMarker), .permanent)
        XCTAssertEqual(PhraseRedactionMode(storedText: "rtx1.ciphertext"), .scramble)
        XCTAssertNil(ReversibleOCRScrambler.decryptOCRText(
            PhraseRedactionMode.permanentTextMarker, frameID: 1, nodeOrder: 0, secret: "any-key"
        ))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertEqual(PhraseRedactionMode.load(from: defaults), .scramble)
        defaults.set("permanent", forKey: PhraseRedactionMode.defaultsKey)
        XCTAssertEqual(PhraseRedactionMode.load(from: defaults), .permanent)
        defaults.set("scramble", forKey: PhraseRedactionMode.defaultsKey)
        XCTAssertEqual(PhraseRedactionMode(storedText: PhraseRedactionMode.permanentTextMarker), .permanent)
    }
}
