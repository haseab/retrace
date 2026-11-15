import AppKit

/// Size changes affect one entry; access-only updates never scan the cache.
struct ByteCountedCacheIndex<Key: Hashable, Value> {
    private var entries: [Key: Value] = [:]
    private let cost: (Value) -> Int64
    private(set) var totalBytes: Int64 = 0
    init(cost: @escaping (Value) -> Int64) { self.cost = cost }
    var count: Int { entries.count }
    var keys: Dictionary<Key, Value>.Keys { entries.keys }
    subscript(key: Key) -> Value? {
        get { entries[key] }
        set {
            if let previous = entries[key] { totalBytes -= cost(previous) }
            entries[key] = newValue
            if let newValue { totalBytes += cost(newValue) }
        }
    }
    @discardableResult mutating func removeValue(forKey key: Key) -> Value? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        totalBytes -= cost(entry)
        return entry
    }
    mutating func removeAll() { entries.removeAll(); totalBytes = 0 }
}

/// Synchronous invalidation lets queued work reject an old preview before touching disk.
final class PreviewCacheEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var current: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func matches(_ token: UInt64) -> Bool { current == token }
    func invalidate() { lock.lock(); value &+= 1; lock.unlock() }
}

/// Immutable after handoff. AppKit image serialization happens only on the worker.
private struct PreviewImage: @unchecked Sendable { let image: NSImage }

/// Synchronous admission preserves request order across the main actor's suspension
/// points. All file access and JPEG serialization run on the serial utility queue.
final class PreviewCacheDiskWorker: @unchecked Sendable {
    static let shared = PreviewCacheDiskWorker()
    struct TrimPolicy: Sendable {
        let directory: URL
        let maxBytes: Int64
        let maxAge: TimeInterval
    }
    struct Statistics: Sendable { var trimPasses = 0; var deletedFiles = 0 }
    private let queue: DispatchQueue
    private let admissionLock = NSLock()
    private let maximumPendingBytes: Int64
    private var pendingBytes: Int64 = 0
    private var pendingTrims: [URL: (UUID, TrimPolicy)] = [:]
    private var lastTrims: [URL: Date] = [:]
    private var stats = Statistics()

    init(queue: DispatchQueue = DispatchQueue(label: "io.retrace.preview-cache-io", qos: .utility), maximumPendingBytes: Int64 = 64 * 1024 * 1024) {
        self.queue = queue
        self.maximumPendingBytes = maximumPendingBytes
    }

    private func reserve(_ bytes: Int64) -> Bool {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        guard bytes <= maximumPendingBytes - pendingBytes else { return false }
        pendingBytes += bytes
        return true
    }

    private func release(_ bytes: Int64) {
        admissionLock.lock()
        pendingBytes -= bytes
        admissionLock.unlock()
    }

    func enqueueWrite(
        _ data: Data, to url: URL, allowed: @escaping @Sendable () -> Bool,
        trim: TrimPolicy? = nil, completion: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        let cost = Int64(data.count)
        guard reserve(cost) else { completion(false); return }
        queue.async {
            defer { self.release(cost) }
            completion(self.write(data, to: url, allowed: allowed, trim: trim))
        }
    }

    func enqueueThumbnail(_ image: NSImage, to url: URL, allowed: @escaping @Sendable () -> Bool, trim: TrimPolicy) {
        let cost = PreviewThumbnailIdentity.memoryCost(image)
        guard reserve(cost) else { return }
        let snapshot = PreviewImage(image: image.copy() as! NSImage)
        queue.async {
            defer { self.release(cost) }
            guard allowed(), let tiff = snapshot.image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return }
            _ = self.write(data, to: url, allowed: allowed, trim: trim)
        }
    }

    private func write(_ data: Data, to url: URL, allowed: () -> Bool, trim: TrimPolicy?) -> Bool {
        guard allowed() else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            guard allowed() else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
            if let trim { scheduleTrim(trim) }
            return true
        } catch { return false } // Cache failures must not prevent displaying the source image.
    }

    func removeFiles(_ urls: [URL]) {
        let requestedAt = Date()
        queue.async {
            for originalURL in urls {
                var url = originalURL
                url.removeAllCachedResourceValues()
                // Capture-time previews have a separate producer. Preserve replacements
                // written after this removal was requested, too.
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date > requestedAt { continue }
                if (try? FileManager.default.removeItem(at: url)) != nil { self.stats.deletedFiles += 1 }
            }
        }
    }

    func pruneTimelineFiles(in directory: URL, olderThan cutoff: Date) {
        queue.async {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { return }
            for url in urls where url.pathExtension == "jpg" && Int64(url.deletingPathExtension().lastPathComponent) != nil {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate, modified <= cutoff else { continue }
                if (try? FileManager.default.removeItem(at: url)) != nil { self.stats.deletedFiles += 1 }
            }
        }
    }

    func requestTrim(_ policy: TrimPolicy) { queue.async { self.scheduleTrim(policy) } }

    private func scheduleTrim(_ policy: TrimPolicy) {
        guard pendingTrims[policy.directory] == nil else { return }
        let id = UUID()
        pendingTrims[policy.directory] = (id, policy)
        // Coalesce bursts, then scan at most once a minute during continuous writes.
        let delay = max(0.25, 60 - Date().timeIntervalSince(lastTrims[policy.directory] ?? .distantPast))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingTrims[policy.directory]?.0 == id else { return }
            self.pendingTrims.removeValue(forKey: policy.directory)
            self.trim(policy)
        }
    }

    private func trim(_ policy: TrimPolicy) {
        stats.trimPasses += 1
        lastTrims[policy.directory] = Date()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: policy.directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-policy.maxAge)
        var entries: [(URL, Date, Int64)] = []
        var bytes: Int64 = 0
        for url in urls where url.pathExtension == "jpg" {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let size = Int64(values.fileSize ?? 0)
            if modified < cutoff, (try? FileManager.default.removeItem(at: url)) != nil { stats.deletedFiles += 1; continue }
            entries.append((url, modified, size)); bytes += size
        }
        for entry in entries.sorted(by: { $0.1 < $1.1 }) where bytes > policy.maxBytes {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { bytes -= entry.2; stats.deletedFiles += 1 }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                let policies = self.pendingTrims.values.map { $0.1 }
                self.pendingTrims.removeAll()
                for policy in policies { self.trim(policy) }
                continuation.resume()
            }
        }
    }
    func statistics() async -> Statistics {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.stats) } }
    }
}

enum PreviewThumbnailIdentity {
    static func key(source: String, frameID: Int64, videoID: Int64, frameIndex: Int, timestamp: TimeInterval, size: CGSize, highlight: CGRect?, revision: String) -> String {
        let crop = highlight.map { [Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)].map { String($0.bitPattern) }.joined(separator: ":") } ?? "full"
        return "preview-v2|\(revision)|\(source)|\(frameID)|\(videoID)|\(frameIndex)|\(timestamp.bitPattern)|\(Double(size.width).bitPattern):\(Double(size.height).bitPattern)|\(crop)"
    }

    /// Read representation dimensions without forcing CGImage creation or decoding on main.
    static func memoryCost(_ image: NSImage) -> Int64 {
        let represented = image.representations.map { representation -> Int64 in
            if let bitmap = representation as? NSBitmapImageRep { return Int64(bitmap.bytesPerRow) * Int64(bitmap.pixelsHigh) }
            return Int64(max(0, representation.pixelsWide)) * Int64(max(0, representation.pixelsHigh)) * 4
        }.max() ?? 0
        let estimated = Int64(max(1, image.size.width.rounded(.up))) * Int64(max(1, image.size.height.rounded(.up))) * 16
        return max(represented, estimated)
    }
}
