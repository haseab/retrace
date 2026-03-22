import CryptoKit
import Foundation
import Security

public struct MasterKeyCreationResult: Sendable {
    public let created: Bool
    public let recoveryPhrase: String?

    public init(
        created: Bool,
        recoveryPhrase: String?
    ) {
        self.created = created
        self.recoveryPhrase = recoveryPhrase
    }
}

public enum MasterKeyManagerError: LocalizedError, Sendable {
    case invalidKeyLength(Int)
    case invalidRecoveryPhraseWordCount(Int)
    case invalidRecoveryPhraseWord(String)
    case invalidRecoveryPhraseChecksum
    case keychainStoreFailed(OSStatus)
    case keychainLoadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case trustedApplicationCreateFailed(OSStatus)
    case accessCreateFailed(OSStatus)

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
        case .keychainStoreFailed(let status):
            return "Failed to save the master key to Keychain (status: \(status))."
        case .keychainLoadFailed(let status):
            return "Failed to load the master key from Keychain (status: \(status))."
        case .keychainDeleteFailed(let status):
            return "Failed to delete the master key from Keychain (status: \(status))."
        case .trustedApplicationCreateFailed(let status):
            return "Failed to create a trusted application entry for the master key (status: \(status))."
        case .accessCreateFailed(let status):
            return "Failed to create access rules for the master key (status: \(status))."
        }
    }
}

public enum MasterKeyManager {
    public static let settingsSuiteName = "io.retrace.app"
    public static let keychainService = "io.retrace.app.masterkey"
    public static let keychainAccount = "master-key"
    public static let createdAtDefaultsKey = "masterKeyCreatedAtMs"
    public static let lastShownRecoveryDefaultsKey = "masterKeyRecoveryShownAtMs"

    private static let keyByteCount = 32
    private static let checksumByteCount = 1
    private static let recoveryPhraseWordCount = 22
    private static let cacheLock = NSLock()
    private static var cachedMasterKeyData: Data?
    private static var cachedScrambleSecret: String?
    private static var cachedHasMasterKey: Bool?

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

    public static func hasMasterKey() -> Bool {
        if let cachedValue = cachedHasMasterKeyValue() {
            return cachedValue
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            cacheHasMasterKeyValue(true)
            return true
        }
        if status == errSecItemNotFound {
            cacheHasMasterKeyValue(false)
        }
        return false
    }

    public static func createMasterKeyIfNeeded(defaults: UserDefaults? = nil) throws -> MasterKeyCreationResult {
        if hasMasterKey() {
            return MasterKeyCreationResult(
                created: false,
                recoveryPhrase: nil
            )
        }

        let defaults = defaults ?? (UserDefaults(suiteName: settingsSuiteName) ?? .standard)
        let masterKeyData = randomMasterKeyData()
        let created = try saveMasterKeyIfAbsent(masterKeyData)
        guard created else {
            return MasterKeyCreationResult(
                created: false,
                recoveryPhrase: nil
            )
        }

        let createdAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        defaults.set(createdAtMs, forKey: createdAtDefaultsKey)
        cacheMasterKey(masterKeyData)

        return MasterKeyCreationResult(
            created: true,
            recoveryPhrase: recoveryPhrase(for: masterKeyData)
        )
    }

    public static func loadMasterKey() throws -> Data {
        if let cachedKey = cachedMasterKeyDataValue() {
            return cachedKey
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let keyData = result as? Data else {
            if status == errSecItemNotFound {
                cacheHasMasterKeyValue(false)
            }
            throw MasterKeyManagerError.keychainLoadFailed(status)
        }
        guard keyData.count == keyByteCount else {
            throw MasterKeyManagerError.invalidKeyLength(keyData.count)
        }
        cacheMasterKey(keyData)
        return keyData
    }

    public static func currentScrambleSecret() -> String? {
        if let cachedSecret = cachedScrambleSecretValue() {
            return cachedSecret
        }
        guard let masterKey = try? loadMasterKey() else {
            return nil
        }
        return masterKey.hexEncodedString()
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
        defaults: UserDefaults? = nil
    ) throws -> Bool {
        guard !hasMasterKey() else {
            return false
        }

        let keyData = try keyData(fromRecoveryPhrase: phrase)
        let defaults = defaults ?? (UserDefaults(suiteName: settingsSuiteName) ?? .standard)
        let created = try saveMasterKeyIfAbsent(keyData)
        guard created else {
            return false
        }

        defaults.set(Int64(Date().timeIntervalSince1970 * 1_000), forKey: createdAtDefaultsKey)
        cacheMasterKey(keyData)
        return true
    }

    @discardableResult
    public static func restoreMasterKey(
        fromRecoveryText text: String,
        defaults: UserDefaults? = nil
    ) throws -> Bool {
        let phrase = try recoveryPhrase(fromRecoveryText: text)
        return try restoreMasterKey(fromRecoveryPhrase: phrase, defaults: defaults)
    }

    public static func recoveryDocumentText(
        recoveryPhrase: String,
        createdAt: Date = Date()
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: createdAt)

        return """
        Retrace Recovery Phrase

        Created At: \(timestamp)
        Storage: Keychain (this device only)

        Keep this phrase offline and private.
        If this Mac loses its Keychain copy and you also lose this phrase, protected data cannot be recovered.

        Recovery Phrase:
        \(recoveryPhrase)
        """
    }

    public static func noteRecoveryPhraseShown(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? (UserDefaults(suiteName: settingsSuiteName) ?? .standard)
        defaults.set(Int64(Date().timeIntervalSince1970 * 1_000), forKey: lastShownRecoveryDefaultsKey)
    }

    @discardableResult
    public static func resetMasterKey(defaults: UserDefaults? = nil) throws -> Bool {
        try resetMasterKey(defaults: defaults) { deleteQuery in
            SecItemDelete(deleteQuery)
        }
    }

    @discardableResult
    static func resetMasterKey(
        defaults: UserDefaults? = nil,
        deleteMasterKey: (CFDictionary) -> OSStatus
    ) throws -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        let defaults = defaults ?? (UserDefaults(suiteName: settingsSuiteName) ?? .standard)
        let status = deleteMasterKey(deleteQuery as CFDictionary)

        if status == errSecItemNotFound {
            clearCache()
            clearMasterKeyDefaults(in: defaults)
            return false
        }
        guard status == errSecSuccess else {
            throw MasterKeyManagerError.keychainDeleteFailed(status)
        }
        clearCache()
        clearMasterKeyDefaults(in: defaults)
        return true
    }

    private static func randomMasterKeyData() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    private static func clearMasterKeyDefaults(in defaults: UserDefaults) {
        defaults.removeObject(forKey: createdAtDefaultsKey)
        defaults.removeObject(forKey: lastShownRecoveryDefaultsKey)
    }

    private static func saveMasterKeyIfAbsent(_ keyData: Data) throws -> Bool {
        guard keyData.count == keyByteCount else {
            throw MasterKeyManagerError.invalidKeyLength(keyData.count)
        }

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData
        ]

        if let trustedPath = trustedApplicationPathForCurrentExecution() {
            addQuery[kSecAttrAccess as String] = try makeTrustedAccess(for: trustedPath)
        } else {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecAttrSynchronizable as String] = false
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            cacheHasMasterKeyValue(true)
            return false
        }
        guard status == errSecSuccess else {
            throw MasterKeyManagerError.keychainStoreFailed(status)
        }
        cacheMasterKey(keyData)
        return true
    }

    private static func cacheMasterKey(_ keyData: Data) {
        cacheLock.lock()
        cachedMasterKeyData = keyData
        cachedScrambleSecret = keyData.hexEncodedString()
        cachedHasMasterKey = true
        cacheLock.unlock()
    }

    private static func clearCache() {
        cacheLock.lock()
        cachedMasterKeyData = nil
        cachedScrambleSecret = nil
        cachedHasMasterKey = false
        cacheLock.unlock()
    }

    static func resetCacheForTests() {
        cacheLock.lock()
        cachedMasterKeyData = nil
        cachedScrambleSecret = nil
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
        }
        cacheLock.unlock()
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
