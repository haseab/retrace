import Foundation
import Shared

/// Manages on-disk directory structure for Storage.
actor DirectoryManager {
    private let fileManager = FileManager.default
    private var storageRoot: URL

    init(storageRoot: URL) {
        self.storageRoot = storageRoot
    }

    func updateRoot(_ url: URL) {
        storageRoot = url
    }

    func ensureBaseDirectories() throws {
        let chunks = storageRoot.appendingPathComponent("chunks", isDirectory: true)
        let temp = storageRoot.appendingPathComponent("temp", isDirectory: true)
        try createDirIfNeeded(storageRoot)
        try createDirIfNeeded(chunks)
        try createDirIfNeeded(temp)
    }

    func segmentURL(for id: VideoSegmentID, date: Date) throws -> URL {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        // Format: chunks/YYYYMM/DD/videoID
        let yearMonth = String(format: "%04d%02d", year, month)
        let dayStr = String(format: "%02d", day)

        let dir = storageRoot
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent(yearMonth, isDirectory: true)
            .appendingPathComponent(dayStr, isDirectory: true)

        try createDirIfNeeded(dir)
        // No extension - security through obscurity (files are actually MP4)
        // Database is encrypted with SQLCipher instead
        // Use actual ID instead of placeholder
        return dir.appendingPathComponent("\(id.stringValue)")
    }

    func relativePath(from url: URL) -> String {
        let rootPath = storageRoot.path
        let fullPath = url.path
        if fullPath.hasPrefix(rootPath) {
            let idx = fullPath.index(fullPath.startIndex, offsetBy: rootPath.count)
            let rel = String(fullPath[idx...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel
        }
        return fullPath
    }

    func listAllSegmentFiles() throws -> [URL] {
        let chunksRoot = storageRoot.appendingPathComponent("chunks", isDirectory: true)
        guard fileManager.fileExists(atPath: chunksRoot.path) else { return [] }
        let enumerator = fileManager.enumerator(
            at: chunksRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                urls.append(url)
            }
        }
        return urls
    }

    private func createDirIfNeeded(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw StorageError.directoryCreationFailed(path: url.path)
            }
        }
    }
}

