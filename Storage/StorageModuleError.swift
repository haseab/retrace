import Foundation
import Shared

/// Storage-local errors not covered by Shared StorageError.
public enum StorageModuleError: RetraceError {
    case encodingFailed(underlying: String)

    public var errorCode: String {
        switch self {
        case .encodingFailed:
            return "STORAGE_LOCAL_001"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let underlying):
            return "Video encoding failed: \(underlying)"
        }
    }
}

