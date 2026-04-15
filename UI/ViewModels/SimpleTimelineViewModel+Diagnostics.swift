import SwiftUI
import AppKit
import Shared
import App

enum UIDirectFrameDecodeMemoryLedger {
    static let shiftDragGeneratorTag = "ui.timeline.shiftDragDecodeGenerator"
    static let zoomCopyGeneratorTag = "ui.timeline.zoomCopyGenerator"
    static let contextMenuGeneratorTag = "ui.contextMenu.frameDecodeGenerator"
    static let timelineWindowGeneratorTag = "ui.timeline.windowFrameDecodeGenerator"

    private static let tracker = Tracker()
    private static let summaryIntervalSeconds: TimeInterval = 30

    static func begin(
        tag: String,
        function: String,
        reason: String,
        videoInfo: FrameVideoInfo?
    ) -> Int64 {
        let estimatedBytes = TimelineMemoryEstimator.directDecodeGeneratorBytes(for: videoInfo)
        let note = generatorNote(for: videoInfo)
        Task(priority: .utility) {
            await tracker.increment(
                tag: tag,
                function: function,
                kind: "direct-decode-generator",
                note: note,
                bytes: estimatedBytes
            )
            MemoryLedger.emitSummary(
                reason: reason,
                category: .ui,
                minIntervalSeconds: summaryIntervalSeconds
            )
        }
        return estimatedBytes
    }

    static func end(tag: String, reason: String, bytes: Int64) {
        Task(priority: .utility) {
            await tracker.decrement(tag: tag, bytes: bytes)
            MemoryLedger.emitSummary(
                reason: reason,
                category: .ui,
                minIntervalSeconds: summaryIntervalSeconds
            )
        }
    }

    private static func generatorNote(for videoInfo: FrameVideoInfo?) -> String {
        guard let width = videoInfo?.width,
              let height = videoInfo?.height,
              width > 0,
              height > 0 else {
            return "estimated-native,frame=unknown"
        }
        return "estimated-native,frame=\(width)x\(height)"
    }

    private actor Tracker {
        private struct Entry {
            var totalBytes: Int64
            var count: Int
            let function: String
            let kind: String
            var note: String
        }

        private var entries: [String: Entry] = [:]

        func increment(
            tag: String,
            function: String,
            kind: String,
            note: String,
            bytes: Int64
        ) {
            var entry = entries[tag] ?? Entry(
                totalBytes: 0,
                count: 0,
                function: function,
                kind: kind,
                note: note
            )
            entry.totalBytes = clampedAdd(entry.totalBytes, bytes)
            entry.count = clampedAdd(entry.count, 1)
            entry.note = note
            entries[tag] = entry
            publish(tag: tag, entry: entry)
        }

        func decrement(tag: String, bytes: Int64) {
            guard var entry = entries[tag] else { return }
            entry.totalBytes = max(0, entry.totalBytes - bytes)
            entry.count = max(0, entry.count - 1)
            entries[tag] = entry
            publish(tag: tag, entry: entry)
        }

        private func publish(tag: String, entry: Entry) {
            MemoryLedger.set(
                tag: tag,
                bytes: entry.totalBytes,
                count: entry.count,
                unit: "requests",
                function: entry.function,
                kind: entry.kind,
                note: entry.note
            )
        }

        private func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            if lhs > Int64.max - rhs {
                return Int64.max
            }
            return lhs + rhs
        }

        private func clampedAdd(_ lhs: Int, _ rhs: Int) -> Int {
            lhs.addingReportingOverflow(rhs).overflow ? Int.max : lhs + rhs
        }
    }
}

extension SimpleTimelineViewModel {
    /// Enables very verbose timeline logging (useful for debugging, expensive in production).
    /// Disabled by default in all builds; enable manually via:
    /// `defaults write io.retrace.app retrace.debug.timelineVerboseLogs -bool YES`
    static let isVerboseTimelineLoggingEnabled: Bool = {
        return UserDefaults.standard.bool(forKey: "retrace.debug.timelineVerboseLogs")
    }()

    /// Enables filtered-timeline scrub diagnostics (tracks requested frame identities during fast scroll).
    /// Disabled by default in all builds; opt in with:
    /// `defaults write io.retrace.app retrace.debug.filteredScrubDiagnostics -bool YES`
    static let isFilteredScrubDiagnosticsEnabled: Bool = {
        return UserDefaults.standard.bool(forKey: "retrace.debug.filteredScrubDiagnostics")
    }()

    // Temporary debug logging switches intentionally disabled in production.
    static let isTimelineStillLoggingEnabled = false

    struct DiskFrameBufferTelemetry {
        var intervalStart = Date()
        var frameRequests = 0
        var diskHits = 0
        var diskMisses = 0
        var storageReads = 0
        var storageReadFailures = 0
        var decodeSuccesses = 0
        var decodeFailures = 0
        var foregroundLoadCancels = 0
        var cacheMoreRequests = 0
        var cacheMoreFramesQueued = 0
        var cacheMoreStored = 0
        var cacheMoreSkippedBuffered = 0
        var cacheMoreFailures = 0
        var cacheMoreCancelled = 0
    }

    /// App quick-filter latency trace payload carried across async reload/boundary paths.
    struct CmdFQuickFilterLatencyTrace: Sendable {
        let id: String
        let startedAt: CFAbsoluteTime
        let trigger: String
        let action: String
        let bundleID: String
        let source: FrameSource
    }

    private static let diskFrameBufferMemoryLogIntervalNs: UInt64 = 5_000_000_000
    nonisolated private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 30
    nonisolated private static let memoryLedgerDiskBufferTag = "ui.timeline.diskFrameBuffer"
    nonisolated private static let memoryLedgerFrameWindowTag = "ui.timeline.frameWindow"
    nonisolated private static let memoryLedgerCurrentImageTag = "ui.timeline.currentImage"
    nonisolated private static let memoryLedgerWaitingFallbackTag = "ui.timeline.waitingFallbackImage"
    nonisolated private static let memoryLedgerLiveScreenshotTag = "ui.timeline.liveScreenshot"
    nonisolated private static let memoryLedgerShiftDragSnapshotTag = "ui.timeline.shiftDragSnapshot"
    nonisolated private static let memoryLedgerOCRNodesTag = "ui.timeline.ocrNodes"
    nonisolated private static let memoryLedgerPreviousOCRNodesTag = "ui.timeline.previousOcrNodes"
    nonisolated private static let memoryLedgerHyperlinkMatchesTag = "ui.timeline.hyperlinkMatches"
    nonisolated private static let memoryLedgerAppBlockSnapshotTag = "ui.timeline.appBlockSnapshot"
    nonisolated private static let memoryLedgerTagCatalogTag = "ui.timeline.tagCatalog"
    nonisolated private static let memoryLedgerNodeSelectionCacheTag = "ui.timeline.nodeSelectionCache"
    nonisolated private static let memoryLedgerPendingExpansionTag = "ui.timeline.cacheExpansionQueue"

    func startDiskFrameBufferMemoryReporting() {
        diskFrameBufferMemoryLogTask?.cancel()
        diskFrameBufferMemoryLogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(Int64(Self.diskFrameBufferMemoryLogIntervalNs)), clock: .continuous)
                guard !Task.isCancelled, let self else { break }
                self.logDiskFrameBufferMemorySnapshot()
            }
        }
    }

    private func logDiskFrameBufferMemorySnapshot() {
        updateTimelineMemoryLedger()
        logAndResetDiskFrameBufferTelemetry()
    }

    private func updateTimelineMemoryLedger() {
        let frameWindowBytes = TimelineMemoryEstimator.frameWindowBytes(frames)
        let currentImageBytes = UIMemoryEstimator.imageBytes(for: currentImage)
        let waitingFallbackBytes = UIMemoryEstimator.imageBytes(for: waitingFallbackImage)
        let liveScreenshotBytes = UIMemoryEstimator.imageBytes(for: liveScreenshot)
        let shiftDragSnapshotBytes = UIMemoryEstimator.imageBytes(for: shiftDragDisplaySnapshot)
        let ocrNodeBytes = TimelineMemoryEstimator.ocrNodeBytes(ocrNodes)
        let previousOCRNodeBytes = TimelineMemoryEstimator.ocrNodeBytes(previousOcrNodes)
        let hyperlinkBytes = TimelineMemoryEstimator.hyperlinkBytes(hyperlinkMatches)
        let cachedAppBlockSnapshot = latestCachedAppBlockSnapshot
        let appBlockSnapshotBytes = TimelineMemoryEstimator.appBlockSnapshotBytes(
            blocks: cachedAppBlockSnapshot?.blocks ?? [],
            frameToBlockIndexCount: cachedAppBlockSnapshot?.frameToBlockIndex.count ?? 0,
            videoBoundaryCount: cachedAppBlockSnapshot?.videoBoundaryIndices.count ?? 0,
            segmentBoundaryCount: cachedAppBlockSnapshot?.segmentBoundaryIndices.count ?? 0
        )
        let tagCatalogBytes = TimelineMemoryEstimator.tagCatalogBytes(availableTagsByID)
        let nodeSelectionCacheBytes = TimelineMemoryEstimator.nodeSelectionCacheBytes(
            sortedNodes: cachedSortedNodes,
            indexMapCount: cachedNodeIndexMap?.count ?? 0
        )
        let pendingExpansionBytes = TimelineMemoryEstimator.pendingExpansionBytes(
            queuedVideoPaths: pendingCacheExpansionVideoPaths,
            queuedOrInFlightCount: queuedOrInFlightCacheExpansionFrameCount
        )

        MemoryLedger.set(
            tag: Self.memoryLedgerDiskBufferTag,
            bytes: diskFrameBufferByteCount,
            count: diskFrameBufferFrameCount,
            unit: "frames",
            function: "ui.timeline.state",
            kind: "disk-frame-buffer"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerFrameWindowTag,
            bytes: frameWindowBytes,
            count: frames.count,
            unit: "frames",
            function: "ui.timeline.state",
            kind: "frame-window",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerCurrentImageTag,
            bytes: currentImageBytes,
            count: currentImage == nil ? 0 : 1,
            unit: "images",
            function: "ui.timeline.images",
            kind: "current-frame",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerWaitingFallbackTag,
            bytes: waitingFallbackBytes,
            count: waitingFallbackImage == nil ? 0 : 1,
            unit: "images",
            function: "ui.timeline.images",
            kind: "waiting-fallback",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerLiveScreenshotTag,
            bytes: liveScreenshotBytes,
            count: liveScreenshot == nil ? 0 : 1,
            unit: "images",
            function: "ui.timeline.images",
            kind: "live-screenshot",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerShiftDragSnapshotTag,
            bytes: shiftDragSnapshotBytes,
            count: shiftDragDisplaySnapshot == nil ? 0 : 1,
            unit: "images",
            function: "ui.timeline.images",
            kind: "zoom-snapshot",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerOCRNodesTag,
            bytes: ocrNodeBytes,
            count: ocrNodes.count,
            unit: "nodes",
            function: "ui.timeline.ocr_overlay",
            kind: "ocr-nodes",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerPreviousOCRNodesTag,
            bytes: previousOCRNodeBytes,
            count: previousOcrNodes.count,
            unit: "nodes",
            function: "ui.timeline.ocr_overlay",
            kind: "previous-ocr-nodes",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerHyperlinkMatchesTag,
            bytes: hyperlinkBytes,
            count: hyperlinkMatches.count,
            unit: "matches",
            function: "ui.timeline.ocr_overlay",
            kind: "hyperlink-overlay",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerAppBlockSnapshotTag,
            bytes: appBlockSnapshotBytes,
            count: cachedAppBlockSnapshot?.blocks.count ?? 0,
            unit: "blocks",
            function: "ui.timeline.state",
            kind: "app-block-snapshot",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerTagCatalogTag,
            bytes: tagCatalogBytes,
            count: availableTagsByID.count,
            unit: "tags",
            function: "ui.timeline.state",
            kind: "tag-catalog",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerNodeSelectionCacheTag,
            bytes: nodeSelectionCacheBytes,
            count: cachedSortedNodes?.count ?? 0,
            unit: "nodes",
            function: "ui.timeline.state",
            kind: "node-selection-cache",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerPendingExpansionTag,
            bytes: pendingExpansionBytes,
            count: queuedOrInFlightCacheExpansionFrameCount,
            unit: "frames",
            function: "ui.timeline.state",
            kind: "cache-expansion-queue",
            note: "estimated"
        )
        MemoryLedger.emitSummary(
            reason: "ui.timeline.memory",
            category: .ui,
            minIntervalSeconds: Self.memoryLedgerSummaryIntervalSeconds
        )
    }

    private func logAndResetDiskFrameBufferTelemetry() {
        let now = Date()
        let intervalSeconds = max(now.timeIntervalSince(diskFrameBufferTelemetry.intervalStart), 0.001)
        let hadSamples =
            diskFrameBufferTelemetry.frameRequests > 0
            || diskFrameBufferTelemetry.cacheMoreRequests > 0
            || diskFrameBufferTelemetry.cacheMoreFailures > 0
            || diskFrameBufferTelemetry.storageReadFailures > 0
            || diskFrameBufferTelemetry.decodeFailures > 0

        guard hadSamples else {
            diskFrameBufferTelemetry.intervalStart = now
            return
        }

        let requests = diskFrameBufferTelemetry.frameRequests
        let hits = diskFrameBufferTelemetry.diskHits
        let misses = diskFrameBufferTelemetry.diskMisses
        let hitRate = requests > 0 ? (Double(hits) / Double(requests)) * 100.0 : 0
        let requestRate = Double(requests) / intervalSeconds

        Log.info(
            "[Timeline-Perf] interval=\(String(format: "%.1f", intervalSeconds))s frameReq=\(requests) reqRate=\(String(format: "%.1f", requestRate))/s diskHit=\(hits) miss=\(misses) hitRate=\(String(format: "%.1f", hitRate))% storageReads=\(diskFrameBufferTelemetry.storageReads) storageReadFailures=\(diskFrameBufferTelemetry.storageReadFailures) decodeOK=\(diskFrameBufferTelemetry.decodeSuccesses) decodeFail=\(diskFrameBufferTelemetry.decodeFailures) fgCancels=\(diskFrameBufferTelemetry.foregroundLoadCancels) cacheMoreReq=\(diskFrameBufferTelemetry.cacheMoreRequests) cacheMoreQueued=\(diskFrameBufferTelemetry.cacheMoreFramesQueued) cacheMoreStored=\(diskFrameBufferTelemetry.cacheMoreStored) cacheMoreSkipBuffered=\(diskFrameBufferTelemetry.cacheMoreSkippedBuffered) cacheMoreFail=\(diskFrameBufferTelemetry.cacheMoreFailures) cacheMoreCancel=\(diskFrameBufferTelemetry.cacheMoreCancelled) hotWindow=\(describeHotWindowRange()) fgPressure=\(hasForegroundFrameLoadPressure) fgActive=\(hasForegroundFrameLoadActivity) cacheMoreActive=\(hasCacheExpansionActivity)",
            category: .ui
        )

        diskFrameBufferTelemetry = DiskFrameBufferTelemetry(intervalStart: now)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    nonisolated static func clearTimelineMemoryLedger() {
        let zeroCountTags: [(tag: String, unit: String, function: String, kind: String)] = [
            (Self.memoryLedgerDiskBufferTag, "frames", "ui.timeline.state", "disk-frame-buffer"),
            (Self.memoryLedgerFrameWindowTag, "frames", "ui.timeline.state", "frame-window"),
            (Self.memoryLedgerCurrentImageTag, "images", "ui.timeline.images", "current-frame"),
            (Self.memoryLedgerWaitingFallbackTag, "images", "ui.timeline.images", "waiting-fallback"),
            (Self.memoryLedgerLiveScreenshotTag, "images", "ui.timeline.images", "live-screenshot"),
            (Self.memoryLedgerShiftDragSnapshotTag, "images", "ui.timeline.images", "zoom-snapshot"),
            (Self.memoryLedgerOCRNodesTag, "nodes", "ui.timeline.ocr_overlay", "ocr-nodes"),
            (Self.memoryLedgerPreviousOCRNodesTag, "nodes", "ui.timeline.ocr_overlay", "previous-ocr-nodes"),
            (Self.memoryLedgerHyperlinkMatchesTag, "matches", "ui.timeline.ocr_overlay", "hyperlink-overlay"),
            (Self.memoryLedgerAppBlockSnapshotTag, "blocks", "ui.timeline.state", "app-block-snapshot"),
            (Self.memoryLedgerTagCatalogTag, "tags", "ui.timeline.state", "tag-catalog"),
            (Self.memoryLedgerNodeSelectionCacheTag, "nodes", "ui.timeline.state", "node-selection-cache"),
            (Self.memoryLedgerPendingExpansionTag, "frames", "ui.timeline.state", "cache-expansion-queue")
        ]

        for entry in zeroCountTags {
            MemoryLedger.set(
                tag: entry.tag,
                bytes: 0,
                count: 0,
                unit: entry.unit,
                function: entry.function,
                kind: entry.kind
            )
        }
    }

    func logCmdFPlayheadState(
        _ _: String,
        trace _: CmdFQuickFilterLatencyTrace?,
        targetTimestamp _: Date? = nil,
        extra _: String? = nil
    ) {}

    func logFrameWindowSummary(context: String, traceID: UInt64? = nil) {
        let trace = traceID.map { "[DateJump:\($0)] " } ?? ""

        let firstFrame = frames.first
        let lastFrame = frames.last
        let currentFrame = (currentIndex >= 0 && currentIndex < frames.count) ? frames[currentIndex] : nil
        let prevFrame = (currentIndex > 0 && currentIndex - 1 < frames.count) ? frames[currentIndex - 1] : nil
        let nextFrame = (currentIndex + 1 >= 0 && currentIndex + 1 < frames.count) ? frames[currentIndex + 1] : nil

        let firstTS = firstFrame.map { Log.timestamp(from: $0.frame.timestamp) } ?? "nil"
        let lastTS = lastFrame.map { Log.timestamp(from: $0.frame.timestamp) } ?? "nil"
        let currentTS = currentFrame.map { Log.timestamp(from: $0.frame.timestamp) } ?? "nil"

        let gapToPrev = prevFrame.flatMap { prev in
            currentFrame.map { max(0, $0.frame.timestamp.timeIntervalSince(prev.frame.timestamp)) }
        }
        let gapToNext = nextFrame.flatMap { next in
            currentFrame.map { max(0, next.frame.timestamp.timeIntervalSince($0.frame.timestamp)) }
        }

        let gapPrevText = gapToPrev.map { String(format: "%.1fs", $0) } ?? "nil"
        let gapNextText = gapToNext.map { String(format: "%.1fs", $0) } ?? "nil"

        Log.info(
            "\(trace)\(context) window count=\(frames.count) index=\(currentIndex) first=\(firstTS) last=\(lastTS) current=\(currentTS) gapPrev=\(gapPrevText) gapNext=\(gapNextText)",
            category: .ui
        )
    }
}
