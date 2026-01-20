import Foundation
import SQLite3
import Shared
import Accelerate

// SQLITE_TRANSIENT is a C macro that tells SQLite to make its own copy of the data
// Swift doesn't bridge C macros automatically, so we define it here
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-based vector storage with cosine similarity search
/// Owner: SEARCH agent
public actor SQLiteVectorStore: VectorStoreProtocol {

    // MARK: - Properties

    private var db: OpaquePointer?
    private let databasePath: String
    private let modelVersion: String
    private var _vectorCount = 0

    // MARK: - Initialization

    public init(databasePath: String, modelVersion: String = "nomic-embed-v1.5") {
        self.databasePath = databasePath
        self.modelVersion = modelVersion
    }

    deinit {
        // Synchronous cleanup of SQLite resources
        // Note: Cannot use async/await in deinit
        if let database = db {
            sqlite3_close(database)
        }
    }

    // MARK: - VectorStoreProtocol

    public var vectorCount: Int {
        _vectorCount
    }

    public func initialize() async throws {
        let expandedPath = NSString(string: databasePath).expandingTildeInPath

        guard sqlite3_open(expandedPath, &db) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw DatabaseError.connectionFailed(underlying: errorMsg)
        }

        // Update vector count
        _vectorCount = try await getVectorCountFromDB()

        Log.info("Vector store initialized with \(_vectorCount) vectors", category: .search)
    }

    public func addVector(frameID: FrameID, vector: [Float]) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Vector store not initialized")
        }

        // Serialize vector to BLOB
        let vectorBlob = vectorToBlob(vector)

        let sql = """
            INSERT OR REPLACE INTO embeddings (frame_id, vector, model_version)
            VALUES (?, ?, ?);
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        // Bind parameters
        sqlite3_bind_text(statement, 1, frameID.stringValue, -1, SQLITE_TRANSIENT)
        vectorBlob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(statement, 3, modelVersion, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        _vectorCount = try await getVectorCountFromDB()
        Log.debug("Added vector for frame \(frameID.stringValue.prefix(8))", category: .search)
    }

    public func removeVector(frameID: FrameID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Vector store not initialized")
        }

        let sql = "DELETE FROM embeddings WHERE frame_id = ?;"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, frameID.stringValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        _vectorCount = try await getVectorCountFromDB()
        Log.debug("Removed vector for frame \(frameID.stringValue.prefix(8))", category: .search)
    }

    public func findNearest(
        to queryVector: [Float],
        limit: Int
    ) async throws -> [(frameID: FrameID, similarity: Float)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Vector store not initialized")
        }

        // For now, we use a simple linear scan with cosine similarity
        // For production at scale, consider:
        // - sqlite-vss extension (https://github.com/asg017/sqlite-vss)
        // - Approximate Nearest Neighbor (ANN) indexes
        // - Dedicated vector DB (Qdrant, Milvus, Pinecone)

        let sql = "SELECT frame_id, vector FROM embeddings WHERE model_version = ?;"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, modelVersion, -1, SQLITE_TRANSIENT)

        var results: [(frameID: FrameID, similarity: Float)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            // Get frame_id
            guard let frameIDText = sqlite3_column_text(statement, 0) else { continue }
            guard let frameID = FrameID(string: String(cString: frameIDText)) else { continue }

            // Get vector blob
            guard let vectorBytes = sqlite3_column_blob(statement, 1) else { continue }
            let vectorSize = Int(sqlite3_column_bytes(statement, 1))

            let vector = blobToVector(Data(bytes: vectorBytes, count: vectorSize))

            // Calculate cosine similarity
            let similarity = cosineSimilarity(queryVector, vector)

            results.append((frameID: frameID, similarity: similarity))
        }

        // Sort by similarity (descending) and take top N
        let topResults = results
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)

        return Array(topResults)
    }

    public func clear() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Vector store not initialized")
        }

        let sql = "DELETE FROM embeddings;"

        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(errorMessage) }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }

        _vectorCount = 0
        Log.info("Cleared all vectors from store", category: .search)
    }

    // MARK: - Private Helpers

    private func close() async throws {
        guard let db = db else { return }

        guard sqlite3_close(db) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.connectionFailed(underlying: "Failed to close vector store: \(errorMsg)")
        }

        self.db = nil
    }

    private func getVectorCountFromDB() async throws -> Int {
        guard let db = db else { return 0 }

        let sql = "SELECT COUNT(*) FROM embeddings WHERE model_version = ?;"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }

        sqlite3_bind_text(statement, 1, modelVersion, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    /// Convert vector to binary blob for storage
    private func vectorToBlob(_ vector: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(vector.count * MemoryLayout<Float>.size)

        vector.withUnsafeBytes { bytes in
            data.append(contentsOf: bytes)
        }

        return data
    }

    /// Convert binary blob back to vector
    private func blobToVector(_ blob: Data) -> [Float] {
        let floatCount = blob.count / MemoryLayout<Float>.size
        var vector = [Float](repeating: 0, count: floatCount)

        blob.withUnsafeBytes { bytes in
            let floatPtr = bytes.bindMemory(to: Float.self)
            for i in 0..<floatCount {
                vector[i] = floatPtr[i]
            }
        }

        return vector
    }

    /// Calculate cosine similarity between two vectors using Accelerate
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        // Use Accelerate for SIMD performance
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))

        normA = sqrt(normA)
        normB = sqrt(normB)

        guard normA > 0, normB > 0 else { return 0 }

        return dotProduct / (normA * normB)
    }
}
