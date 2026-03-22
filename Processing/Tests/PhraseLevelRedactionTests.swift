import XCTest
import Foundation
import CoreGraphics
import CryptoKit
import Shared
@testable import Processing

final class PhraseLevelRedactionTests: XCTestCase {
    func testFuzzyPhraseRedactionMatchesOCRSubstitution() {
        let extracted = makeExtractedText(regions: ["insentions"])

        let result = FrameProcessingQueue.applyPhraseLevelRedactionForTesting(
            to: extracted,
            phrases: ["insertions"]
        )

        XCTAssertEqual(result.redactedCombinedNodeOrders, Set([0]))
        XCTAssertEqual(result.sanitizedText.regions[0].text, String(repeating: " ", count: "insentions".count))
    }

    func testFuzzyPhraseRedactionMatchesAcrossAdjacentNodesWithoutOverRedactingNeighbors() {
        let extracted = makeExtractedText(regions: ["open", "secret", "kex", "panel"])

        let result = FrameProcessingQueue.applyPhraseLevelRedactionForTesting(
            to: extracted,
            phrases: ["secret key"]
        )

        XCTAssertEqual(result.redactedCombinedNodeOrders, Set([1, 2]))
        XCTAssertEqual(result.sanitizedText.regions[0].text, "open")
        XCTAssertEqual(result.sanitizedText.regions[1].text, String(repeating: " ", count: "secret".count))
        XCTAssertEqual(result.sanitizedText.regions[2].text, String(repeating: " ", count: "kex".count))
        XCTAssertEqual(result.sanitizedText.regions[3].text, "panel")
    }

    func testFuzzyPhraseRedactionMatchesMergedSingleNodePhrase() {
        let extracted = makeExtractedText(regions: ["apikey", "visible"])

        let result = FrameProcessingQueue.applyPhraseLevelRedactionForTesting(
            to: extracted,
            phrases: ["api key"]
        )

        XCTAssertEqual(result.redactedCombinedNodeOrders, Set([0]))
        XCTAssertEqual(result.sanitizedText.regions[1].text, "visible")
    }

    func testFuzzyPhraseRedactionDoesNotMatchDistantText() {
        let extracted = makeExtractedText(regions: ["calendar", "visible"])

        let result = FrameProcessingQueue.applyPhraseLevelRedactionForTesting(
            to: extracted,
            phrases: ["insertions"]
        )

        XCTAssertTrue(result.redactedCombinedNodeOrders.isEmpty)
        XCTAssertEqual(result.sanitizedText.regions.map(\.text), ["calendar", "visible"])
    }

    func testPhraseLevelRedactionSkipsWhenSecretIsMissing() {
        let extracted = makeExtractedText(regions: ["insentions"])

        let result = FrameProcessingQueue.applyPhraseLevelRedactionForTesting(
            to: extracted,
            phrases: ["insertions"],
            redactionSecret: nil
        )

        XCTAssertTrue(result.redactedCombinedNodeOrders.isEmpty)
        XCTAssertEqual(result.sanitizedText.regions.map(\.text), ["insentions"])
    }

    func testEncryptedOCRTextRoundTripsWithCorrectNodeContext() throws {
        let secret = "test-secret"
        let plaintext = "secret key 123"
        let encrypted = try XCTUnwrap(
            ReversibleOCRScrambler.encryptOCRText(
                plaintext,
                frameID: 42,
                nodeOrder: 3,
                secret: secret
            )
        )

        XCTAssertTrue(encrypted.hasPrefix("rtx1."))
        XCTAssertNotEqual(encrypted, plaintext)
        XCTAssertEqual(
            ReversibleOCRScrambler.decryptOCRText(
                encrypted,
                frameID: 42,
                nodeOrder: 3,
                secret: secret
            ),
            plaintext
        )
        XCTAssertNotEqual(
            ReversibleOCRScrambler.decryptOCRText(
                encrypted,
                frameID: 42,
                nodeOrder: 4,
                secret: secret
            ),
            plaintext
        )
    }

    func testEncryptedOCRTextSupportsLegacyFrameZeroFallback() throws {
        let secret = "test-secret"
        let encrypted = try XCTUnwrap(
            legacyProtectedText(
                "legacy secret",
                frameID: 0,
                nodeOrder: 2,
                secret: secret
            )
        )

        XCTAssertEqual(
            ReversibleOCRScrambler.decryptOCRText(
                encrypted,
                frameID: 50799350,
                nodeOrder: 2,
                secret: secret
            ),
            "legacy secret"
        )
    }

    func testPhraseLevelRedactionUsesActualFrameIDForEncryptedText() throws {
        let extracted = makeExtractedText(
            frameID: FrameID(value: 0),
            regions: ["secret"]
        )

        let result = FrameProcessingQueue.applyPhraseLevelRedactionForTesting(
            to: extracted,
            phrases: ["secret"],
            redactionSecret: "test-secret",
            actualFrameID: 50799350
        )

        let encrypted = try XCTUnwrap(result.encryptedRedactedTexts[0])
        XCTAssertEqual(result.redactedCombinedNodeOrders, Set([0]))
        XCTAssertTrue(encrypted.hasPrefix("rtx1."))
        XCTAssertEqual(
            ReversibleOCRScrambler.decryptOCRText(
                encrypted,
                frameID: 50799350,
                nodeOrder: 0,
                secret: "test-secret"
            ),
            "secret"
        )
        XCTAssertNotEqual(
            ReversibleOCRScrambler.decryptOCRText(
                encrypted,
                frameID: 0,
                nodeOrder: 0,
                secret: "test-secret"
            ),
            "secret"
        )
    }

    private func makeExtractedText(
        frameID: FrameID = FrameID(value: 42),
        regions: [String],
        chromeRegions: [String] = [],
        metadata: FrameMetadata = .empty
    ) -> ExtractedText {
        let mainRegions = regions.enumerated().map { index, text in
            TextRegion(
                frameID: frameID,
                text: text,
                bounds: CGRect(x: CGFloat(index * 20), y: 0, width: 16, height: 10),
                confidence: 0.9
            )
        }
        let chromeTextRegions = chromeRegions.enumerated().map { index, text in
            TextRegion(
                frameID: frameID,
                text: text,
                bounds: CGRect(x: CGFloat(index * 20), y: 20, width: 16, height: 10),
                confidence: 0.9
            )
        }

        return ExtractedText(
            frameID: frameID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            regions: mainRegions,
            chromeRegions: chromeTextRegions,
            metadata: metadata
        )
    }

    private func legacyProtectedText(
        _ text: String,
        frameID: Int64,
        nodeOrder: Int,
        secret: String
    ) -> String? {
        guard let plaintext = text.data(using: .utf8) else { return nil }

        let material = Data("ocr-text|\(frameID)|\(nodeOrder)|\(secret)".utf8)
        let digest = SHA256.hash(data: material)
        let key = SymmetricKey(data: Data(digest))

        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealedBox.combined else { return nil }
            return "rtx1." + base64URLEncode(combined)
        } catch {
            return nil
        }
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
