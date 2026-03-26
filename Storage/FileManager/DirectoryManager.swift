import Foundation
import Shared

/// Manages on-disk directory structure for Storage.
actor DirectoryManager {
    private let fileManager = FileManager.default
    private var vaultRoot: URL
    private var appSupportRoot: URL

    init(storageRoot: URL, appSupportRoot: URL? = nil) {
        self.vaultRoot = storageRoot
        self.appSupportRoot = appSupportRoot ?? storageRoot
    }

    func updateRoots(storageRoot: URL, appSupportRoot: URL) {
        vaultRoot = storageRoot
        self.appSupportRoot = appSupportRoot
    }

    func ensureBaseDirectories() throws {
        let chunks = vaultRoot.appendingPathComponent("chunks", isDirectory: true)
        let temp = appSupportRoot.appendingPathComponent("temp", isDirectory: true)

        // Create vault and app-home roots if needed
        try createDirIfNeeded(vaultRoot)
        try createDirIfNeeded(appSupportRoot)

        // For chunks: only create if it doesn't exist
        // This prevents creating empty chunks folder when database already has data elsewhere
        if !fileManager.fileExists(atPath: chunks.path) {
            try createDirIfNeeded(chunks)
            Log.info("Created chunks directory at: \(chunks.path)", category: .storage)
        } else {
            Log.info("Using existing chunks directory at: \(chunks.path)", category: .storage)
        }

        // Temp directory is always safe to create
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

        let dir = vaultRoot
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
        let rootPath = vaultRoot.path
        let fullPath = url.path
        if fullPath.hasPrefix(rootPath) {
            let idx = fullPath.index(fullPath.startIndex, offsetBy: rootPath.count)
            let rel = String(fullPath[idx...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel
        }
        return fullPath
    }

    func listAllSegmentFiles() throws -> [URL] {
        let chunksRoot = vaultRoot.appendingPathComponent("chunks", isDirectory: true)
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
