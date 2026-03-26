import XCTest
@testable import Shared
import Security

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

    func testRecoveryDocumentIncludesSelectedStoragePolicy() {
        let phrase = Array(repeating: "bab", count: 22).joined(separator: " ")
        let document = MasterKeyManager.recoveryDocumentText(
            recoveryPhrase: phrase,
            storagePolicy: .iCloudKeychain
        )

        XCTAssertTrue(document.contains("iCloud Keychain sync enabled"))
    }

    func testDerivedDatabaseKeyIsStableAndDistinctFromMasterKey() {
        let masterKeyData = Data((0..<32).map { UInt8($0) })

        let first = MasterKeyManager.derivedKeyData(from: masterKeyData, purpose: .databaseEncryption)
        let second = MasterKeyManager.derivedKeyData(from: masterKeyData, purpose: .databaseEncryption)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, masterKeyData)
    }

    func testDerivedRedactionKeyIsStableAndDistinctFromOtherKeyMaterial() {
        let masterKeyData = Data((0..<32).map { UInt8($0) })

        let redactionKey = MasterKeyManager.derivedKeyData(from: masterKeyData, purpose: .phraseRedaction)
        let databaseKey = MasterKeyManager.derivedKeyData(from: masterKeyData, purpose: .databaseEncryption)

        XCTAssertEqual(
            redactionKey,
            MasterKeyManager.derivedKeyData(from: masterKeyData, purpose: .phraseRedaction)
        )
        XCTAssertEqual(redactionKey.count, 32)
        XCTAssertNotEqual(redactionKey, masterKeyData)
        XCTAssertNotEqual(redactionKey, databaseKey)
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

    func testHasMasterKeyTreatsLegacyInteractionRequiredStatusAsPresent() {
        var queriedServices: [String] = []

        let hasMasterKey = MasterKeyManager.hasMasterKey { query, _ in
            let service = (query as NSDictionary)[kSecAttrService as String] as? String ?? ""
            queriedServices.append(service)

            switch service {
            case MasterKeyManager.keychainService:
                return errSecItemNotFound
            case MasterKeyManager.legacyKeychainService:
                return errSecInteractionNotAllowed
            default:
                XCTFail("Unexpected keychain service \(service)")
                return errSecItemNotFound
            }
        }

        XCTAssertTrue(hasMasterKey)
        XCTAssertEqual(
            queriedServices,
            [MasterKeyManager.keychainService, MasterKeyManager.legacyKeychainService]
        )
    }

    func testLoadMasterKeyPrefersCanonicalItemWhenPresent() throws {
        let canonicalKeyData = Data((0..<32).map { UInt8(255 - $0) })
        var addWasCalled = false

        let loadedKey = try MasterKeyManager.loadMasterKey(
            copyMatching: { query, result in
                let service = (query as NSDictionary)[kSecAttrService as String] as? String ?? ""
                XCTAssertEqual(service, MasterKeyManager.keychainService)
                result?.pointee = canonicalKeyData as CFTypeRef
                return errSecSuccess
            },
            addItem: { _, _ in
                addWasCalled = true
                return errSecSuccess
            }
        )

        XCTAssertEqual(loadedKey, canonicalKeyData)
        XCTAssertFalse(addWasCalled)
    }

    func testLoadMasterKeyPromotesLegacyItemIntoCanonicalService() throws {
        let legacyKeyData = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        var queriedServices: [String] = []
        var addedService: String?
        var addedData: Data?

        let loadedKey = try MasterKeyManager.loadMasterKey(
            copyMatching: { query, result in
                let service = (query as NSDictionary)[kSecAttrService as String] as? String ?? ""
                queriedServices.append(service)

                switch service {
                case MasterKeyManager.keychainService:
                    return errSecItemNotFound
                case MasterKeyManager.legacyKeychainService:
                    result?.pointee = legacyKeyData as CFTypeRef
                    return errSecSuccess
                default:
                    XCTFail("Unexpected keychain service \(service)")
                    return errSecItemNotFound
                }
            },
            addItem: { query, _ in
                let dictionary = query as NSDictionary
                addedService = dictionary[kSecAttrService as String] as? String
                addedData = dictionary[kSecValueData as String] as? Data
                return errSecSuccess
            }
        )

        XCTAssertEqual(loadedKey, legacyKeyData)
        XCTAssertEqual(
            queriedServices,
            [MasterKeyManager.keychainService, MasterKeyManager.legacyKeychainService]
        )
        XCTAssertEqual(addedService, MasterKeyManager.keychainService)
        XCTAssertEqual(addedData, legacyKeyData)
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

    func testResetMasterKeyDeletesCanonicalAndLegacyItems() throws {
        var deletedServices: [String] = []

        let removed = try MasterKeyManager.resetMasterKey(
            defaults: makeDefaults(),
            deleteMasterKey: { query in
                let service = (query as NSDictionary)[kSecAttrService as String] as? String ?? ""
                deletedServices.append(service)
                return service == MasterKeyManager.keychainService ? errSecSuccess : errSecItemNotFound
            }
        )

        XCTAssertTrue(removed)
        XCTAssertEqual(
            deletedServices,
            [MasterKeyManager.keychainService, MasterKeyManager.legacyKeychainService]
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MasterKeyManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
