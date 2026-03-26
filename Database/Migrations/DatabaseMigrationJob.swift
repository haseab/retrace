import Foundation
import CryptoKit

public enum DatabaseMigrationKind: String, Codable, Sendable {
    case encrypt
    case decrypt
    case schema
}

public enum DatabaseMigrationPhase: String, Codable, Sendable {
    case preflight
    case shadowA = "shadow_a"
    case shadowBTransform = "shadow_b_transform"
    case verify
    case swap
    case cleanup
    case completed
    case failed
}

public struct DatabaseMigrationJob: Codable, Sendable {
    public let id: UUID
    public let kind: DatabaseMigrationKind
    public var phase: DatabaseMigrationPhase

    public let databasePath: String
    public let storageRootPath: String

    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var completedAt: Date?

    public var requiredFreeSpaceBytes: Int64?
    public var observedFootprintBytes: Int64?
    public var estimatedDurationSeconds: TimeInterval?

    public var bytesProcessed: Int64
    public var lastMessage: String?

    public var interruptionReason: String?
    public var lastError: String?
    public var scheduledSchemaVersion: Int?

    /// For encrypt/decrypt jobs this stores where the target key should be read from.
    /// For schema jobs this can be nil.
    public var keychainAccount: String?
    public var keyMaterialSource: DatabaseKeyMaterialSource?

    public init(
        id: UUID = UUID(),
        kind: DatabaseMigrationKind,
        phase: DatabaseMigrationPhase = .preflight,
        databasePath: String,
        storageRootPath: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        requiredFreeSpaceBytes: Int64? = nil,
        observedFootprintBytes: Int64? = nil,
        estimatedDurationSeconds: TimeInterval? = nil,
        bytesProcessed: Int64 = 0,
        lastMessage: String? = nil,
        interruptionReason: String? = nil,
        lastError: String? = nil,
        scheduledSchemaVersion: Int? = nil,
        keychainAccount: String? = nil,
        keyMaterialSource: DatabaseKeyMaterialSource? = nil
    ) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.databasePath = databasePath
        self.storageRootPath = storageRootPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.requiredFreeSpaceBytes = requiredFreeSpaceBytes
        self.observedFootprintBytes = observedFootprintBytes
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.bytesProcessed = bytesProcessed
        self.lastMessage = lastMessage
        self.interruptionReason = interruptionReason
        self.lastError = lastError
        self.scheduledSchemaVersion = scheduledSchemaVersion
        self.keychainAccount = keychainAccount
        self.keyMaterialSource = keyMaterialSource
    }

    public init(
        id: UUID = UUID(),
        kind: DatabaseMigrationKind,
        phase: DatabaseMigrationPhase = .preflight,
        databasePath: String,
        storageRootPath: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        requiredFreeSpaceBytes: Int64? = nil,
        observedFootprintBytes: Int64? = nil,
        estimatedDurationSeconds: TimeInterval? = nil,
        bytesProcessed: Int64 = 0,
        lastMessage: String? = nil,
        interruptionReason: String? = nil,
        lastError: String? = nil,
        keychainAccount: String? = nil,
        keyMaterialSource: DatabaseKeyMaterialSource? = nil
    ) {
        self.init(
            id: id,
            kind: kind,
            phase: phase,
            databasePath: databasePath,
            storageRootPath: storageRootPath,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            completedAt: completedAt,
            requiredFreeSpaceBytes: requiredFreeSpaceBytes,
            observedFootprintBytes: observedFootprintBytes,
            estimatedDurationSeconds: estimatedDurationSeconds,
            bytesProcessed: bytesProcessed,
            lastMessage: lastMessage,
            interruptionReason: interruptionReason,
            lastError: lastError,
            scheduledSchemaVersion: nil,
            keychainAccount: keychainAccount,
            keyMaterialSource: keyMaterialSource
        )
    }

    public var isTerminal: Bool {
        phase == .completed || phase == .failed
    }
}

public struct DatabaseMigrationStatus: Sendable {
    public let isActive: Bool
    public let jobID: UUID?
    public let kind: DatabaseMigrationKind?
    public let phase: DatabaseMigrationPhase?
    public let progress: Double
    public let message: String?
    public let estimatedSecondsRemaining: TimeInterval?
    public let updatedAt: Date

    public init(
        isActive: Bool,
        jobID: UUID? = nil,
        kind: DatabaseMigrationKind? = nil,
        phase: DatabaseMigrationPhase? = nil,
        progress: Double = 0,
        message: String? = nil,
        estimatedSecondsRemaining: TimeInterval? = nil,
        updatedAt: Date = Date()
    ) {
        self.isActive = isActive
        self.jobID = jobID
        self.kind = kind
        self.phase = phase
        self.progress = min(max(progress, 0), 1)
        self.message = message
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.updatedAt = updatedAt
    }

    public static let inactive = DatabaseMigrationStatus(isActive: false)
}

public enum DatabaseRecoveryPhraseError: LocalizedError, Sendable {
    case invalidWordCount
    case unknownWord(String)
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidWordCount:
            return "Recovery phrases must contain exactly 24 words."
        case .unknownWord(let word):
            return "Unknown recovery word: \(word)"
        case .checksumMismatch:
            return "Recovery phrase checksum is invalid."
        }
    }
}

public struct DatabaseRecoveryPhrase: Sendable, Equatable {
    public static let wordCount = 24
    private static let seedByteCount = 23

    public let words: [String]

    public init(words: [String]) throws {
        guard words.count == Self.wordCount else {
            throw DatabaseRecoveryPhraseError.invalidWordCount
        }
        self.words = words
        _ = try Self.seedBytes(from: words)
    }

    public var phraseText: String {
        words.joined(separator: " ")
    }

    public var exportText: String {
        """
        Retrace Database Recovery Key

        Keep these 24 words backed up offline. If your keychain key is lost, this phrase is required to restore database access.

        \(phraseText)
        """
    }

    public var derivedKeyData: Data {
        let seed = try? Self.seedBytes(from: words)
        let digest = SHA256.hash(data: seed ?? Data())
        return Data(digest)
    }

    public static func generate() -> DatabaseRecoveryPhrase {
        let seed = Data((0..<seedByteCount).map { _ in UInt8.random(in: .min ... .max) })
        let checksum = checksumByte(for: seed)
        let bytes = Array(seed) + [checksum]
        let words = bytes.map { wordList[Int($0)] }
        return try! DatabaseRecoveryPhrase(words: words)
    }

    public static func parse(_ text: String) throws -> DatabaseRecoveryPhrase {
        let words = text
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { reverseLookup[$0] != nil }
        return try DatabaseRecoveryPhrase(words: words)
    }

    private static func seedBytes(from words: [String]) throws -> Data {
        guard words.count == wordCount else {
            throw DatabaseRecoveryPhraseError.invalidWordCount
        }

        let bytes = try words.map { word -> UInt8 in
            guard let value = reverseLookup[word.lowercased()] else {
                throw DatabaseRecoveryPhraseError.unknownWord(word)
            }
            return value
        }

        let seed = Data(bytes.prefix(seedByteCount))
        let checksum = bytes.last ?? 0
        guard checksum == checksumByte(for: seed) else {
            throw DatabaseRecoveryPhraseError.checksumMismatch
        }

        return seed
    }

    private static func checksumByte(for seed: Data) -> UInt8 {
        Array(SHA256.hash(data: seed)).first ?? 0
    }

    private static let reverseLookup: [String: UInt8] = {
        Dictionary(uniqueKeysWithValues: wordList.enumerated().map { index, word in
            (word, UInt8(index))
        })
    }()

    private static let wordList: [String] = {
        let prefixes = [
            "amber", "apex", "atlas", "brisk",
            "cinder", "cobalt", "delta", "ember",
            "fable", "glint", "harbor", "ivory",
            "jasper", "lumen", "nova", "onyx"
        ]
        let suffixes = [
            "acre", "beam", "bloom", "brook",
            "crest", "field", "flare", "forge",
            "grove", "haven", "line", "mark",
            "point", "ridge", "stone", "vale"
        ]

        return prefixes.flatMap { prefix in
            suffixes.map { suffix in
                prefix + suffix
            }
        }
    }()
}
