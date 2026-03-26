import Foundation

/// Centralized app paths and identifiers
/// Single source of truth for all path constants used across the app
public enum AppPaths {
    public static let settingsSuiteName = "io.retrace.app"
    public static let customRetraceVaultLocationDefaultsKey = "customRetraceDBLocation"
    public static let defaultRetraceVaultLocationDefaultsKey = "defaultRetraceVaultLocation"
    public static let vaultsDirectoryName = "Vaults"
    public static let vaultFolderPrefix = "vault-"
    private static let pendingDefaultVaultFolderName = "vault-pending"

    // MARK: - Base Paths

    /// Fixed app-home path for app-global state (logs, caches, manifests, models).
    public static let defaultAppSupportRoot = NSString(string: "~/Library/Application Support/Retrace").expandingTildeInPath

    /// Default vault container directory under the fixed app-home path.
    public static let defaultVaultsRoot = "\(defaultAppSupportRoot)/\(vaultsDirectoryName)"

    /// Default root storage path for the active Retrace vault.
    public static var defaultStorageRoot: String {
        resolveDefaultVaultPath()
    }

    /// Fixed app-home path for app-global state.
    public static var appSupportRoot: String {
        defaultAppSupportRoot
    }

    /// Expanded default vault container directory under the fixed app-home path.
    public static var expandedDefaultVaultsRoot: String {
        NSString(string: defaultVaultsRoot).expandingTildeInPath
    }

    /// Expanded fixed app-home path.
    public static var expandedAppSupportRoot: String {
        NSString(string: appSupportRoot).expandingTildeInPath
    }

    /// Default Rewind/MemoryVault storage root path (tilde expanded)
    public static let defaultRewindStorageRoot = NSString(string: "~/Library/Application Support/com.memoryvault.MemoryVault").expandingTildeInPath

    /// Default Rewind database path
    public static let defaultRewindDBPath = "\(defaultRewindStorageRoot)/db-enc.sqlite3"

    /// Active Retrace vault path (respects custom location if set).
    public static var storageRoot: String {
        let defaults = UserDefaults(suiteName: settingsSuiteName) ?? .standard
        if let customLocation = defaults.string(forKey: customRetraceVaultLocationDefaultsKey) {
            return NSString(string: customLocation).expandingTildeInPath
        }
        return resolveDefaultVaultPath()
    }

    /// Expanded active vault path (tilde resolved)
    public static var expandedStorageRoot: String {
        NSString(string: storageRoot).expandingTildeInPath
    }

    // MARK: - Database

    /// Database file path inside the active vault.
    public static var databasePath: String {
        "\(storageRoot)/retrace.db"
    }

    /// Rewind/MemoryVault storage root (respects custom location if set)
    /// `customRewindDBLocation` stores a folder path. Legacy file-path values are normalized.
    public static var rewindStorageRoot: String {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        if let customLocation = defaults.string(forKey: "customRewindDBLocation") {
            let normalized = NSString(string: customLocation).expandingTildeInPath
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory), !isDirectory.boolValue {
                // Backward compatibility for older file-based setting values.
                return (normalized as NSString).deletingLastPathComponent
            }

            let lastComponent = (normalized as NSString).lastPathComponent.lowercased()
            if lastComponent.hasSuffix(".sqlite3") || lastComponent.hasSuffix(".db") {
                // Handle legacy values that point to a DB file that is no longer present.
                return (normalized as NSString).deletingLastPathComponent
            }
            return normalized
        }
        return defaultRewindStorageRoot
    }

    /// Expanded Rewind storage root path (tilde resolved)
    public static var expandedRewindStorageRoot: String {
        NSString(string: rewindStorageRoot).expandingTildeInPath
    }

    /// Rewind database path (db-enc.sqlite3 under rewindStorageRoot)
    public static var rewindDBPath: String {
        return "\(rewindStorageRoot)/db-enc.sqlite3"
    }

    /// Rewind chunks path (respects custom location if set)
    public static var rewindChunksPath: String {
        "\(rewindStorageRoot)/chunks"
    }

    /// Rewind rewind.db path (unencrypted database used for ID offset)
    public static var rewindUnencryptedDBPath: String {
        "\(rewindStorageRoot)/rewind.db"
    }

    // MARK: - Vault Directories

    /// Video segments storage path
    public static var segmentsPath: String {
        "\(storageRoot)/segments"
    }

    // MARK: - App-Home Directories

    /// Temp files path for app-global scratch data.
    public static var tempPath: String {
        "\(appSupportRoot)/temp"
    }

    /// Models directory path for app-global downloadable models.
    public static var modelsPath: String {
        "\(appSupportRoot)/models"
    }

    /// Logs directory path for app-global diagnostic logs.
    public static var logsPath: String {
        "\(appSupportRoot)/logs"
    }

    // MARK: - Keychain

    /// Keychain service identifier for database encryption
    public static let keychainService = "com.retrace.database"

    /// Keychain account for SQLCipher key
    public static let keychainAccount = "sqlcipher-key"

    // MARK: - Logging

    /// Log subsystem identifier
    public static let logSubsystem = "io.retrace.app"

    private static func resolveDefaultVaultPath() -> String {
        let defaults = UserDefaults(suiteName: settingsSuiteName) ?? .standard
        if let stored = defaults.string(forKey: defaultRetraceVaultLocationDefaultsKey) {
            let expandedStored = NSString(string: stored).expandingTildeInPath
            let storedVaultsRoot = (expandedStored as NSString).lastPathComponent == vaultsDirectoryName
                ? expandedStored
                : (expandedStored as NSString).appendingPathComponent(vaultsDirectoryName)
            if let discovered = firstCompleteVaultPath(in: storedVaultsRoot) {
                return discovered
            }
            return expandedStored
        }

        if let discovered = firstCompleteVaultPath(in: defaultVaultsRoot) {
            return discovered
        }

        let legacyRoot = defaultAppSupportRoot
        if hasCompleteLegacyAssets(in: legacyRoot) {
            return legacyRoot
        }

        return (defaultVaultsRoot as NSString).appendingPathComponent(pendingDefaultVaultFolderName)
    }

    private static func firstCompleteVaultPath(in root: String) -> String? {
        let expandedRoot = NSString(string: root).expandingTildeInPath
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: expandedRoot, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return contents
            .filter { $0.lastPathComponent.hasPrefix(vaultFolderPrefix) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first(where: { vaultURL in
                let dbPath = vaultURL.appendingPathComponent("retrace.db", isDirectory: false).path
                let chunksPath = vaultURL.appendingPathComponent("chunks", isDirectory: true).path
                return fileManager.fileExists(atPath: dbPath) && fileManager.fileExists(atPath: chunksPath)
            })?
            .path
    }

    private static func hasCompleteLegacyAssets(in root: String) -> Bool {
        let expandedRoot = NSString(string: root).expandingTildeInPath
        let dbPath = (expandedRoot as NSString).appendingPathComponent("retrace.db")
        let chunksPath = (expandedRoot as NSString).appendingPathComponent("chunks")
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: dbPath) && fileManager.fileExists(atPath: chunksPath)
    }
}
