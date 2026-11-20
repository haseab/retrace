import XCTest
@testable import Shared

final class MasterKeyManagerTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MasterKeyManager.resetCacheForTests()
    }

    func testRecoveryPhraseRoundTripsMasterKeyData() throws {
        let keyData = Data((0..<32).map { UInt8($0) })

        let phrase = MasterKeyManager.recoveryPhrase(for: keyData)
        let recoveredKeyData = try MasterKeyManager.keyData(fromRecoveryPhrase: phrase)

        XCTAssertEqual(recoveredKeyData, keyData)
        XCTAssertEqual(phrase.split(whereSeparator: \.isWhitespace).count, 22)
    }

    func testRecoveryPhraseRejectsChecksumMismatch() throws {
        let keyData = Data((0..<32).map { UInt8($0) })
        var words = MasterKeyManager.recoveryPhrase(for: keyData)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        XCTAssertEqual(words.count, 22)
        words[0] = words[0] == "bab" ? "cec" : "bab"

        XCTAssertThrowsError(try MasterKeyManager.keyData(fromRecoveryPhrase: words.joined(separator: " "))) { error in
            XCTAssertEqual(
                error.localizedDescription,
                MasterKeyManagerError.invalidRecoveryPhraseChecksum.localizedDescription
            )
        }
    }

    func testRecoveryDocumentIncludesPhraseAndWarning() {
        let phrase = Array(repeating: "bab", count: 22).joined(separator: " ")
        let document = MasterKeyManager.recoveryDocumentText(recoveryPhrase: phrase)

        XCTAssertTrue(document.contains("Retrace Recovery Phrase"))
        XCTAssertTrue(document.contains(phrase))
        XCTAssertTrue(document.contains("protected data cannot be recovered"))
    }

    func testRecoveryPhraseCanBeRecoveredFromDocumentText() throws {
        let keyData = Data((0..<32).map { UInt8($0) })
        let phrase = MasterKeyManager.recoveryPhrase(for: keyData)
        let document = MasterKeyManager.recoveryDocumentText(recoveryPhrase: phrase)

        XCTAssertEqual(
            try MasterKeyManager.recoveryPhrase(fromRecoveryText: document),
            phrase
        )
    }

    func testTrustedApplicationPathIsNilForAppBundles() {
        XCTAssertNil(
            MasterKeyManager.trustedApplicationPath(
                bundlePath: "/Applications/Retrace.app",
                executablePath: "/Applications/Retrace.app/Contents/MacOS/Retrace"
            )
        )
    }

    func testTrustedApplicationPathUsesExecutableForNakedDevBinary() {
        XCTAssertEqual(
            MasterKeyManager.trustedApplicationPath(
                bundlePath: "/Users/alice/dev/retrace/.build/debug/Retrace",
                executablePath: "/Users/alice/dev/retrace/.build/debug/Retrace"
            ),
            "/Users/alice/dev/retrace/.build/debug/Retrace"
        )
    }

    func testResetMasterKeyPreservesDefaultsWhenDeleteFails() throws {
        let defaults = makeDefaults()
        defaults.set(123, forKey: MasterKeyManager.createdAtDefaultsKey)
        defaults.set(456, forKey: MasterKeyManager.lastShownRecoveryDefaultsKey)

        XCTAssertThrowsError(
            try MasterKeyManager.resetMasterKey(
                defaults: defaults,
                deleteMasterKey: { _ in errSecInteractionNotAllowed }
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                MasterKeyManagerError.keychainDeleteFailed(errSecInteractionNotAllowed).localizedDescription
            )
        }

        XCTAssertEqual(defaults.object(forKey: MasterKeyManager.createdAtDefaultsKey) as? Int, 123)
        XCTAssertEqual(defaults.object(forKey: MasterKeyManager.lastShownRecoveryDefaultsKey) as? Int, 456)
    }

    func testResetMasterKeyClearsDefaultsWhenDeleteSucceeds() throws {
        let defaults = makeDefaults()
        defaults.set(123, forKey: MasterKeyManager.createdAtDefaultsKey)
        defaults.set(456, forKey: MasterKeyManager.lastShownRecoveryDefaultsKey)

        let removed = try MasterKeyManager.resetMasterKey(
            defaults: defaults,
            deleteMasterKey: { _ in errSecSuccess }
        )

        XCTAssertTrue(removed)
        XCTAssertNil(defaults.object(forKey: MasterKeyManager.createdAtDefaultsKey))
        XCTAssertNil(defaults.object(forKey: MasterKeyManager.lastShownRecoveryDefaultsKey))
    }

    func testResetMasterKeyClearsDefaultsWhenKeyAlreadyMissing() throws {
        let defaults = makeDefaults()
        defaults.set(123, forKey: MasterKeyManager.createdAtDefaultsKey)
        defaults.set(456, forKey: MasterKeyManager.lastShownRecoveryDefaultsKey)

        let removed = try MasterKeyManager.resetMasterKey(
            defaults: defaults,
            deleteMasterKey: { _ in errSecItemNotFound }
        )

        XCTAssertFalse(removed)
        XCTAssertNil(defaults.object(forKey: MasterKeyManager.createdAtDefaultsKey))
        XCTAssertNil(defaults.object(forKey: MasterKeyManager.lastShownRecoveryDefaultsKey))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MasterKeyManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
