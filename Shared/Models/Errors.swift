import Foundation

// MARK: - Base Error Protocol

/// Base protocol for all Retrace errors
public protocol RetraceError: LocalizedError, Sendable {
    var errorCode: String { get }
}

// MARK: - Capture Errors

public enum CaptureError: RetraceError {
    case permissionDenied
    case accessibilityPermissionDenied
    case noDisplaysAvailable
    case captureSessionFailed(underlying: String)
    case encodingFailed(underlying: String)
    case invalidFrame

    public var errorCode: String {
        switch self {
        case .permissionDenied: return "CAPTURE_001"
        case .noDisplaysAvailable: return "CAPTURE_002"
        case .captureSessionFailed: return "CAPTURE_003"
        case .encodingFailed: return "CAPTURE_004"
        case .invalidFrame: return "CAPTURE_005"
        case .accessibilityPermissionDenied: return "CAPTURE_006"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission denied. Please enable in System Settings > Privacy & Security > Screen Recording."
        case .accessibilityPermissionDenied:
            return "Accessibility permission denied. Retrace needs accessibility access to detect which display you're working on. Please enable in System Settings > Privacy & Security > Accessibility."
        case .noDisplaysAvailable:
            return "No displays available for capture."
        case .captureSessionFailed(let underlying):
            return "Capture session failed: \(underlying)"
        case .encodingFailed(let underlying):
            return "Video encoding failed: \(underlying)"
        case .invalidFrame:
            return "Received invalid frame data."
        }
    }
}

// MARK: - Storage Errors

public enum StorageError: RetraceError {
    case directoryCreationFailed(path: String)
    case fileWriteFailed(path: String, underlying: String)
    case fileReadFailed(path: String, underlying: String)
    case fileNotFound(path: String)
    case encryptionFailed(underlying: String)
    case decryptionFailed(underlying: String)
    case keyNotFound
    case insufficientDiskSpace
    case segmentCorrupted(segmentID: String)
    // External drive errors
    case driveDisconnected(path: String)
    case driveSlowIO(latencyMs: Double)
    case walCheckpointFailed(retries: Int)

    public var errorCode: String {
        switch self {
        case .directoryCreationFailed: return "STORAGE_001"
        case .fileWriteFailed: return "STORAGE_002"
        case .fileReadFailed: return "STORAGE_003"
        case .fileNotFound: return "STORAGE_004"
        case .encryptionFailed: return "STORAGE_005"
        case .decryptionFailed: return "STORAGE_006"
        case .keyNotFound: return "STORAGE_007"
        case .insufficientDiskSpace: return "STORAGE_008"
        case .segmentCorrupted: return "STORAGE_009"
        case .driveDisconnected: return "STORAGE_010"
        case .driveSlowIO: return "STORAGE_011"
        case .walCheckpointFailed: return "STORAGE_012"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let path):
            return "Failed to create directory: \(path)"
        case .fileWriteFailed(let path, let underlying):
            return "Failed to write file '\(path)': \(underlying)"
        case .fileReadFailed(let path, let underlying):
            return "Failed to read file '\(path)': \(underlying)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .encryptionFailed(let underlying):
            return "Encryption failed: \(underlying)"
        case .decryptionFailed(let underlying):
            return "Decryption failed: \(underlying)"
        case .keyNotFound:
            return "Encryption key not found in keychain."
        case .insufficientDiskSpace:
            return "Insufficient disk space for storage."
        case .segmentCorrupted(let segmentID):
            return "Video segment corrupted: \(segmentID)"
        case .driveDisconnected(let path):
            return "Storage drive disconnected: \(path)"
        case .driveSlowIO(let latencyMs):
            return "Storage I/O too slow: \(Int(latencyMs))ms write latency"
        case .walCheckpointFailed(let retries):
            return "Database checkpoint failed after \(retries) retries"
        }
    }
}

// MARK: - Database Errors

public enum DatabaseError: RetraceError {
    case connectionFailed(underlying: String)
    case queryFailed(query: String, underlying: String)
    case queryPreparationFailed(String)
    case queryExecutionFailed(String)
    case migrationFailed(version: Int, underlying: String)
    case transactionFailed(underlying: String)
    case recordNotFound(table: String, id: String)
    case constraintViolation(underlying: String)

    public var errorCode: String {
        switch self {
        case .connectionFailed: return "DB_001"
        case .queryFailed: return "DB_002"
        case .queryPreparationFailed: return "DB_003"
        case .queryExecutionFailed: return "DB_004"
        case .migrationFailed: return "DB_005"
        case .transactionFailed: return "DB_006"
        case .recordNotFound: return "DB_007"
        case .constraintViolation: return "DB_008"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let underlying):
            return "Database connection failed: \(underlying)"
        case .queryFailed(let query, let underlying):
            return "Query failed '\(query)': \(underlying)"
        case .queryPreparationFailed(let underlying):
            return "Query preparation failed: \(underlying)"
        case .queryExecutionFailed(let underlying):
            return "Query execution failed: \(underlying)"
        case .migrationFailed(let version, let underlying):
            return "Migration to version \(version) failed: \(underlying)"
        case .transactionFailed(let underlying):
            return "Transaction failed: \(underlying)"
        case .recordNotFound(let table, let id):
            return "Record not found in \(table) with id: \(id)"
        case .constraintViolation(let underlying):
            return "Constraint violation: \(underlying)"
        }
    }
}

// MARK: - Processing Errors

public enum ProcessingError: RetraceError {
    case ocrFailed(underlying: String)
    case accessibilityPermissionDenied
    case accessibilityQueryFailed(underlying: String)
    case imageConversionFailed
    case processingQueueFull
    case invalidVideoPath(path: String)

    public var errorCode: String {
        switch self {
        case .ocrFailed: return "PROC_001"
        case .accessibilityPermissionDenied: return "PROC_002"
        case .accessibilityQueryFailed: return "PROC_003"
        case .imageConversionFailed: return "PROC_004"
        case .processingQueueFull: return "PROC_005"
        case .invalidVideoPath: return "PROC_006"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .ocrFailed(let underlying):
            return "OCR processing failed: \(underlying)"
        case .accessibilityPermissionDenied:
            return "Accessibility permission denied. Please enable in System Settings > Privacy & Security > Accessibility."
        case .accessibilityQueryFailed(let underlying):
            return "Accessibility query failed: \(underlying)"
        case .imageConversionFailed:
            return "Failed to convert image for processing."
        case .processingQueueFull:
            return "Processing queue is full, frame dropped."
        case .invalidVideoPath(let path):
            return "Invalid video path format: \(path)"
        }
    }
}

// MARK: - Transcription Errors

public enum TranscriptionError: Error, Sendable {
    case notImplemented(String)
    case notInitialized
    case modelLoadFailed(String)
    case transcriptionFailed
    case apiError(String)
    case invalidResponse
    case audioFormatError
}

// MARK: - Search Errors

public enum SearchError: RetraceError {
    case invalidQuery(reason: String)
    case indexNotReady
    case embeddingFailed(underlying: String)
    case modelLoadFailed(modelName: String)

    public var errorCode: String {
        switch self {
        case .invalidQuery: return "SEARCH_001"
        case .indexNotReady: return "SEARCH_002"
        case .embeddingFailed: return "SEARCH_003"
        case .modelLoadFailed: return "SEARCH_004"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidQuery(let reason):
            return "Invalid search query: \(reason)"
        case .indexNotReady:
            return "Search index is not ready. Please wait for indexing to complete."
        case .embeddingFailed(let underlying):
            return "Text embedding failed: \(underlying)"
        case .modelLoadFailed(let modelName):
            return "Failed to load ML model: \(modelName)"
        }
    }
}
