import Foundation
import Shared
import Database
import Storage

/// Data source for fetching data from native Retrace storage
/// Wraps DatabaseManager and StorageManager to conform to DataSourceProtocol
public actor RetraceDataSource: DataSourceProtocol {

    // MARK: - DataSourceProtocol Properties

    public let source: FrameSource = .native

    public var isConnected: Bool {
        _isConnected
    }

    /// Native Retrace data has no cutoff - it's the current/primary source
    public var cutoffDate: Date? {
        nil
    }

    // MARK: - Private Properties

    private let database: DatabaseManager
    private let storage: StorageManager
    private var _isConnected = false

    // MARK: - Initialization

    public init(database: DatabaseManager, storage: StorageManager) {
        self.database = database
        self.storage = storage
    }

    // MARK: - DataSourceProtocol Methods

    public func connect() async throws {
        // Database and storage are already initialized by ServiceContainer
        // Just mark as connected
        _isConnected = true
        Log.info("RetraceDataSource connected", category: .app)
    }

    public func disconnect() async {
        _isConnected = false
        Log.info("RetraceDataSource disconnected", category: .app)
    }

    public func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference] {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        return try await database.getFrames(from: startDate, to: endDate, limit: limit)
    }

    public func getFrameImage(segmentID: SegmentID, timestamp: Date) async throws -> Data {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        return try await storage.readFrame(segmentID: segmentID, timestamp: timestamp)
    }

    public func getFrameVideoInfo(segmentID: SegmentID, timestamp: Date) async throws -> FrameVideoInfo? {
        // Retrace stores individual JPEG files, not video
        return nil
    }
}
