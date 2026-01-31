import Foundation

/// Centralized app paths and identifiers
/// Single source of truth for all path constants used across the app
public enum AppPaths {

    // MARK: - Base Paths

    /// Default root storage path for all app data
    public static let defaultStorageRoot = "~/Library/Application Support/Retrace"

    /// Default Rewind database path
    public static let defaultRewindDBPath = "~/Library/Application Support/com.memoryvault.MemoryVault/db-enc.sqlite3"

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

    /// Rewind database path (respects custom location if set)
    public static var rewindDBPath: String {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        if let customPath = defaults.string(forKey: "customRewindDBLocation") {
            return customPath
        }
        return defaultRewindDBPath
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
