import Foundation

/// Centralized app paths and identifiers
/// Single source of truth for all path constants used across the app
public enum AppPaths {

    /// Only the persistent bundled development identity uses the separate namespace.
    public static let isDevelopment = Bundle.main.bundleIdentifier == "io.retrace.app.dev"
    public static let settingsSuiteName = isDevelopment ? "io.retrace.app.dev" : "io.retrace.app"
    public static let applicationSupportName = isDevelopment ? "Retrace Dev" : "Retrace"
    public static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return isDevelopment ? base.appendingPathComponent(settingsSuiteName, isDirectory: true) : base
    }()

    // MARK: - Base Paths

    /// Default root storage path for all app data (tilde expanded)
    public static let defaultStorageRoot = NSString(string: "~/Library/Application Support/\(applicationSupportName)").expandingTildeInPath

    /// Default Rewind/MemoryVault storage root path (tilde expanded)
    public static let defaultRewindStorageRoot = NSString(string: "~/Library/Application Support/com.memoryvault.MemoryVault").expandingTildeInPath

    /// Default Rewind database path
    public static let defaultRewindDBPath = "\(defaultRewindStorageRoot)/db-enc.sqlite3"

    /// Root storage path for all app data (respects custom location if set)
    public static var storageRoot: String {
        let defaults = UserDefaults(suiteName: AppPaths.settingsSuiteName) ?? .standard
        return defaults.string(forKey: "customRetraceDBLocation") ?? defaultStorageRoot
    }

    /// Expanded storage root path (tilde resolved)
    public static var expandedStorageRoot: String {
        NSString(string: storageRoot).expandingTildeInPath
    }

    // MARK: - Database

    /// Database file path (respects custom location if set)
    public static var databasePath: String {
        "\(storageRoot)/retrace.db"
    }

    /// Rewind/MemoryVault storage root (respects custom location if set)
    /// `customRewindDBLocation` stores a folder path. Legacy file-path values are normalized.
    public static var rewindStorageRoot: String {
        let defaults = UserDefaults(suiteName: AppPaths.settingsSuiteName) ?? .standard
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

    // MARK: - Storage Directories

    /// Video segments storage path
    public static let segmentsPath = "\(storageRoot)/segments"

    /// Temp files path
    public static let tempPath = "\(storageRoot)/temp"

    /// Models directory path
    public static let modelsPath = "\(storageRoot)/models"

    // MARK: - Keychain

    /// Keychain service identifier for database encryption
    public static let keychainService = isDevelopment ? "com.retrace.database.dev" : "com.retrace.database"

    /// Keychain account for SQLCipher key
    public static let keychainAccount = "sqlcipher-key"

    // MARK: - Logging

    /// Log subsystem identifier
    public static let logSubsystem = settingsSuiteName
}
