import Foundation
import Shared

/// Write intent before deleting the database row. A failed file removal can then
/// be retried after restart without losing track of the orphaned file.
struct RetentionDeletionJournal: Sendable {
    let url: URL

    func process(
        candidates: [Int64],
        deleteDatabase: (Int64) async throws -> Bool,
        deleteFile: (Int64) async throws -> Int64
    ) async throws -> (deleted: Int, bytes: Int64) {
        let previous: [Int64]
        do { previous = try JSONDecoder().decode([Int64].self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { previous = [] }
        var pending = Set(previous).union(candidates)
        if pending.isEmpty { return (0, 0) }
        try save(pending)
        var deleted = 0
        var bytes: Int64 = 0
        for id in pending.sorted() {
            do {
                // A referenced or active video must not be deleted, even on retry.
                guard try await deleteDatabase(id) else {
                    pending.remove(id)
                    try save(pending)
                    continue
                }
                let reclaimed = try await deleteFile(id)
                pending.remove(id)
                try save(pending)
                deleted += 1
                bytes += reclaimed
            } catch {
                Log.warning("[Retention] Deferred video deletion for retry id=\(id) errorCode=\((error as NSError).code)", category: .app)
            }
        }
        return (deleted, bytes)
    }

    private func save(_ pending: Set<Int64>) throws {
        try JSONEncoder().encode(pending.sorted()).write(to: url, options: .atomic)
    }
}
