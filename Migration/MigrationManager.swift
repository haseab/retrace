import Foundation
import Shared

/// Coordinates data migration from third-party screen recording applications
/// Manages multiple importers and provides a unified interface for the UI
public actor MigrationManager {

    // MARK: - Properties

    private var importers: [FrameSource: any MigrationProtocol] = [:]
    private let stateStore: MigrationStateStore
    private let database: any DatabaseProtocol
    private let processing: any ProcessingProtocol

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        processing: any ProcessingProtocol,
        stateDirectory: URL? = nil
    ) {
        self.database = database
        self.processing = processing

        let stateDir = stateDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Retrace/Migration")

        self.stateStore = MigrationStateStore(directory: stateDir)
    }

    // MARK: - Public Methods

    /// Register an importer for a specific source
    public func registerImporter(_ importer: any MigrationProtocol) async {
        let source = await importer.source
        importers[source] = importer
    }

    /// Get all registered importers
    public func getImporters() -> [FrameSource: any MigrationProtocol] {
        importers
    }

    /// Check which sources have data available for import
    public func getAvailableSources() async -> [FrameSource] {
        var available: [FrameSource] = []
        for (source, importer) in importers {
            if await importer.isDataAvailable() {
                available.append(source)
            }
        }
        return available
    }

    /// Scan a specific source and return import statistics
    public func scan(source: FrameSource) async throws -> MigrationScanResult {
        guard let importer = importers[source] else {
            throw MigrationError.sourceNotFound(path: source.rawValue)
        }
        return try await importer.scan()
    }

    /// Start import from a specific source
    public func startImport(
        source: FrameSource,
        delegate: MigrationDelegate?
    ) async throws {
        guard let importer = importers[source] else {
            throw MigrationError.sourceNotFound(path: source.rawValue)
        }
        try await importer.startImport(delegate: delegate)
    }

    /// Pause import from a specific source
    public func pauseImport(source: FrameSource) async {
        guard let importer = importers[source] else { return }
        await importer.pauseImport()
    }

    /// Cancel import from a specific source
    public func cancelImport(source: FrameSource) async {
        guard let importer = importers[source] else { return }
        await importer.cancelImport()
    }

    /// Get progress for a specific source
    public func getProgress(source: FrameSource) async -> MigrationProgress? {
        guard let importer = importers[source] else { return nil }
        return await importer.progress
    }

    /// Check if any import is in progress
    public func isAnyImportInProgress() async -> Bool {
        for (_, importer) in importers {
            if await importer.isImporting {
                return true
            }
        }
        return false
    }

    /// Get state for a specific source (for UI persistence)
    public func getState(source: FrameSource) async -> MigrationState? {
        guard let importer = importers[source] else { return nil }
        return await importer.getState()
    }

    /// Initialize default importers (call during app setup)
    public func setupDefaultImporters() async {
        // Register Rewind importer
        let rewindImporter = RewindImporter(
            database: database,
            processing: processing,
            stateStore: stateStore
        )
        await registerImporter(rewindImporter)

        // Future: Register other importers here
        // let screenMemoryImporter = ScreenMemoryImporter(...)
        // await registerImporter(screenMemoryImporter)
    }
}

// MARK: - Migration State Store

/// Handles persistence of migration state for resumability
public actor MigrationStateStore {

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Save migration state to disk
    public func saveState(_ state: MigrationState) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let filename = "migration_\(state.source.rawValue).json"
        let fileURL = directory.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)

        Log.debug("Saved migration state for \(state.source.rawValue)", category: .app)
    }

    /// Load migration state from disk
    public func loadState(for source: FrameSource) throws -> MigrationState? {
        let filename = "migration_\(source.rawValue).json"
        let fileURL = directory.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let state = try decoder.decode(MigrationState.self, from: data)

        Log.debug("Loaded migration state for \(source.rawValue)", category: .app)
        return state
    }

    /// Delete migration state (after successful completion or manual clear)
    public func deleteState(for source: FrameSource) throws {
        let filename = "migration_\(source.rawValue).json"
        let fileURL = directory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
            Log.debug("Deleted migration state for \(source.rawValue)", category: .app)
        }
    }

    /// Check if there's a resumable state for a source
    public func hasResumableState(for source: FrameSource) -> Bool {
        let filename = "migration_\(source.rawValue).json"
        let fileURL = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}
