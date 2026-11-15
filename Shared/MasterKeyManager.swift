import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum MasterKeyStoragePolicy: String, Codable, CaseIterable, Sendable {
    // Retained only to decode legacy preferences; new writes always synchronize.
    case localOnly = "local_only"
    case iCloudKeychain = "icloud_keychain"

    public var isSynchronizable: Bool {
        self == .iCloudKeychain
    }

    public var accessibleAttribute: CFString {
        switch self {
        case .localOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .iCloudKeychain:
            return kSecAttrAccessibleAfterFirstUnlock
        }
    }

    public var recoveryDocumentStorageLabel: String {
        switch self {
        case .localOnly:
            return "Keychain (this device only)"
        case .iCloudKeychain:
            return "iCloud Keychain sync enabled"
        }
    }
}

public enum MasterKeyDerivedKeyPurpose: String, Sendable {
    case databaseEncryption = "database_encryption"
    case phraseRedaction = "phrase_redaction"
}

public struct MasterKeyCreationResult: Sendable {
    public let created: Bool
    public let recoveryPhrase: String?
    public let storagePolicy: MasterKeyStoragePolicy?

    public init(
        created: Bool,
        recoveryPhrase: String?,
        storagePolicy: MasterKeyStoragePolicy?
    ) {
        self.created = created
        self.recoveryPhrase = recoveryPhrase
        self.storagePolicy = storagePolicy
    }
}

public enum MasterKeyManagerError: LocalizedError, Sendable {
    case invalidKeyLength(Int)
    case invalidRecoveryPhraseWordCount(Int)
    case invalidRecoveryPhraseWord(String)
    case invalidRecoveryPhraseChecksum
    case invalidProtectedSettingsPayload
    case settingsEncryptionFailed(underlying: String)
    case settingsDecryptionFailed(underlying: String)
    case keychainStoreFailed(OSStatus)
    case keychainLoadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case trustedApplicationCreateFailed(OSStatus)
    case accessCreateFailed(OSStatus)
    case conflictingICloudKey

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let length):
            return "Expected a 32-byte master key, got \(length) bytes."
        case .invalidRecoveryPhraseWordCount(let count):
            return "Expected a 22-word recovery phrase, got \(count) words."
        case .invalidRecoveryPhraseWord(let word):
            return "The recovery phrase contains an unknown word: \(word)."
        case .invalidRecoveryPhraseChecksum:
            return "The recovery phrase checksum does not match."
        case .invalidProtectedSettingsPayload:
            return "The protected settings payload is invalid."
        case .settingsEncryptionFailed(let underlying):
            return "Failed to encrypt the protected settings payload: \(underlying)"
        case .settingsDecryptionFailed(let underlying):
            return "Failed to decrypt the protected settings payload: \(underlying)"
        case .keychainStoreFailed(let status):
            return "Could not save the master key for iCloud Keychain synchronization (status: \(status)). No local-only replacement was created."
        case .keychainLoadFailed(let status):
            return "Failed to load the master key from Keychain (status: \(status))."
        case .keychainDeleteFailed(let status):
            return "Failed to delete the master key from Keychain (status: \(status))."
        case .trustedApplicationCreateFailed(let status):
            return "Failed to create a trusted application entry for the master key (status: \(status))."
        case .conflictingICloudKey:
            return "The iCloud and local Retrace master keys differ. Neither key was replaced. Recover the key for this library before continuing."
        case .accessCreateFailed(let status):
            return "Failed to create access rules for the master key (status: \(status))."
        }
    }
}

public enum MasterKeyManager {
    public static let settingsSuiteName = "io.retrace.app"
    public static let keychainService = "io.retrace.app.masterkey.v2"
    public static let legacyKeychainService = "io.retrace.app.masterkey"
    public static let keychainAccount = "master-key"
    public static let createdAtDefaultsKey = "masterKeyCreatedAtMs"
    public static let lastShownRecoveryDefaultsKey = "masterKeyRecoveryShownAtMs"
    public static let storagePolicyDefaultsKey = "masterKeyStoragePolicy"

    private static let keyByteCount = 32
    private static let checksumByteCount = 1
    private static let recoveryPhraseWordCount = 22
    private static let derivationSalt = Data("io.retrace.app.masterkey.hkdf.v1".utf8)
    private static let keychainServices = [keychainService, legacyKeychainService]
    private static let cacheLock = NSLock()
    private static var cachedMasterKeyData: Data?
    private static var cachedScrambleSecret: String?
    private static var cachedLegacyScrambleSecret: String?
    private static var cachedHasMasterKey: Bool?
    private static let protectedSettingsPayloadPrefix = "rtcfg1."
    private static let phraseLevelRedactionSettingsPurpose = "phrase-level-redaction-phrases"

    private static let onsetSyllables = [
        "b", "c", "d", "f",
        "g", "h", "j", "k",
        "l", "m", "n", "p",
        "r", "s", "t", "v"
    ]

    private static let vowelSyllables = [
        "a", "e", "i", "o",
        "u", "ai", "ea", "ie",
        "oa", "oo", "ou", "au",
        "ei", "ia", "io", "ue"
    ]

    private static let codaSyllables = [
        "b", "c", "d", "f",
        "g", "h", "j", "k",
        "l", "m", "n", "p",
        "r", "s", "t", "v"
    ]

    private static let recoveryWordToIndex: [String: Int] = {
        var mapping: [String: Int] = [:]
        mapping.reserveCapacity(4_096)

        for index in 0..<4_096 {
            mapping[recoveryWord(for: index)] = index
        }

        return mapping
    }()

    public static func hasMasterKey(account: String = keychainAccount) -> Bool {
        hasMasterKey(account: account, copyMatching: SecItemCopyMatching)
    }

    public static func hasMasterKeyAsync(account: String = keychainAccount) async -> Bool {
        await Task.detached(priority: .utility) {
            hasMasterKey(account: account)
        }.value
    }

    static func hasMasterKey(
        account: String = keychainAccount,
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    ) -> Bool {
        if account == keychainAccount, let cachedValue = cachedHasMasterKeyValue() {
            return cachedValue
        }

        for service in keychainServices {
            let status = copyMatching(
                makeLookupQuery(
                    service: service,
                    account: account,
                    returnAttributes: true,
                    authenticationContext: noInteractionAuthenticationContext()
                ) as CFDictionary,
                nil
            )

            switch status {
            case errSecSuccess, errSecInteractionNotAllowed:
                if account == keychainAccount {
                    cacheHasMasterKeyValue(true)
                }
                return true
            case errSecItemNotFound:
                continue
            default:
                continue
            }
        }

        if account == keychainAccount {
            cacheHasMasterKeyValue(false)
        }
        return false
    }

    public static func createMasterKeyIfNeeded(
        defaults: UserDefaults? = nil,
        storagePolicy: MasterKeyStoragePolicy? = nil,
        keychainAccount: String = keychainAccount
    ) throws -> MasterKeyCreationResult {
        do {
            _ = try loadMasterKey(account: keychainAccount)
            return MasterKeyCreationResult(created: false, recoveryPhrase: nil, storagePolicy: .iCloudKeychain)
        } catch MasterKeyManagerError.keychainLoadFailed(let status) where status == errSecItemNotFound {
            // Only a confirmed missing item allows generation. Locked/unavailable
            // Keychain errors propagate without minting replacement key material.
        }

        let defaults = resolvedDefaults(defaults)
        let resolvedStoragePolicy = MasterKeyStoragePolicy.iCloudKeychain
        let masterKeyData = randomMasterKeyData()
        let created = try saveMasterKeyIfAbsent(
            masterKeyData,
            service: keychainService,
            account: keychainAccount,
            storagePolicy: resolvedStoragePolicy
        )
        guard created else {
            return MasterKeyCreationResult(
                created: false,
                recoveryPhrase: nil,
                storagePolicy: nil
            )
        }

        if keychainAccount == self.keychainAccount {
            let createdAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
            defaults.set(createdAtMs, forKey: createdAtDefaultsKey)
            defaults.set(resolvedStoragePolicy.rawValue, forKey: storagePolicyDefaultsKey)
            cacheMasterKey(masterKeyData)
        }

        return MasterKeyCreationResult(
            created: true,
            recoveryPhrase: recoveryPhrase(for: masterKeyData),
            storagePolicy: resolvedStoragePolicy
        )
    }

    public static func createMasterKeyIfNeededAsync(
        defaults: UserDefaults? = nil,
        storagePolicy: MasterKeyStoragePolicy? = nil,
        keychainAccount: String = keychainAccount
    ) async throws -> MasterKeyCreationResult {
        let defaultsReference = UserDefaultsReference(defaults: resolvedDefaults(defaults))
        return try await Task.detached(priority: .userInitiated) {
            try createMasterKeyIfNeeded(
                defaults: defaultsReference.defaults,
                storagePolicy: storagePolicy,
                keychainAccount: keychainAccount
            )
        }.value
    }

    public static func loadMasterKey(account: String = keychainAccount) throws -> Data {
        try loadMasterKey(
            account: account,
            copyMatching: SecItemCopyMatching,
            addItem: SecItemAdd
        )
    }

    public static func loadMasterKeyAsync(account: String = keychainAccount) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try loadMasterKey(account: account)
        }.value
    }

    static func loadMasterKey(
        account: String = keychainAccount,
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
        addItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    ) throws -> Data {
        if account == keychainAccount, let cachedKey = cachedMasterKeyDataValue() {
            return cachedKey
        }

        let synchronizedKey = try loadMasterKey(
            service: keychainService, account: account,
            synchronizable: true, copyMatching: copyMatching
        )
        let localCanonicalKey = try loadMasterKey(
            service: keychainService, account: account,
            synchronizable: false, copyMatching: copyMatching
        )
        let localKey: Data?
        if let localCanonicalKey {
            localKey = localCanonicalKey
        } else {
            localKey = try loadMasterKey(
                service: legacyKeychainService, account: account,
                copyMatching: copyMatching
            )
        }

        if let synchronizedKey {
            guard localKey == nil || localKey == synchronizedKey else {
                throw MasterKeyManagerError.conflictingICloudKey
            }
            if account == keychainAccount { cacheMasterKey(synchronizedKey) }
            return synchronizedKey
        }

        guard let localKey else {
            throw MasterKeyManagerError.keychainLoadFailed(errSecItemNotFound)
        }
        // Copy the exact existing bytes. Keep the old item for rollback; never
        // delete a usable key before the synchronizable copy can be read back.
        _ = try saveMasterKeyIfAbsent(
            localKey, service: keychainService, account: account,
            storagePolicy: .iCloudKeychain, addItem: addItem
        )
        guard let verifiedKey = try loadMasterKey(
            service: keychainService, account: account,
            synchronizable: true, copyMatching: copyMatching
        ) else {
            if account == keychainAccount { clearCache() }
            throw MasterKeyManagerError.keychainStoreFailed(errSecItemNotFound)
        }
        guard verifiedKey == localKey else {
            if account == keychainAccount { clearCache() }
            throw MasterKeyManagerError.conflictingICloudKey
        }
        if account == keychainAccount { cacheMasterKey(verifiedKey) }
        return verifiedKey
    }


    public static func currentScrambleSecret() -> String? {
        if let cachedSecret = cachedScrambleSecretValue() {
            return cachedSecret
        }
        guard let masterKey = try? loadMasterKey() else {
            return nil
        }
        return derivedKeyData(from: masterKey, purpose: .phraseRedaction).hexEncodedString()
    }

    public static func legacyScrambleSecret() -> String? {
        if let cachedSecret = cachedLegacyScrambleSecretValue() {
            return cachedSecret
        }
        guard let masterKey = try? loadMasterKey() else {
            return nil
        }
        return masterKey.hexEncodedString()
    }

    public static func derivedKeyData(
        for purpose: MasterKeyDerivedKeyPurpose,
        account: String = keychainAccount
    ) throws -> Data {
        let masterKey = try loadMasterKey(account: account)
        return derivedKeyData(from: masterKey, purpose: purpose)
    }

    public static func storagePolicy(defaults: UserDefaults? = nil) -> MasterKeyStoragePolicy {
        // A stored legacy preference must not create another device-only key.
        .iCloudKeychain
    }

    public static func protectPhraseLevelRedactionPhrases(_ phrases: [String]) throws -> String {
        let masterKeyData = try loadMasterKey()
        return try protectedPhraseLevelRedactionPayload(
            for: phrases,
            masterKeyData: masterKeyData
        )
    }

    public static func unprotectPhraseLevelRedactionPhrases(_ payload: String) throws -> [String] {
        let masterKeyData = try loadMasterKey()
        return try phraseLevelRedactionPhrases(
            fromProtectedPayload: payload,
            masterKeyData: masterKeyData
        )
    }

    package static func isProtectedPhraseLevelRedactionPayload(_ payload: String) -> Bool {
        payload.hasPrefix(protectedSettingsPayloadPrefix)
    }

    package static func protectedPhraseLevelRedactionPayload(
        for phrases: [String],
        masterKeyData: Data
    ) throws -> String {
        let data: Data
        do {
            data = try JSONEncoder().encode(phrases)
        } catch {
            throw MasterKeyManagerError.settingsEncryptionFailed(underlying: error.localizedDescription)
        }

        return try protectedSettingsPayload(
            data,
            purpose: phraseLevelRedactionSettingsPurpose,
            masterKeyData: masterKeyData
        )
    }

    package static func phraseLevelRedactionPhrases(
        fromProtectedPayload payload: String,
        masterKeyData: Data
    ) throws -> [String] {
        let data = try unprotectedSettingsPayload(
            payload,
            purpose: phraseLevelRedactionSettingsPurpose,
            masterKeyData: masterKeyData
        )

        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw MasterKeyManagerError.settingsDecryptionFailed(underlying: error.localizedDescription)
        }
    }
    public static func recoveryPhrase(for keyData: Data) -> String {
        precondition(keyData.count == keyByteCount)

        var payload = keyData
        payload.append(recoveryChecksumByte(for: keyData))

        return payload
            .recoveryPhraseWords()
            .joined(separator: " ")
    }

    public static func keyData(fromRecoveryPhrase phrase: String) throws -> Data {
        let words = phrase
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard words.count == recoveryPhraseWordCount else {
            throw MasterKeyManagerError.invalidRecoveryPhraseWordCount(words.count)
        }

        let payload = try Data(recoveryWords: words)
        guard payload.count == keyByteCount + checksumByteCount else {
            throw MasterKeyManagerError.invalidKeyLength(payload.count)
        }

        let keyData = payload.prefix(keyByteCount)
        let checksum = payload[keyByteCount]
        guard recoveryChecksumByte(for: keyData) == checksum else {
            throw MasterKeyManagerError.invalidRecoveryPhraseChecksum
        }

        return Data(keyData)
    }

    public static func recoveryPhrase(fromRecoveryText text: String) throws -> String {
        let directWords = text
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        if directWords.count == recoveryPhraseWordCount {
            let candidate = directWords.joined(separator: " ")
            _ = try keyData(fromRecoveryPhrase: candidate)
            return candidate
        }

        let tokens = text
            .lowercased()
            .split { !$0.isLetter }
            .map(String.init)

        guard tokens.count >= recoveryPhraseWordCount else {
            throw MasterKeyManagerError.invalidRecoveryPhraseWordCount(tokens.count)
        }

        for startIndex in 0...(tokens.count - recoveryPhraseWordCount) {
            let endIndex = startIndex + recoveryPhraseWordCount
            let candidate = tokens[startIndex..<endIndex].joined(separator: " ")
            if (try? keyData(fromRecoveryPhrase: candidate)) != nil {
                return candidate
            }
        }

        throw MasterKeyManagerError.invalidRecoveryPhraseChecksum
    }

    @discardableResult
    public static func restoreMasterKey(
        fromRecoveryPhrase phrase: String,
        defaults: UserDefaults? = nil,
        storagePolicy: MasterKeyStoragePolicy? = nil,
        keychainAccount: String = keychainAccount
    ) throws -> Bool {
        do {
            _ = try loadMasterKey(account: keychainAccount)
            return false
        } catch MasterKeyManagerError.keychainLoadFailed(let status) where status == errSecItemNotFound {
            // Keep an inaccessible existing key intact; restore only if missing.
        }

        let keyData = try keyData(fromRecoveryPhrase: phrase)
        let defaults = resolvedDefaults(defaults)
        let resolvedStoragePolicy = MasterKeyStoragePolicy.iCloudKeychain
        let created = try saveMasterKeyIfAbsent(
            keyData,
            service: keychainService,
            account: keychainAccount,
            storagePolicy: resolvedStoragePolicy
        )
        guard created else {
            return false
        }

        if keychainAccount == self.keychainAccount {
            defaults.set(Int64(Date().timeIntervalSince1970 * 1_000), forKey: createdAtDefaultsKey)
            defaults.set(resolvedStoragePolicy.rawValue, forKey: storagePolicyDefaultsKey)
            cacheMasterKey(keyData)
        }
        return true
    }

    @discardableResult
    public static func restoreMasterKey(
        fromRecoveryText text: String,
        defaults: UserDefaults? = nil,
        storagePolicy: MasterKeyStoragePolicy? = nil,
        keychainAccount: String = keychainAccount
    ) throws -> Bool {
        let phrase = try recoveryPhrase(fromRecoveryText: text)
        return try restoreMasterKey(
            fromRecoveryPhrase: phrase,
            defaults: defaults,
            storagePolicy: storagePolicy,
            keychainAccount: keychainAccount
        )
    }

    @discardableResult
    public static func restoreMasterKeyAsync(
        fromRecoveryText text: String,
        defaults: UserDefaults? = nil,
        storagePolicy: MasterKeyStoragePolicy? = nil,
        keychainAccount: String = keychainAccount
    ) async throws -> Bool {
        let defaultsReference = UserDefaultsReference(defaults: resolvedDefaults(defaults))
        return try await Task.detached(priority: .userInitiated) {
            try restoreMasterKey(
                fromRecoveryText: text,
                defaults: defaultsReference.defaults,
                storagePolicy: storagePolicy,
                keychainAccount: keychainAccount
            )
        }.value
    }

    public static func recoveryDocumentText(
        recoveryPhrase: String,
        createdAt: Date = Date(),
        storagePolicy: MasterKeyStoragePolicy = .iCloudKeychain
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: createdAt)

        return """
        Retrace Recovery Phrase

        Created At: \(timestamp)
        Storage: \(storagePolicy.recoveryDocumentStorageLabel)

        Keep this phrase offline and private.
        If this Mac loses its Keychain copy and you also lose this phrase, protected data cannot be recovered.

        Recovery Phrase:
        \(recoveryPhrase)
        """
    }

    public static func noteRecoveryPhraseShown(defaults: UserDefaults? = nil) {
        let defaults = resolvedDefaults(defaults)
        defaults.set(Int64(Date().timeIntervalSince1970 * 1_000), forKey: lastShownRecoveryDefaultsKey)
    }

    @discardableResult
    public static func resetMasterKey(
        defaults: UserDefaults? = nil,
        keychainAccount: String = keychainAccount
    ) throws -> Bool {
        try resetMasterKey(defaults: defaults, keychainAccount: keychainAccount) { deleteQuery in
            SecItemDelete(deleteQuery)
        }
    }

    @discardableResult
    public static func resetMasterKeyAsync(
        defaults: UserDefaults? = nil,
        keychainAccount: String = keychainAccount
    ) async throws -> Bool {
        let defaultsReference = UserDefaultsReference(defaults: resolvedDefaults(defaults))
        return try await Task.detached(priority: .utility) {
            try resetMasterKey(defaults: defaultsReference.defaults, keychainAccount: keychainAccount)
        }.value
    }

    @discardableResult
    static func resetMasterKey(
        defaults: UserDefaults? = nil,
        keychainAccount: String = keychainAccount,
        deleteMasterKey: (CFDictionary) -> OSStatus
    ) throws -> Bool {
        let defaults = resolvedDefaults(defaults)
        var removedAnyItem = false

        for service in keychainServices {
            let status = deleteMasterKey(
                makeDeleteQuery(service: service, account: keychainAccount) as CFDictionary
            )
            switch status {
            case errSecSuccess:
                removedAnyItem = true
            case errSecItemNotFound:
                continue
            default:
                throw MasterKeyManagerError.keychainDeleteFailed(status)
            }
        }

        if keychainAccount == self.keychainAccount {
            clearCache()
            clearMasterKeyDefaults(in: defaults)
        }
        return removedAnyItem
    }

    private static func randomMasterKeyData() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    private static func clearMasterKeyDefaults(in defaults: UserDefaults) {
        defaults.removeObject(forKey: createdAtDefaultsKey)
        defaults.removeObject(forKey: lastShownRecoveryDefaultsKey)
        defaults.removeObject(forKey: storagePolicyDefaultsKey)
    }

    private static func protectedSettingsPayload(
        _ payload: Data,
        purpose: String,
        masterKeyData: Data
    ) throws -> String {
        do {
            let sealedBox = try AES.GCM.seal(
                payload,
                using: settingsProtectionKey(
                    purpose: purpose,
                    masterKeyData: masterKeyData
                ),
                authenticating: Data(purpose.utf8)
            )
            guard let combined = sealedBox.combined else {
                throw MasterKeyManagerError.invalidProtectedSettingsPayload
            }
            return protectedSettingsPayloadPrefix + base64URLEncode(combined)
        } catch let error as MasterKeyManagerError {
            throw error
        } catch {
            throw MasterKeyManagerError.settingsEncryptionFailed(underlying: error.localizedDescription)
        }
    }

    private static func unprotectedSettingsPayload(
        _ payload: String,
        purpose: String,
        masterKeyData: Data
    ) throws -> Data {
        guard isProtectedPhraseLevelRedactionPayload(payload) else {
            throw MasterKeyManagerError.invalidProtectedSettingsPayload
        }

        let encodedPayload = String(payload.dropFirst(protectedSettingsPayloadPrefix.count))
        guard let combined = base64URLDecode(encodedPayload) else {
            throw MasterKeyManagerError.invalidProtectedSettingsPayload
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(
                sealedBox,
                using: settingsProtectionKey(
                    purpose: purpose,
                    masterKeyData: masterKeyData
                ),
                authenticating: Data(purpose.utf8)
            )
        } catch let error as MasterKeyManagerError {
            throw error
        } catch {
            throw MasterKeyManagerError.settingsDecryptionFailed(underlying: error.localizedDescription)
        }
    }

    private static func saveMasterKeyIfAbsent(_ keyData: Data) throws -> Bool {
        try saveMasterKeyIfAbsent(
            keyData,
            service: keychainService,
            account: keychainAccount,
            storagePolicy: .iCloudKeychain,
            addItem: SecItemAdd
        )
    }

    private static func saveMasterKeyIfAbsent(
        _ keyData: Data,
        service: String,
        account: String,
        storagePolicy: MasterKeyStoragePolicy
    ) throws -> Bool {
        try saveMasterKeyIfAbsent(
            keyData,
            service: service,
            account: account,
            storagePolicy: storagePolicy,
            addItem: SecItemAdd
        )
    }

    private static func saveMasterKeyIfAbsent(
        _ keyData: Data,
        service: String,
        account: String,
        storagePolicy: MasterKeyStoragePolicy,
        addItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    ) throws -> Bool {
        guard keyData.count == keyByteCount else {
            throw MasterKeyManagerError.invalidKeyLength(keyData.count)
        }

        // The canonical v2 item intentionally uses the modern accessible-item
        // format instead of the legacy trusted-application ACL.
        let status = addItem(
            makeAddQuery(
                service: service,
                account: account,
                keyData: keyData,
                storagePolicy: storagePolicy
            ) as CFDictionary,
            nil
        )
        if status == errSecDuplicateItem {
            if account == keychainAccount {
                cacheHasMasterKeyValue(true)
            }
            return false
        }
        guard status == errSecSuccess else {
            throw MasterKeyManagerError.keychainStoreFailed(status)
        }
        return true
    }

    private static func resolvedDefaults(_ defaults: UserDefaults?) -> UserDefaults {
        defaults ?? (UserDefaults(suiteName: settingsSuiteName) ?? .standard)
    }

    private static func makeLookupQuery(
        service: String,
        account: String,
        synchronizable: Bool? = nil,
        returnAttributes: Bool = false,
        authenticationContext: LAContext? = nil
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let synchronizable { query[kSecAttrSynchronizable as String] = synchronizable }
        if returnAttributes {
            query[kSecReturnAttributes as String] = true
        } else {
            query[kSecReturnData as String] = true
        }

        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }

        return query
    }

    private static func noInteractionAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func makeAddQuery(
        service: String,
        account: String,
        keyData: Data,
        storagePolicy: MasterKeyStoragePolicy
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: MasterKeyStoragePolicy.iCloudKeychain.accessibleAttribute,
            kSecAttrSynchronizable as String: true
        ]
    }

    private static func makeDeleteQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
    }

    private static func loadMasterKey(
        service: String,
        account: String,
        synchronizable: Bool? = nil,
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    ) throws -> Data? {
        var result: CFTypeRef?
        let status = copyMatching(
            makeLookupQuery(service: service, account: account, synchronizable: synchronizable) as CFDictionary,
            &result
        )

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let keyData = result as? Data else {
            throw MasterKeyManagerError.keychainLoadFailed(status)
        }

        guard keyData.count == keyByteCount else {
            throw MasterKeyManagerError.invalidKeyLength(keyData.count)
        }

        return keyData
    }

    private static func cacheMasterKey(_ keyData: Data) {
        cacheLock.lock()
        cachedMasterKeyData = keyData
        cachedScrambleSecret = derivedKeyData(
            from: keyData,
            purpose: .phraseRedaction
        ).hexEncodedString()
        cachedLegacyScrambleSecret = keyData.hexEncodedString()
        cachedHasMasterKey = true
        cacheLock.unlock()
    }

    public static func derivedKeyData(
        from masterKeyData: Data,
        purpose: MasterKeyDerivedKeyPurpose
    ) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKeyData),
            salt: derivationSalt,
            info: Data(purpose.rawValue.utf8),
            outputByteCount: keyByteCount
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    private static func clearCache() {
        cacheLock.lock()
        cachedMasterKeyData = nil
        cachedScrambleSecret = nil
        cachedLegacyScrambleSecret = nil
        cachedHasMasterKey = false
        cacheLock.unlock()
    }

    static func resetCacheForTests() {
        cacheLock.lock()
        cachedMasterKeyData = nil
        cachedScrambleSecret = nil
        cachedLegacyScrambleSecret = nil
        cachedHasMasterKey = nil
        cacheLock.unlock()
    }

    private static func cachedMasterKeyDataValue() -> Data? {
        cacheLock.lock()
        let value = cachedMasterKeyData
        cacheLock.unlock()
        return value
    }

    private static func cachedScrambleSecretValue() -> String? {
        cacheLock.lock()
        let value = cachedScrambleSecret
        cacheLock.unlock()
        return value
    }

    private static func cachedLegacyScrambleSecretValue() -> String? {
        cacheLock.lock()
        let value = cachedLegacyScrambleSecret
        cacheLock.unlock()
        return value
    }

    private static func cachedHasMasterKeyValue() -> Bool? {
        cacheLock.lock()
        let value = cachedHasMasterKey
        cacheLock.unlock()
        return value
    }

    private static func cacheHasMasterKeyValue(_ value: Bool) {
        cacheLock.lock()
        cachedHasMasterKey = value
        if value == false {
            cachedMasterKeyData = nil
            cachedScrambleSecret = nil
            cachedLegacyScrambleSecret = nil
        }
        cacheLock.unlock()
    }

    private static func settingsProtectionKey(
        purpose: String,
        masterKeyData: Data
    ) -> SymmetricKey {
        var material = Data("retrace.settings.".utf8)
        material.append(Data(purpose.utf8))
        material.append(0)
        material.append(masterKeyData)
        let digest = SHA256.hash(data: material)
        return SymmetricKey(data: Data(digest))
    }

    static func trustedApplicationPath(bundlePath: String, executablePath: String?) -> String? {
        guard !bundlePath.isEmpty else { return executablePath }
        if bundlePath.hasSuffix(".app") {
            return nil
        }
        return executablePath
    }

    private static func trustedApplicationPathForCurrentExecution() -> String? {
        trustedApplicationPath(
            bundlePath: Bundle.main.bundlePath,
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments.first
        )
    }

    private static func makeTrustedAccess(for trustedPath: String) throws -> SecAccess {
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = trustedPath.withCString { pathPointer in
            SecTrustedApplicationCreateFromPath(pathPointer, &trustedApplication)
        }
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw MasterKeyManagerError.trustedApplicationCreateFailed(trustedStatus)
        }

        let trustedList = [trustedApplication] as CFArray
        var access: SecAccess?
        let accessStatus = SecAccessCreate("Retrace Master Key" as CFString, trustedList, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw MasterKeyManagerError.accessCreateFailed(accessStatus)
        }
        return access
    }

    private static func recoveryChecksumByte(for keyData: Data) -> UInt8 {
        let digest = SHA256.hash(data: keyData)
        return digest.withUnsafeBytes { rawBuffer in
            rawBuffer[0]
        }
    }

    fileprivate static func recoveryWord(for index: Int) -> String {
        let onsetIndex = (index >> 8) & 0x0F
        let vowelIndex = (index >> 4) & 0x0F
        let codaIndex = index & 0x0F
        return onsetSyllables[onsetIndex] + vowelSyllables[vowelIndex] + codaSyllables[codaIndex]
    }

    fileprivate static func recoveryIndex(for word: String) -> Int? {
        recoveryWordToIndex[word]
    }
}

private struct UserDefaultsReference: @unchecked Sendable {
    let defaults: UserDefaults
}

private extension Data {
    init(recoveryWords: [String]) throws {
        self.init(capacity: recoveryWords.count / 2 * 3)

        for pairStart in stride(from: 0, to: recoveryWords.count, by: 2) {
            let firstWord = recoveryWords[pairStart]
            let secondWord = recoveryWords[pairStart + 1]

            guard let firstIndex = MasterKeyManager.recoveryIndex(for: firstWord) else {
                throw MasterKeyManagerError.invalidRecoveryPhraseWord(firstWord)
            }
            guard let secondIndex = MasterKeyManager.recoveryIndex(for: secondWord) else {
                throw MasterKeyManagerError.invalidRecoveryPhraseWord(secondWord)
            }

            let combined = (firstIndex << 12) | secondIndex
            append(UInt8((combined >> 16) & 0xFF))
            append(UInt8((combined >> 8) & 0xFF))
            append(UInt8(combined & 0xFF))
        }
    }

    func recoveryPhraseWords() -> [String] {
        precondition(count % 3 == 0)

        var words: [String] = []
        words.reserveCapacity(count / 3 * 2)

        for offset in stride(from: 0, to: count, by: 3) {
            let combined = (Int(self[offset]) << 16)
                | (Int(self[offset + 1]) << 8)
                | Int(self[offset + 2])

            words.append(MasterKeyManager.recoveryWord(for: (combined >> 12) & 0xFFF))
            words.append(MasterKeyManager.recoveryWord(for: combined & 0xFFF))
        }

        return words
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension MasterKeyManager {
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ encoded: String) -> Data? {
        let remainder = encoded.count % 4
        let padding: String
        switch remainder {
        case 0:
            padding = ""
        case 2:
            padding = "=="
        case 3:
            padding = "="
        default:
            return nil
        }

        let padded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        return Data(base64Encoded: padded)
    }
}
