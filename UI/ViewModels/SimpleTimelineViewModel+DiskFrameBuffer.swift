import AppKit
import Foundation
import Shared

extension SimpleTimelineViewModel {
    func setupSearchOverlayPersistence() {
        $isSearchOverlayVisible
            .dropFirst()
            .sink { isVisible in
                UserDefaults.standard.set(isVisible, forKey: "searchOverlayVisible")
            }
            .store(in: &cancellables)
    }

    static func estimatedDiskFrameBufferBytes(_ index: [FrameID: DiskFrameBufferEntry]) -> Int64 {
        index.values.reduce(into: Int64(0)) { total, entry in
            total += entry.sizeBytes
        }
    }

    nonisolated static func timelineDiskFrameBufferDirectoryURL() -> URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDirectory
            .appendingPathComponent("io.retrace.app", isDirectory: true)
            .appendingPathComponent("TimelineFrameBuffer", isDirectory: true)
    }

    static func defaultDiskFrameBufferDirectoryURL() -> URL {
        timelineDiskFrameBufferDirectoryURL()
    }

    nonisolated static func timelineDiskFrameBufferFileURL(for frameID: FrameID) -> URL {
        timelineDiskFrameBufferDirectoryURL()
            .appendingPathComponent("\(frameID.value)")
            .appendingPathExtension(Self.diskFrameBufferFilenameExtension)
    }

    nonisolated static func loadTimelineDiskFrameBufferPreviewImage(
        for frameID: FrameID,
        logPrefix: String
    ) async -> NSImage? {
        let fileURL = timelineDiskFrameBufferFileURL(for: frameID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            }.value

            guard let image = NSImage(data: data) else {
                Log.warning(
                    "\(logPrefix) Failed to decode timeline disk-buffer preview for frame \(frameID.value)",
                    category: .ui
                )
                return nil
            }

            return image
        } catch {
            Log.warning(
                "\(logPrefix) Failed to read timeline disk-buffer preview for frame \(frameID.value): \(error)",
                category: .ui
            )
            return nil
        }
    }

    nonisolated private static func frameID(fromDiskFrameFileURL url: URL) -> FrameID? {
        guard url.pathExtension.lowercased() == Self.diskFrameBufferFilenameExtension else { return nil }
        let frameIDString = url.deletingPathExtension().lastPathComponent
        guard let rawValue = Int64(frameIDString) else { return nil }
        return FrameID(value: rawValue)
    }

    func diskFrameBufferURL(for frameID: FrameID) -> URL {
        diskFrameBufferDirectoryURL
            .appendingPathComponent("\(frameID.value)")
            .appendingPathExtension(Self.diskFrameBufferFilenameExtension)
    }

    func initializeDiskFrameBuffer() {
        diskFrameBufferAccessSequence = 0
        diskFrameBufferIndex = [:]
        diskFrameBufferInitializationTask?.cancel()

        let directoryURL = diskFrameBufferDirectoryURL
        diskFrameBufferInitializationTask = Task { [directoryURL] in
            let outcome = await Task.detached(priority: .utility) {
                Self.initializeDiskFrameBufferSync(directoryURL: directoryURL)
            }.value

            guard !Task.isCancelled else { return }

            if let errorMessage = outcome.errorMessage {
                Log.warning(errorMessage, category: .ui)
                return
            }

            if outcome.removedCount > 0 {
                Log.info(
                    "[Timeline-DiskBuffer] Cleared \(outcome.removedCount) stale disk-buffer files from previous session",
                    category: .ui
                )
            }
        }
    }

    private func awaitDiskFrameBufferInitializationIfNeeded() async {
        guard let initializationTask = diskFrameBufferInitializationTask else { return }
        await initializationTask.value
        diskFrameBufferInitializationTask = nil
    }

    nonisolated private static func initializeDiskFrameBufferSync(
        directoryURL: URL
    ) -> (removedCount: Int, errorMessage: String?) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return (0, "[Timeline-DiskBuffer] Failed to create disk frame buffer directory: \(error)")
        }

        do {
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
            let files = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )

            let appLaunchDate = Self.appLaunchDate
            var removedCount = 0
            for fileURL in files {
                let values = try? fileURL.resourceValues(forKeys: resourceKeys)
                guard values?.isRegularFile == true else { continue }
                guard Self.frameID(fromDiskFrameFileURL: fileURL) != nil else { continue }
                if let contentModifiedAt = values?.contentModificationDate, contentModifiedAt >= appLaunchDate {
                    continue
                }
                try? FileManager.default.removeItem(at: fileURL)
                removedCount += 1
            }

            return (removedCount, nil)
        } catch {
            return (0, "[Timeline-DiskBuffer] Failed to initialize disk frame buffer index: \(error)")
        }
    }

    func containsFrameInDiskFrameBuffer(_ frameID: FrameID) -> Bool {
        diskFrameBufferIndex[frameID] != nil
    }

    private func touchDiskFrameBufferEntry(_ frameID: FrameID) {
        guard var entry = diskFrameBufferIndex[frameID] else { return }
        diskFrameBufferAccessSequence &+= 1
        entry.lastAccessSequence = diskFrameBufferAccessSequence
        diskFrameBufferIndex[frameID] = entry
    }

    @discardableResult
    func removeDiskFrameBufferEntries(
        _ frameIDs: [FrameID],
        reason: String,
        removeExternalFiles: Bool = false
    ) -> (removedFromIndex: Int, removedFromDisk: Int, preservedExternal: Int) {
        guard !frameIDs.isEmpty else { return (0, 0, 0) }

        var removedFromIndex = 0
        var removedFromDisk = 0
        var preservedExternal = 0
        for frameID in frameIDs {
            if let entry = diskFrameBufferIndex.removeValue(forKey: frameID) {
                removedFromIndex += 1
                let shouldRemoveFile = removeExternalFiles || entry.origin == .timelineManaged
                if shouldRemoveFile {
                    try? FileManager.default.removeItem(at: entry.fileURL)
                    removedFromDisk += 1
                } else {
                    preservedExternal += 1
                }
            }
        }

        if Self.isVerboseTimelineLoggingEnabled {
            Log.info(
                "[Memory] Removed frame-buffer entries reason=\(reason) removedFromIndex=\(removedFromIndex) removedFromDisk=\(removedFromDisk) preservedExternal=\(preservedExternal)",
                category: .ui
            )
        }
        return (removedFromIndex, removedFromDisk, preservedExternal)
    }

    func clearDiskFrameBuffer(reason: String) {
        foregroundPresentationWorkState.unavailableFrameLookupTask?.cancel()
        foregroundPresentationWorkState.unavailableFrameLookupTask = nil
        cancelForegroundFrameLoad(reason: "clearDiskFrameBuffer.\(reason)")
        cancelCacheExpansion(reason: "clearDiskFrameBuffer.\(reason)")
        hotWindowRange = nil
        resetCacheMoreEdgeHysteresis()
        let indexedBefore = diskFrameBufferIndex.count
        var removedIndexedFiles = 0
        var removedIndexedFromDisk = 0
        var preservedExternalIndexed = 0
        let frameIDs = Array(diskFrameBufferIndex.keys)
        if !frameIDs.isEmpty {
            let result = removeDiskFrameBufferEntries(
                frameIDs,
                reason: reason,
                removeExternalFiles: false
            )
            removedIndexedFiles = result.removedFromIndex
            removedIndexedFromDisk = result.removedFromDisk
            preservedExternalIndexed = result.preservedExternal
        }
        let removeAllUnindexedFiles = shouldRemoveAllUnindexedDiskFrameBufferFiles(for: reason)
        let removedUnindexedFiles = clearUnindexedDiskFrameBufferFiles(reason: reason, removeAll: removeAllUnindexedFiles)
        if removedIndexedFiles > 0 || removedUnindexedFiles > 0 || removeAllUnindexedFiles || preservedExternalIndexed > 0 {
            let mode = removeAllUnindexedFiles ? "all" : "prune-old"
            Log.info(
                "[Timeline-DiskBuffer] clear reason=\(reason) indexedBefore=\(indexedBefore) removedIndexed=\(removedIndexedFiles) removedIndexedFromDisk=\(removedIndexedFromDisk) preservedExternalIndexed=\(preservedExternalIndexed) removedUnindexed=\(removedUnindexedFiles) mode=\(mode)",
                category: .ui
            )
        }
    }

    private func shouldRemoveAllUnindexedDiskFrameBufferFiles(for reason: String) -> Bool {
        reason == "data source reload"
    }

    private func clearUnindexedDiskFrameBufferFiles(
        reason: String,
        removeAll: Bool
    ) -> Int {
        do {
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
            let files = try FileManager.default.contentsOfDirectory(
                at: diskFrameBufferDirectoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
            let cutoffDate = removeAll ? nil : Date().addingTimeInterval(-Self.diskFrameBufferUnindexedPruneAgeSeconds)
            var removedCount = 0
            for fileURL in files {
                let values = try? fileURL.resourceValues(forKeys: resourceKeys)
                guard values?.isRegularFile == true else { continue }
                guard Self.frameID(fromDiskFrameFileURL: fileURL) != nil else { continue }
                if let cutoffDate,
                   let contentModifiedAt = values?.contentModificationDate,
                   contentModifiedAt >= cutoffDate {
                    continue
                }
                try? FileManager.default.removeItem(at: fileURL)
                removedCount += 1
            }
            if removedCount > 0, Self.isVerboseTimelineLoggingEnabled {
                Log.info(
                    "[Timeline-DiskBuffer] Removed \(removedCount) unindexed disk-buffer files (\(reason))",
                    category: .ui
                )
            }
            return removedCount
        } catch {
            Log.warning(
                "[Timeline-DiskBuffer] Failed to clear unindexed disk-buffer files (\(reason)): \(error)",
                category: .ui
            )
            return 0
        }
    }

    func describeHotWindowRange() -> String {
        guard let hotWindowRange else { return "none" }
        return "\(hotWindowRange.lowerBound)...\(hotWindowRange.upperBound)"
    }

    var hasCacheExpansionActivity: Bool {
        cacheExpansionTask != nil || !pendingCacheExpansionQueue.isEmpty
    }

    var hasForegroundFrameLoadPressure: Bool {
        foregroundPresentationWorkState.activeFrameID != nil || foregroundPresentationWorkState.pendingRequest != nil
    }

    var hasForegroundFrameLoadActivity: Bool {
        hasForegroundFrameLoadPressure || foregroundPresentationWorkState.loadTask != nil
    }

    func cancelForegroundFrameLoad(reason: String) {
        guard hasForegroundFrameLoadActivity else { return }
        foregroundPresentationWorkState.loadTask?.cancel()
        foregroundPresentationWorkState.loadTask = nil
        foregroundPresentationWorkState.pendingRequest = nil
        foregroundPresentationWorkState.activeFrameID = nil
        diskFrameBufferTelemetry.foregroundLoadCancels += 1
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[Timeline-DiskBuffer] Cancelled foreground frame load (\(reason))", category: .ui)
        }
    }

    func cancelCacheExpansion(reason: String) {
        guard hasCacheExpansionActivity else { return }
        cacheExpansionTask?.cancel()
        cacheExpansionTask = nil
        pendingCacheExpansionQueue.removeAll()
        pendingCacheExpansionReadIndex = 0
        queuedOrInFlightCacheExpansionFrameIDs.removeAll()
        diskFrameBufferTelemetry.cacheMoreCancelled += 1
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[Timeline-DiskBuffer] Cancelled cacheMore task (\(reason))", category: .ui)
        }
    }

    func cancelDiskFrameBufferInactivityCleanup() {
        diskFrameBufferInactivityCleanupTask?.cancel()
        diskFrameBufferInactivityCleanupTask = nil
    }

    func scheduleDiskFrameBufferInactivityCleanup() {
        cancelDiskFrameBufferInactivityCleanup()
        diskFrameBufferInactivityCleanupTask = Task { [weak self] in
            let ttlNanoseconds = UInt64(Self.diskFrameBufferInactivityTTLSeconds * 1_000_000_000)
            try? await Task.sleep(for: .nanoseconds(Int64(ttlNanoseconds)), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            guard !self.hasForegroundFrameLoadActivity, !self.hasCacheExpansionActivity else { return }
            self.clearDiskFrameBuffer(reason: "inactivity ttl")
            Log.info(
                "[Timeline-DiskBuffer] Cleared disk buffer after \(Int(Self.diskFrameBufferInactivityTTLSeconds))s inactivity",
                category: .ui
            )
            self.diskFrameBufferInactivityCleanupTask = nil
        }
    }

    public func handleTimelineOpened() {
        setPresentationWorkEnabled(true, reason: "timeline opened")
        cancelDiskFrameBufferInactivityCleanup()
    }

    public func handleTimelineClosed() {
        setPresentationWorkEnabled(false, reason: "timeline closed")
        cancelDragStartStillFrameOCR(reason: "timeline closed")
        foregroundPresentationWorkState.unavailableFrameLookupTask?.cancel()
        foregroundPresentationWorkState.unavailableFrameLookupTask = nil
        cancelForegroundFrameLoad(reason: "timeline closed")
        cancelCacheExpansion(reason: "timeline closed")
        scheduleDiskFrameBufferInactivityCleanup()
    }

    public func resetVisibleSessionScrubTracking(reason: String = "timeline shown") {
        hasStartedScrubbingThisVisibleSession = false
    }

    func markVisibleSessionScrubStarted(source: String) {
        guard !hasStartedScrubbingThisVisibleSession else { return }
        hasStartedScrubbingThisVisibleSession = true
    }

    func readFrameDataFromDiskFrameBuffer(frameID: FrameID) async -> Data? {
        await awaitDiskFrameBufferInitializationIfNeeded()
        let existingEntry = diskFrameBufferIndex[frameID]
        let fileURL = existingEntry?.fileURL ?? diskFrameBufferURL(for: frameID)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if existingEntry != nil {
                removeDiskFrameBufferEntries([frameID], reason: "read missing file")
            }
            return nil
        }

        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            }.value

            if existingEntry != nil {
                touchDiskFrameBufferEntry(frameID)
            } else {
                diskFrameBufferAccessSequence &+= 1
                diskFrameBufferIndex[frameID] = DiskFrameBufferEntry(
                    fileURL: fileURL,
                    sizeBytes: Int64(data.count),
                    lastAccessSequence: diskFrameBufferAccessSequence,
                    origin: .externalCapture
                )
            }

            return data
        } catch {
            removeDiskFrameBufferEntries([frameID], reason: "read failure")
            return nil
        }
    }

    func storeFrameDataInDiskFrameBuffer(frameID: FrameID, data: Data) async {
        await awaitDiskFrameBufferInitializationIfNeeded()
        let fileURL = diskFrameBufferURL(for: frameID)
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: [.atomic])
            }.value

            diskFrameBufferAccessSequence &+= 1
            let entry = DiskFrameBufferEntry(
                fileURL: fileURL,
                sizeBytes: Int64(data.count),
                lastAccessSequence: diskFrameBufferAccessSequence,
                origin: .timelineManaged
            )
            diskFrameBufferIndex[frameID] = entry
        } catch {
            Log.warning("[Timeline-DiskBuffer] Failed to write frame \(frameID.value) to disk buffer: \(error)", category: .ui)
        }
    }
}
