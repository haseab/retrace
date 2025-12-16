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
        let segments = storageRoot.appendingPathComponent("segments", isDirectory: true)
        let temp = storageRoot.appendingPathComponent("temp", isDirectory: true)
        try createDirIfNeeded(storageRoot)
        try createDirIfNeeded(segments)
        try createDirIfNeeded(temp)
    }

    func segmentURL(for id: SegmentID, date: Date) throws -> URL {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        let dir = storageRoot
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)

        try createDirIfNeeded(dir)
        // No extension - security through obscurity (files are actually MP4)
        // Database is encrypted with SQLCipher instead
        return dir.appendingPathComponent("segment_\(id.stringValue)")
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
        let segmentsRoot = storageRoot.appendingPathComponent("segments", isDirectory: true)
        guard fileManager.fileExists(atPath: segmentsRoot.path) else { return [] }
        let enumerator = fileManager.enumerator(
            at: segmentsRoot,
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

