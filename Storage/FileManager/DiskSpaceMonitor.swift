import Foundation
import Shared

/// Lightweight disk space querying.
struct DiskSpaceMonitor {
    static func availableBytes(at url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let cap = values.volumeAvailableCapacityForImportantUsage {
                return Int64(cap)
            }
            let fs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
            if let free = fs[.systemFreeSize] as? NSNumber {
                return free.int64Value
            }
            return 0
        } catch {
            throw StorageError.fileReadFailed(path: url.path, underlying: error.localizedDescription)
        }
    }
}

