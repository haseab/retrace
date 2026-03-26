import Foundation
import SQLCipher
import Shared

private let databaseIdentityTableName = "database_identity"
private let databaseIdentitySingletonID = 1
private let libraryManifestFileName = ".retrace-library.json"
private let libraryManifestFormatVersion = 1
private let vaultMetadataFileName = ".retrace-vault.json"
private let vaultMetadataFormatVersion = 1
private let legacyDatabaseFileName = "retrace.db"
private let legacySQLiteWALFileName = "retrace.db-wal"
private let legacySQLiteSHMFileName = "retrace.db-shm"
private let legacyChunksDirectoryName = "chunks"
private let legacyCaptureWALDirectoryName = "wal"
private let appHomeArtifactNames = [
    "logs",
    "temp",
    "models",
    "app_names.json",
    "favicon_cache",
    "app_icon_colors.json",
]

public struct DatabaseIdentity: Sendable, Equatable, Codable {
    public let libraryID: String
    public let vaultID: String
    public let generationID: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        libraryID: String,
        vaultID: String,
        generationID: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.libraryID = libraryID
        self.vaultID = vaultID
        self.generationID = generationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Backward-compatible alias while the underlying SQL schema still uses `shard_id`.
    public var shardID: String {
        vaultID
    }
}

struct DatabaseLibraryManifest: Sendable, Equatable, Codable {
    let formatVersion: Int
    let libraryID: String
    let updatedAt: Date
}

public struct RetraceVaultMetadata: Sendable, Equatable, Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case vaultID
        case libraryID
        case bootstrapPending
        case createdAt
        case updatedAt
    }

    public let formatVersion: Int
    public let vaultID: String
    public let libraryID: String?
    public let bootstrapPending: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        formatVersion: Int = 1,
        vaultID: String,
        libraryID: String?,
        bootstrapPending: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.formatVersion = formatVersion
        self.vaultID = vaultID
        self.libraryID = libraryID
        self.bootstrapPending = bootstrapPending
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion)
            ?? vaultMetadataFormatVersion
        vaultID = try container.decode(String.self, forKey: .vaultID)
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        bootstrapPending = try container.decodeIfPresent(Bool.self, forKey: .bootstrapPending) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public enum RetraceVaultLayoutError: LocalizedError, Equatable {
    case recoveryRequired(rootPath: String)

    public var errorDescription: String? {
        switch self {
        case .recoveryRequired(let rootPath):
            return "Retrace couldn't safely migrate the vault layout at \(rootPath). Use the vault recovery flow to locate an existing vault or create a new default vault."
        }
    }
}

struct VaultLayoutContext: Sendable, Equatable {
    let appHomeRootPath: String
    let defaultVaultsRootPath: String

    init(appHomeRootPath: String, defaultVaultsRootPath: String? = nil) {
        self.appHomeRootPath = NSString(string: appHomeRootPath).expandingTildeInPath
        self.defaultVaultsRootPath = NSString(
            string: defaultVaultsRootPath
                ?? (self.appHomeRootPath as NSString).appendingPathComponent(AppPaths.vaultsDirectoryName)
        ).expandingTildeInPath
    }

    static let live = VaultLayoutContext(
        appHomeRootPath: AppPaths.expandedAppSupportRoot,
        defaultVaultsRootPath: AppPaths.expandedDefaultVaultsRoot
    )
}

public enum RetraceVaultLayoutManager {
    private enum VaultAssetState {
        case none
        case partial
        case complete
    }

    private struct ChildVaultInventory {
        let completePaths: [String]
        let partialPaths: [String]

        static let empty = ChildVaultInventory(completePaths: [], partialPaths: [])

        var hasAny: Bool {
            !completePaths.isEmpty || !partialPaths.isEmpty
        }

        var hasSingleCompleteOnly: Bool {
            completePaths.count == 1 && partialPaths.isEmpty
        }

        var firstCompletePath: String? {
            completePaths.first
        }
    }

    private struct RootLayoutSnapshot {
        let rootPath: String
        let canonicalContainerPath: String
        let hasVaultsDirectory: Bool
        let canonicalVaults: ChildVaultInventory
        let looseVaults: ChildVaultInventory
        let legacyAssets: VaultAssetState
    }

    public static func prepareActiveVaultIfNeeded() throws -> String {
        let defaults = UserDefaults(suiteName: AppPaths.settingsSuiteName) ?? .standard

        if let customPath = defaults.string(forKey: AppPaths.customRetraceVaultLocationDefaultsKey) {
            let prepared = try canonicalizeSelectedVaultPath(customPath, context: .live)
            if NSString(string: customPath).expandingTildeInPath != prepared {
                defaults.set(prepared, forKey: AppPaths.customRetraceVaultLocationDefaultsKey)
            }
            return prepared
        }

        let prepared = try prepareDefaultVaultIfNeeded(defaults: defaults, context: .live)
        defaults.set(prepared, forKey: AppPaths.defaultRetraceVaultLocationDefaultsKey)
        return prepared
    }

    public static func canonicalizeSelectedVaultPath(_ selectedPath: String) throws -> String {
        try canonicalizeSelectedVaultPath(selectedPath, context: .live)
    }

    public static func forceCreateDefaultVault() throws -> String {
        try createVault(in: VaultLayoutContext.live.defaultVaultsRootPath, context: .live)
    }

    static func canonicalizeSelectedVaultPath(
        _ selectedPath: String,
        context: VaultLayoutContext
    ) throws -> String {
        let expandedPath = NSString(string: selectedPath).expandingTildeInPath

        if isExplicitVaultFolder(expandedPath) {
            return try ensureVaultFolder(at: expandedPath, context: context)
        }

        return try prepareRootLayoutIfNeeded(
            at: expandedPath,
            allowDefaultBootstrapCreation: false,
            context: context
        )
    }

    static func prepareRootLayoutIfNeeded(
        at rootPath: String,
        allowDefaultBootstrapCreation: Bool,
        context: VaultLayoutContext
    ) throws -> String {
        let expandedRoot = NSString(string: rootPath).expandingTildeInPath
        let snapshot = snapshotRootLayout(at: expandedRoot)

        if let canonicalVaultPath = snapshot.canonicalVaults.firstCompletePath {
            return try ensureVaultFolder(at: canonicalVaultPath, context: context)
        }

        if snapshot.hasVaultsDirectory {
            if allowDefaultBootstrapCreation && shouldCreateFreshDefaultVault(from: snapshot) {
                return try createVault(in: snapshot.canonicalContainerPath, context: context)
            }

            if !snapshot.canonicalVaults.hasAny && !snapshot.looseVaults.hasAny && snapshot.legacyAssets == .complete {
                return try migrateLegacyRoot(
                    at: expandedRoot,
                    targetParentPath: snapshot.canonicalContainerPath,
                    context: context
                )
            }

            throw RetraceVaultLayoutError.recoveryRequired(rootPath: expandedRoot)
        }

        if snapshot.looseVaults.hasSingleCompleteOnly && snapshot.legacyAssets == .none {
            return try moveLooseVaultIntoCanonicalContainer(
                from: snapshot.looseVaults.completePaths[0],
                rootPath: expandedRoot,
                targetParentPath: snapshot.canonicalContainerPath,
                context: context
            )
        }

        if !snapshot.looseVaults.hasAny && snapshot.legacyAssets == .complete {
            return try migrateLegacyRoot(
                at: expandedRoot,
                targetParentPath: snapshot.canonicalContainerPath,
                context: context
            )
        }

        if allowDefaultBootstrapCreation && shouldCreateFreshDefaultVault(from: snapshot) {
            return try createVault(in: snapshot.canonicalContainerPath, context: context)
        }

        throw RetraceVaultLayoutError.recoveryRequired(rootPath: expandedRoot)
    }

    private static func prepareDefaultVaultIfNeeded(
        defaults: UserDefaults,
        context: VaultLayoutContext
    ) throws -> String {
        if let stored = defaults.string(forKey: AppPaths.defaultRetraceVaultLocationDefaultsKey) {
            let expanded = NSString(string: stored).expandingTildeInPath
            if isExplicitVaultFolder(expanded) {
                return try ensureVaultFolder(at: expanded, context: context)
            }
            return try prepareRootLayoutIfNeeded(
                at: expanded,
                allowDefaultBootstrapCreation: false,
                context: context
            )
        }

        return try prepareRootLayoutIfNeeded(
            at: context.appHomeRootPath,
            allowDefaultBootstrapCreation: true,
            context: context
        )
    }

    private static func createVault(in parentPath: String, context: VaultLayoutContext) throws -> String {
        let expandedParent = NSString(string: parentPath).expandingTildeInPath
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: expandedParent, isDirectory: true),
            withIntermediateDirectories: true
        )

        let libraryID = try ensureAppLibraryID(context: context)
        let vaultPrefix = vaultFolderPrefixHint(for: expandedParent)
        let vaultID = makeVaultIdentifier(prefix: vaultPrefix)
        let vaultFolderName = "\(AppPaths.vaultFolderPrefix)\(vaultID.prefix(6))"
        let vaultPath = (expandedParent as NSString).appendingPathComponent(vaultFolderName)

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: vaultPath, isDirectory: true),
            withIntermediateDirectories: true
        )

        let now = Date()
        try DatabaseIdentityStore.persistVaultMetadata(
            RetraceVaultMetadata(
                vaultID: vaultID,
                libraryID: libraryID,
                bootstrapPending: true,
                createdAt: now,
                updatedAt: now
            ),
            vaultPath: vaultPath
        )

        return vaultPath
    }

    private static func ensureVaultFolder(at vaultPath: String, context: VaultLayoutContext) throws -> String {
        let expandedVaultPath = NSString(string: vaultPath).expandingTildeInPath
        let vaultURL = URL(fileURLWithPath: expandedVaultPath, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        let currentMetadata = try DatabaseIdentityStore.loadVaultMetadata(vaultPath: expandedVaultPath)
        let existingIdentity = try loadIdentityForVaultDatabaseIfPresent(at: expandedVaultPath)
        let libraryManifest = try DatabaseIdentityStore.loadManifest(
            storageRootPath: context.appHomeRootPath
        )

        let libraryID: String
        if let existingLibraryID = existingIdentity?.libraryID {
            libraryID = existingLibraryID
        } else if let metadataLibraryID = currentMetadata?.libraryID {
            libraryID = metadataLibraryID
        } else if let manifestLibraryID = libraryManifest?.libraryID {
            libraryID = manifestLibraryID
        } else {
            libraryID = try ensureAppLibraryID(context: context)
        }

        let vaultID = existingIdentity?.vaultID
            ?? currentMetadata?.vaultID
            ?? makeVaultIdentifier(prefix: vaultFolderPrefixHint(for: expandedVaultPath))
        let createdAt = currentMetadata?.createdAt ?? existingIdentity?.createdAt ?? Date()
        let bootstrapPending = existingIdentity == nil
            ? (currentMetadata?.bootstrapPending ?? true)
            : false
        let metadata = RetraceVaultMetadata(
            vaultID: vaultID,
            libraryID: libraryID,
            bootstrapPending: bootstrapPending,
            createdAt: createdAt,
            updatedAt: Date()
        )

        try DatabaseIdentityStore.persistVaultMetadata(metadata, vaultPath: expandedVaultPath)
        try DatabaseIdentityStore.persistManifest(
            DatabaseLibraryManifest(
                formatVersion: libraryManifestFormatVersion,
                libraryID: libraryID,
                updatedAt: Date()
            ),
            storageRootPath: context.appHomeRootPath
        )
        return expandedVaultPath
    }

    private static func migrateLegacyRoot(
        at sourceRootPath: String,
        targetParentPath: String,
        context: VaultLayoutContext
    ) throws -> String {
        let expandedSourceRoot = NSString(string: sourceRootPath).expandingTildeInPath
        let expandedTargetParent = NSString(string: targetParentPath).expandingTildeInPath
        let existingIdentity = try loadIdentityForDatabaseIfPresent(
            at: (expandedSourceRoot as NSString).appendingPathComponent(legacyDatabaseFileName)
        )
        let legacyManifest = try DatabaseIdentityStore.loadManifest(storageRootPath: expandedSourceRoot)
        let appLibraryManifest = try DatabaseIdentityStore.loadManifest(
            storageRootPath: context.appHomeRootPath
        )

        let libraryID: String
        if let existingLibraryID = existingIdentity?.libraryID {
            libraryID = existingLibraryID
        } else if let legacyLibraryID = legacyManifest?.libraryID {
            libraryID = legacyLibraryID
        } else if let appLibraryID = appLibraryManifest?.libraryID {
            libraryID = appLibraryID
        } else {
            libraryID = try ensureAppLibraryID(context: context)
        }
        let sourceVaultMetadata = try DatabaseIdentityStore.loadVaultMetadata(vaultPath: expandedSourceRoot)
        let vaultID = existingIdentity?.vaultID
            ?? sourceVaultMetadata?.vaultID
            ?? makeVaultIdentifier(prefix: nil)
        let vaultFolderName = "\(AppPaths.vaultFolderPrefix)\(vaultID.prefix(6))"
        let targetVaultPath = (expandedTargetParent as NSString).appendingPathComponent(vaultFolderName)

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: expandedTargetParent, isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: targetVaultPath, isDirectory: true),
            withIntermediateDirectories: true
        )

        for itemName in [
            legacyDatabaseFileName,
            legacySQLiteWALFileName,
            legacySQLiteSHMFileName,
            legacyChunksDirectoryName,
            legacyCaptureWALDirectoryName,
        ] {
            try moveItemIfPresent(
                from: (expandedSourceRoot as NSString).appendingPathComponent(itemName),
                to: (targetVaultPath as NSString).appendingPathComponent(itemName)
            )
        }

        if expandedSourceRoot != context.appHomeRootPath {
            try migrateAppHomeArtifacts(from: expandedSourceRoot, to: context.appHomeRootPath)
        }

        try DatabaseIdentityStore.persistManifest(
            DatabaseLibraryManifest(
                formatVersion: libraryManifestFormatVersion,
                libraryID: libraryID,
                updatedAt: Date()
            ),
            storageRootPath: context.appHomeRootPath
        )

        let createdAt = existingIdentity?.createdAt ?? Date()
        try DatabaseIdentityStore.persistVaultMetadata(
            RetraceVaultMetadata(
                vaultID: vaultID,
                libraryID: libraryID,
                bootstrapPending: false,
                createdAt: createdAt,
                updatedAt: Date()
            ),
            vaultPath: targetVaultPath
        )

        return targetVaultPath
    }

    private static func moveLooseVaultIntoCanonicalContainer(
        from sourceVaultPath: String,
        rootPath: String,
        targetParentPath: String,
        context: VaultLayoutContext
    ) throws -> String {
        let expandedRoot = NSString(string: rootPath).expandingTildeInPath
        let expandedSourceVault = NSString(string: sourceVaultPath).expandingTildeInPath
        let expandedTargetParent = NSString(string: targetParentPath).expandingTildeInPath
        let destinationVaultPath = (expandedTargetParent as NSString).appendingPathComponent(
            (expandedSourceVault as NSString).lastPathComponent
        )

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: expandedTargetParent, isDirectory: true),
            withIntermediateDirectories: true
        )

        if expandedSourceVault != destinationVaultPath,
           !FileManager.default.fileExists(atPath: destinationVaultPath) {
            try FileManager.default.moveItem(
                at: URL(fileURLWithPath: expandedSourceVault, isDirectory: true),
                to: URL(fileURLWithPath: destinationVaultPath, isDirectory: true)
            )
        }

        if expandedRoot != context.appHomeRootPath {
            try migrateAppHomeArtifacts(from: expandedRoot, to: context.appHomeRootPath)
        }

        return try ensureVaultFolder(at: destinationVaultPath, context: context)
    }

    private static func migrateAppHomeArtifacts(from sourceRoot: String, to appHomeRoot: String) throws {
        guard sourceRoot != appHomeRoot else { return }
        for itemName in appHomeArtifactNames {
            try moveItemIfPresent(
                from: (sourceRoot as NSString).appendingPathComponent(itemName),
                to: (appHomeRoot as NSString).appendingPathComponent(itemName)
            )
        }
    }

    private static func ensureAppLibraryID(context: VaultLayoutContext) throws -> String {
        if let manifest = try DatabaseIdentityStore.loadManifest(storageRootPath: context.appHomeRootPath) {
            return manifest.libraryID
        }

        let libraryID = makeVaultIdentifier(prefix: nil)
        try DatabaseIdentityStore.persistManifest(
            DatabaseLibraryManifest(
                formatVersion: libraryManifestFormatVersion,
                libraryID: libraryID,
                updatedAt: Date()
            ),
            storageRootPath: context.appHomeRootPath
        )
        return libraryID
    }

    private static func loadIdentityForVaultDatabaseIfPresent(at vaultPath: String) throws -> DatabaseIdentity? {
        let dbPath = (vaultPath as NSString).appendingPathComponent(legacyDatabaseFileName)
        return try loadIdentityForDatabaseIfPresent(at: dbPath)
    }

    private static func loadIdentityForDatabaseIfPresent(at databasePath: String) throws -> DatabaseIdentity? {
        let expandedPath = NSString(string: databasePath).expandingTildeInPath
        let state = DatabaseManager.databaseFileEncryptionState(at: expandedPath)

        switch state {
        case .missing, .empty:
            return nil
        case .plaintext:
            return try DatabaseIdentityStore.readIdentity(at: expandedPath)
        case .encrypted:
            let resolution = try DatabaseManager.resolveDatabaseConnection(
                at: expandedPath,
                preferredEncrypted: true,
                encryptedKeyAccounts: [AppPaths.keychainAccount, DatabaseManager.pendingMigrationKeychainAccount]
            )
            guard resolution.mode == .encrypted else {
                return nil
            }
            let account = resolution.keychainAccount ?? AppPaths.keychainAccount
            let keyData = try DatabaseManager.loadDatabaseKeyFromKeychain(
                account: account,
                source: resolution.keyMaterialSource
            )
            return try DatabaseIdentityStore.readIdentity(at: expandedPath, keyData: keyData)
        }
    }

    private static func isExplicitVaultFolder(_ path: String) -> Bool {
        let expandedPath = NSString(string: path).expandingTildeInPath
        if (expandedPath as NSString).lastPathComponent.hasPrefix(AppPaths.vaultFolderPrefix) {
            return true
        }
        return FileManager.default.fileExists(
            atPath: DatabaseIdentityStore.vaultMetadataURL(vaultPath: expandedPath).path
        )
    }

    private static func moveItemIfPresent(from sourcePath: String, to destinationPath: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourcePath) else { return }
        guard !fileManager.fileExists(atPath: destinationPath) else { return }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: (destinationPath as NSString).deletingLastPathComponent, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(
            at: URL(fileURLWithPath: sourcePath),
            to: URL(fileURLWithPath: destinationPath)
        )
    }

    private static func vaultFolderPrefixHint(for path: String) -> String? {
        let lastComponent = (NSString(string: path).expandingTildeInPath as NSString).lastPathComponent
        guard lastComponent.hasPrefix(AppPaths.vaultFolderPrefix) else {
            return nil
        }
        let suffix = String(lastComponent.dropFirst(AppPaths.vaultFolderPrefix.count))
        guard suffix.count == 6 else { return nil }
        return suffix.lowercased()
    }

    private static func snapshotRootLayout(at rootPath: String) -> RootLayoutSnapshot {
        let expandedRoot = NSString(string: rootPath).expandingTildeInPath
        let isVaultsContainer = (expandedRoot as NSString).lastPathComponent == AppPaths.vaultsDirectoryName
        let canonicalContainerPath = isVaultsContainer
            ? expandedRoot
            : (expandedRoot as NSString).appendingPathComponent(AppPaths.vaultsDirectoryName)

        return RootLayoutSnapshot(
            rootPath: expandedRoot,
            canonicalContainerPath: canonicalContainerPath,
            hasVaultsDirectory: isVaultsContainer || directoryExists(at: canonicalContainerPath),
            canonicalVaults: scanVaultChildren(
                in: (isVaultsContainer || directoryExists(at: canonicalContainerPath)) ? canonicalContainerPath : nil
            ),
            looseVaults: isVaultsContainer ? .empty : scanVaultChildren(in: expandedRoot),
            legacyAssets: legacyAssetState(at: expandedRoot)
        )
    }

    private static func shouldCreateFreshDefaultVault(from snapshot: RootLayoutSnapshot) -> Bool {
        snapshot.legacyAssets == .none
            && !snapshot.canonicalVaults.hasAny
            && !snapshot.looseVaults.hasAny
    }

    private static func scanVaultChildren(in rootPath: String?) -> ChildVaultInventory {
        guard let rootPath else {
            return .empty
        }

        let expandedRoot = NSString(string: rootPath).expandingTildeInPath
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: expandedRoot, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        let candidateVaults = contents
            .filter { candidate in
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
                return exists
                    && isDirectory.boolValue
                    && candidate.lastPathComponent.hasPrefix(AppPaths.vaultFolderPrefix)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var completePaths: [String] = []
        var partialPaths: [String] = []
        for candidate in candidateVaults {
            switch vaultAssetState(at: candidate.path) {
            case .complete:
                completePaths.append(candidate.path)
            case .none, .partial:
                partialPaths.append(candidate.path)
            }
        }

        return ChildVaultInventory(completePaths: completePaths, partialPaths: partialPaths)
    }

    private static func legacyAssetState(at path: String) -> VaultAssetState {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let fileManager = FileManager.default
        let dbPath = (expandedPath as NSString).appendingPathComponent(legacyDatabaseFileName)
        let chunksPath = (expandedPath as NSString).appendingPathComponent(legacyChunksDirectoryName)
        let sqliteWALPath = (expandedPath as NSString).appendingPathComponent(legacySQLiteWALFileName)
        let sqliteSHMPath = (expandedPath as NSString).appendingPathComponent(legacySQLiteSHMFileName)
        let captureWALPath = (expandedPath as NSString).appendingPathComponent(legacyCaptureWALDirectoryName)

        let hasDatabase = fileManager.fileExists(atPath: dbPath)
        let hasChunks = fileManager.fileExists(atPath: chunksPath)
        let hasSQLiteWAL = fileManager.fileExists(atPath: sqliteWALPath)
        let hasSQLiteSHM = fileManager.fileExists(atPath: sqliteSHMPath)
        let hasCaptureWAL = fileManager.fileExists(atPath: captureWALPath)

        if hasDatabase && hasChunks {
            return .complete
        }

        if hasDatabase || hasChunks || hasSQLiteWAL || hasSQLiteSHM || hasCaptureWAL {
            return .partial
        }

        return .none
    }

    private static func vaultAssetState(at path: String) -> VaultAssetState {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let fileManager = FileManager.default
        let dbPath = (expandedPath as NSString).appendingPathComponent(legacyDatabaseFileName)
        let chunksPath = (expandedPath as NSString).appendingPathComponent(legacyChunksDirectoryName)
        let sqliteWALPath = (expandedPath as NSString).appendingPathComponent(legacySQLiteWALFileName)
        let sqliteSHMPath = (expandedPath as NSString).appendingPathComponent(legacySQLiteSHMFileName)
        let captureWALPath = (expandedPath as NSString).appendingPathComponent(legacyCaptureWALDirectoryName)
        let metadataPath = DatabaseIdentityStore.vaultMetadataURL(vaultPath: expandedPath).path

        let hasDatabase = fileManager.fileExists(atPath: dbPath)
        let hasChunks = fileManager.fileExists(atPath: chunksPath)
        let hasSQLiteWAL = fileManager.fileExists(atPath: sqliteWALPath)
        let hasSQLiteSHM = fileManager.fileExists(atPath: sqliteSHMPath)
        let hasCaptureWAL = fileManager.fileExists(atPath: captureWALPath)
        let hasMetadata = fileManager.fileExists(atPath: metadataPath)

        if hasDatabase && hasChunks {
            return .complete
        }

        if hasDatabase || hasChunks || hasSQLiteWAL || hasSQLiteSHM || hasCaptureWAL || hasMetadata {
            return .partial
        }

        return .none
    }

    private static func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

enum DatabaseIdentityStore {
    static func ensureIdentity(
        for db: OpaquePointer,
        databasePath: String,
        vaultPath: String,
        appSupportRootPath: String
    ) throws -> DatabaseIdentity {
        try createTableIfNeeded(db: db)

        let existingVaultMetadata = try loadVaultMetadata(vaultPath: vaultPath)
        let existingLibraryManifest = try loadManifest(storageRootPath: appSupportRootPath)

        if let existing = try currentIdentity(for: db) {
            try syncMetadataIfNeeded(
                identity: existing,
                databasePath: databasePath,
                vaultPath: vaultPath,
                appSupportRootPath: appSupportRootPath,
                currentVaultMetadata: existingVaultMetadata,
                currentLibraryManifest: existingLibraryManifest
            )
            return existing
        }

        let libraryID = existingVaultMetadata?.libraryID
            ?? existingLibraryManifest?.libraryID
            ?? makeVaultIdentifier(prefix: nil)
        let now = Date()
        let identity = DatabaseIdentity(
            libraryID: libraryID,
            vaultID: existingVaultMetadata?.bootstrapPending == true
                ? (existingVaultMetadata?.vaultID ?? makeVaultIdentifier(prefix: nil))
                : makeVaultIdentifier(prefix: nil),
            generationID: makeVaultIdentifier(prefix: nil),
            createdAt: now,
            updatedAt: now
        )
        try write(identity: identity, db: db)
        try syncMetadataIfNeeded(
            identity: identity,
            databasePath: databasePath,
            vaultPath: vaultPath,
            appSupportRootPath: appSupportRootPath,
            currentVaultMetadata: existingVaultMetadata,
            currentLibraryManifest: existingLibraryManifest
        )
        return identity
    }

    static func currentIdentity(for db: OpaquePointer) throws -> DatabaseIdentity? {
        guard try tableExists(db: db) else {
            return nil
        }

        let sql = """
            SELECT library_id, shard_id, generation_id, created_at, updated_at
            FROM \(databaseIdentityTableName)
            WHERE singleton_id = \(databaseIdentitySingletonID)
            LIMIT 1;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let libraryID = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let vaultID = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        let generationID = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        let createdAtMs = sqlite3_column_int64(statement, 3)
        let updatedAtMs = sqlite3_column_int64(statement, 4)

        return DatabaseIdentity(
            libraryID: libraryID,
            vaultID: vaultID,
            generationID: generationID,
            createdAt: timestampToDate(createdAtMs),
            updatedAt: timestampToDate(updatedAtMs)
        )
    }

    static func readIdentity(
        at path: String,
        keyData: Data? = nil
    ) throws -> DatabaseIdentity? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let fileState = DatabaseManager.databaseFileEncryptionState(at: expandedPath)

        guard fileState != .missing, fileState != .empty else {
            return nil
        }

        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close_v2(db)
            }
        }

        guard sqlite3_open_v2(expandedPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            throw DatabaseError.connectionFailed(
                underlying: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open database"
            )
        }

        if fileState.isEncrypted {
            guard let keyData else {
                throw DatabaseError.connectionFailed(
                    underlying: "Missing encryption key for encrypted database identity read"
                )
            }
            try DatabaseManager.applyRetraceSQLCipherSettings(keyData, to: db)
        }

        return try currentIdentity(for: db)
    }

    @discardableResult
    static func rollGeneration(
        at path: String,
        keychainAccount: String? = nil,
        storageRootPath: String? = nil,
        appSupportRootPath: String? = nil
    ) throws -> DatabaseIdentity {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let expandedVaultPath = NSString(
            string: storageRootPath ?? (expandedPath as NSString).deletingLastPathComponent
        ).expandingTildeInPath
        let expandedAppSupportRootPath = NSString(
            string: appSupportRootPath ?? AppPaths.expandedAppSupportRoot
        ).expandingTildeInPath

        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close_v2(db)
            }
        }

        guard sqlite3_open_v2(expandedPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            throw DatabaseError.connectionFailed(
                underlying: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open database for identity rollover"
            )
        }

        let fileState = DatabaseManager.databaseFileEncryptionState(at: expandedPath)
        if fileState.isEncrypted {
            let resolution = try DatabaseManager.resolveDatabaseConnection(
                at: expandedPath,
                preferredEncrypted: true,
                encryptedKeyAccounts: [keychainAccount ?? AppPaths.keychainAccount]
            )
            try DatabaseManager.applyDatabaseConnectionResolution(resolution, to: db)
        }

        let current = try ensureIdentity(
            for: db,
            databasePath: expandedPath,
            vaultPath: expandedVaultPath,
            appSupportRootPath: expandedAppSupportRootPath
        )
        let next = DatabaseIdentity(
            libraryID: current.libraryID,
            vaultID: current.vaultID,
            generationID: makeVaultIdentifier(prefix: nil),
            createdAt: current.createdAt,
            updatedAt: Date()
        )
        try write(identity: next, db: db)
        try syncMetadataIfNeeded(
            identity: next,
            databasePath: expandedPath,
            vaultPath: expandedVaultPath,
            appSupportRootPath: expandedAppSupportRootPath,
            currentVaultMetadata: loadVaultMetadata(vaultPath: expandedVaultPath),
            currentLibraryManifest: loadManifest(storageRootPath: expandedAppSupportRootPath)
        )
        return next
    }

    static func manifestURL(storageRootPath: String) -> URL {
        let expandedRoot = NSString(string: storageRootPath).expandingTildeInPath
        return URL(fileURLWithPath: expandedRoot, isDirectory: true)
            .appendingPathComponent(libraryManifestFileName, isDirectory: false)
    }

    static func loadManifest(storageRootPath: String) throws -> DatabaseLibraryManifest? {
        let url = manifestURL(storageRootPath: storageRootPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        return try decoder.decode(DatabaseLibraryManifest.self, from: data)
    }

    static func vaultMetadataURL(vaultPath: String) -> URL {
        let expandedVaultPath = NSString(string: vaultPath).expandingTildeInPath
        return URL(fileURLWithPath: expandedVaultPath, isDirectory: true)
            .appendingPathComponent(vaultMetadataFileName, isDirectory: false)
    }

    static func loadVaultMetadata(vaultPath: String) throws -> RetraceVaultMetadata? {
        let url = vaultMetadataURL(vaultPath: vaultPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        return try decoder.decode(RetraceVaultMetadata.self, from: data)
    }

    static func persistVaultMetadata(
        _ metadata: RetraceVaultMetadata,
        vaultPath: String
    ) throws {
        let url = vaultMetadataURL(vaultPath: vaultPath)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    static func persistManifest(
        _ manifest: DatabaseLibraryManifest,
        storageRootPath: String
    ) throws {
        let url = manifestURL(storageRootPath: storageRootPath)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static func createTableIfNeeded(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS \(databaseIdentityTableName) (
                singleton_id    INTEGER PRIMARY KEY CHECK (singleton_id = 1),
                library_id      TEXT NOT NULL,
                shard_id        TEXT NOT NULL,
                generation_id   TEXT NOT NULL,
                created_at      INTEGER NOT NULL,
                updated_at      INTEGER NOT NULL
            );
            """
        try execute(sql: sql, db: db)
    }

    private static func tableExists(db: OpaquePointer) throws -> Bool {
        let sql = """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'table' AND name = '\(databaseIdentityTableName)';
            """
        return try queryInt(sql: sql, db: db) > 0
    }

    private static func write(identity: DatabaseIdentity, db: OpaquePointer) throws {
        let sql = """
            INSERT INTO \(databaseIdentityTableName) (
                singleton_id,
                library_id,
                shard_id,
                generation_id,
                created_at,
                updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(singleton_id) DO UPDATE SET
                library_id = excluded.library_id,
                shard_id = excluded.shard_id,
                generation_id = excluded.generation_id,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int(statement, 1, Int32(databaseIdentitySingletonID))
        sqlite3_bind_text(statement, 2, identity.libraryID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, identity.vaultID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, identity.generationID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 5, dateToTimestamp(identity.createdAt))
        sqlite3_bind_int64(statement, 6, dateToTimestamp(identity.updatedAt))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    private static func syncMetadataIfNeeded(
        identity: DatabaseIdentity,
        databasePath: String,
        vaultPath: String,
        appSupportRootPath: String,
        currentVaultMetadata: RetraceVaultMetadata?,
        currentLibraryManifest: DatabaseLibraryManifest?
    ) throws {
        guard usesMetadata(databasePath: databasePath) else {
            return
        }

        let desiredManifest = DatabaseLibraryManifest(
            formatVersion: libraryManifestFormatVersion,
            libraryID: identity.libraryID,
            updatedAt: Date()
        )
        if currentLibraryManifest?.libraryID != desiredManifest.libraryID {
            try persistManifest(desiredManifest, storageRootPath: appSupportRootPath)
        } else if currentLibraryManifest == nil {
            try persistManifest(desiredManifest, storageRootPath: appSupportRootPath)
        }

        let desiredVaultMetadata = RetraceVaultMetadata(
            vaultID: identity.vaultID,
            libraryID: identity.libraryID,
            bootstrapPending: false,
            createdAt: currentVaultMetadata?.createdAt ?? identity.createdAt,
            updatedAt: Date()
        )
        if currentVaultMetadata?.vaultID != desiredVaultMetadata.vaultID
            || currentVaultMetadata?.libraryID != desiredVaultMetadata.libraryID {
            try persistVaultMetadata(desiredVaultMetadata, vaultPath: vaultPath)
        } else if currentVaultMetadata == nil {
            try persistVaultMetadata(desiredVaultMetadata, vaultPath: vaultPath)
        }
    }

    private static func execute(sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(errorMessage) }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }
    }

    private static func queryInt(sql: String, db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: "No rows")
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    private static func usesMetadata(databasePath: String) -> Bool {
        !(databasePath == ":memory:" || databasePath.contains("mode=memory"))
    }

    private static func makeIdentifier() -> String {
        makeVaultIdentifier(prefix: nil)
    }
}

private func makeVaultIdentifier(prefix: String?) -> String {
    let random = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    guard let prefix, !prefix.isEmpty else {
        return UUID().uuidString.lowercased()
    }

    let normalizedPrefix = prefix.lowercased()
    let suffixStart = min(normalizedPrefix.count, random.count)
    let suffix = String(random.dropFirst(suffixStart))
    return normalizedPrefix + suffix
}

private func dateToTimestamp(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000)
}

private func timestampToDate(_ timestamp: Int64) -> Date {
    Date(timeIntervalSince1970: Double(timestamp) / 1000)
}
