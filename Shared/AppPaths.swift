import Foundation

/// Centralized app paths and identifiers
/// Single source of truth for all path constants used across the app
public enum AppPaths {

    // MARK: - Base Paths

    /// Default root storage path for all app data (tilde expanded)
    public static let defaultStorageRoot = NSString(string: "~/Library/Application Support/Retrace").expandingTildeInPath

    /// Default Rewind/MemoryVault storage root path (tilde expanded)
    public static let defaultRewindStorageRoot = NSString(string: "~/Library/Application Support/com.memoryvault.MemoryVault").expandingTildeInPath

    /// Default Rewind database path
    public static let defaultRewindDBPath = "\(defaultRewindStorageRoot)/db-enc.sqlite3"

    /// Root storage path for all app data (respects custom location if set)
    public static var storageRoot: String {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
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
    /// Derived from customRewindDBLocation by getting its parent directory
    public static var rewindStorageRoot: String {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        if let customDBPath = defaults.string(forKey: "customRewindDBLocation") {
            // Custom DB path is like "/path/to/db-enc.sqlite3", storage root is the parent directory
            return (customDBPath as NSString).deletingLastPathComponent
        }
        return defaultRewindStorageRoot
    }

    /// Expanded Rewind storage root path (tilde resolved)
    public static var expandedRewindStorageRoot: String {
        NSString(string: rewindStorageRoot).expandingTildeInPath
    }

    /// Rewind database path (respects custom location if set)
    public static var rewindDBPath: String {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        if let customPath = defaults.string(forKey: "customRewindDBLocation") {
            return customPath
        }
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
    public static let keychainService = "com.retrace.database"

    /// Keychain account for SQLCipher key
    public static let keychainAccount = "sqlcipher-key"

    // MARK: - Logging

    /// Log subsystem identifier
    public static let logSubsystem = "io.retrace.app"
}
