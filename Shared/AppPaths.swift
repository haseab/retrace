import Foundation

/// Centralized app paths and identifiers
/// Single source of truth for all path constants used across the app
public enum AppPaths {

    // MARK: - Base Paths

    /// Root storage path for all app data
    public static let storageRoot = "~/Library/Application Support/Retrace"

    /// Expanded storage root path (tilde resolved)
    public static var expandedStorageRoot: String {
        NSString(string: storageRoot).expandingTildeInPath
    }

    // MARK: - Database

    /// Database file path
    public static let databasePath = "\(storageRoot)/retrace.db"

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
