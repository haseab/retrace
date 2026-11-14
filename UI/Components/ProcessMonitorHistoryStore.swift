import Foundation

protocol ProcessMonitorHistoryBucket: Codable, Equatable {
    var startTimestamp: TimeInterval { get }
}

protocol ProcessMonitorHistoryState: Codable, Equatable {
    associatedtype Bucket: ProcessMonitorHistoryBucket
    var buckets: [Bucket] { get set }
}

/// Confined to the sampler actor. Saves bucket replacements, never additive totals, so replay is idempotent.
/// The checkpoint is atomic; sequence numbers make an interrupted journal rotation safe.
final class ProcessMonitorHistoryStore<State: ProcessMonitorHistoryState> {
    private struct Checkpoint: Codable {
        let sequence: UInt64
        let state: State
    }

    private struct Update: Codable {
        let sequence: UInt64
        let metadata: State
        let buckets: [State.Bucket]
        let removed: [TimeInterval]
    }

    let journalURL: URL
    private let checkpointURL: URL
    private let checkpointInterval: TimeInterval
    private let maximumJournalBytes: Int
    private var loaded = false
    private var persisted: State?
    private var sequence: UInt64 = 0
    private var journalBytes = 0
    private var lastCheckpointDate: Date?
    private var needsCheckpoint = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        checkpointURL: URL,
        checkpointInterval: TimeInterval = 30 * 60,
        maximumJournalBytes: Int = 4 * 1024 * 1024
    ) {
        self.checkpointURL = checkpointURL
        self.journalURL = checkpointURL.appendingPathExtension("updates")
        self.checkpointInterval = checkpointInterval
        self.maximumJournalBytes = maximumJournalBytes
    }

    func load() throws -> State? {
        if loaded { return persisted }
        var recovered: State?
        var recoveredSequence: UInt64 = 0
        var legacy = false
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            let data = try Data(contentsOf: checkpointURL)
            if !data.isEmpty {
                if let checkpoint = try? decoder.decode(Checkpoint.self, from: data) {
                    recovered = checkpoint.state
                    recoveredSequence = checkpoint.sequence
                } else {
                    recovered = try decoder.decode(State.self, from: data)
                    legacy = true
                }
            }
        }

        var bytes = 0
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let data = try Data(contentsOf: journalURL)
            var start = data.startIndex
            while let newline = data[start...].firstIndex(of: 10) {
                let update = try decoder.decode(Update.self, from: data[start..<newline])
                if update.sequence > recoveredSequence {
                    guard update.sequence == recoveredSequence + 1, let previous = recovered else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    var buckets = Self.index(previous.buckets)
                    for key in update.removed { buckets.removeValue(forKey: key) }
                    for bucket in update.buckets { buckets[bucket.startTimestamp] = bucket }
                    var next = update.metadata
                    next.buckets = buckets.values.sorted { $0.startTimestamp < $1.startTimestamp }
                    recovered = next
                    recoveredSequence = update.sequence
                }
                start = data.index(after: newline)
            }
            bytes = start
            // A crash can leave only the final append incomplete. Preserve all complete records.
            if start < data.endIndex {
                let handle = try FileHandle(forWritingTo: journalURL)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(start))
            }
        }
        persisted = recovered
        sequence = recoveredSequence
        journalBytes = bytes
        needsCheckpoint = legacy
        loaded = true
        return recovered
    }

    func save(_ state: State, at now: Date = Date()) throws {
        _ = try load()
        guard persisted != state else { return }
        guard let previous = persisted else {
            try checkpoint(state, at: now)
            return
        }
        let previousBuckets = Self.index(previous.buckets)
        let currentBuckets = Self.index(state.buckets)
        let changed = state.buckets.filter { previousBuckets[$0.startTimestamp] != $0 }
        let removed = previous.buckets.compactMap {
            currentBuckets[$0.startTimestamp] == nil ? $0.startTimestamp : nil
        }
        var metadata = state
        metadata.buckets = []
        let update = Update(sequence: sequence + 1, metadata: metadata, buckets: changed, removed: removed)
        var data = try encoder.encode(update)
        data.append(10)
        if needsCheckpoint || lastCheckpointDate.map({ now.timeIntervalSince($0) >= checkpointInterval }) == true
            || journalBytes + data.count > maximumJournalBytes {
            try checkpoint(state, at: now)
            return
        }
        try ensureDirectory()
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            guard FileManager.default.createFile(atPath: journalURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: data)
        } catch {
            // Do not leave a partial record ahead of the next retry.
            do { try handle.truncate(atOffset: offset) } catch { loaded = false }
            throw error
        }
        sequence += 1
        journalBytes = Int(offset) + data.count
        persisted = state
        if lastCheckpointDate == nil { lastCheckpointDate = now }
    }

    func reset(to state: State, at now: Date = Date()) throws {
        do {
            _ = try load()
        } catch {
            // Restart Baseline is an explicit discard, including a damaged journal.
            // Clear it before replacing the checkpoint so unreadable records cannot reappear.
            try ensureDirectory()
            try Data().write(to: journalURL, options: .atomic)
            loaded = true
            persisted = nil
            sequence = 0
            journalBytes = 0
        }
        try checkpoint(state, at: now)
    }

    private func checkpoint(_ state: State, at now: Date) throws {
        try ensureDirectory()
        let nextSequence = sequence + 1
        try encoder.encode(Checkpoint(sequence: nextSequence, state: state))
            .write(to: checkpointURL, options: .atomic)
        // Publish the checkpoint before rotating. Leftover older updates are skipped on replay.
        sequence = nextSequence
        persisted = state
        lastCheckpointDate = now
        needsCheckpoint = false
        do {
            try Data().write(to: journalURL, options: .atomic)
            journalBytes = 0
        } catch {
            // Force replay before any later append if rotation failed.
            loaded = false
            throw error
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    private static func index(_ buckets: [State.Bucket]) -> [TimeInterval: State.Bucket] {
        buckets.reduce(into: [:]) { $0[$1.startTimestamp] = $1 }
    }
}
