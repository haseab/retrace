import Foundation

enum ProcessUsageLogCleanup {
    /// System Monitor history lives in the bounded tally file. The old raw sample
    /// log is unused and can be arbitrarily large, so unlink it without reading it.
    static func removeLegacyLog(storageRoot: URL) throws {
        let file = storageRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("cpu_process_usage.jsonl", isDirectory: false)
        do {
            try FileManager.default.removeItem(at: file)
        } catch CocoaError.fileNoSuchFile {
            // Expected on fresh installs and subsequent launches.
        }
    }
}
