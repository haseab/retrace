import Foundation
import Shared

extension SimpleTimelineViewModel {
    func makeCenteredHotWindow(around index: Int) -> ClosedRange<Int> {
        let totalFrames = frames.count
        let targetCount = min(Self.hotWindowFrameCount, totalFrames)
        guard targetCount > 0 else { return 0...0 }

        var lowerBound = max(0, index - (targetCount / 2))
        var upperBound = lowerBound + targetCount - 1
        if upperBound >= totalFrames {
            upperBound = totalFrames - 1
            lowerBound = max(0, upperBound - targetCount + 1)
        }
        return lowerBound...upperBound
    }

    func ensureDiskHotWindowCoverage(reason: String) {
        guard !frames.isEmpty else { return }
        guard currentIndex >= 0 && currentIndex < frames.count else { return }

        guard let existingRange = hotWindowRange, existingRange.contains(currentIndex) else {
            let centeredRange = makeCenteredHotWindow(around: currentIndex)
            resetCacheMoreEdgeHysteresis()
            hotWindowRange = centeredRange
            queueCacheMoreFrames(
                for: centeredRange,
                direction: .centered,
                reason: "hot-window-reset.\(reason)"
            )
            return
        }

        let distanceToLower = currentIndex - existingRange.lowerBound
        let distanceToUpper = existingRange.upperBound - currentIndex
        if distanceToLower > Self.cacheMoreEdgeRetriggerDistance {
            cacheMoreOlderEdgeArmed = true
        }
        if distanceToUpper > Self.cacheMoreEdgeRetriggerDistance {
            cacheMoreNewerEdgeArmed = true
        }

        let shouldExpandOlder = distanceToLower <= Self.cacheMoreEdgeThreshold && cacheMoreOlderEdgeArmed
        let shouldExpandNewer = distanceToUpper <= Self.cacheMoreEdgeThreshold && cacheMoreNewerEdgeArmed

        if shouldExpandOlder && shouldExpandNewer {
            if distanceToLower <= distanceToUpper {
                cacheMoreOlderEdgeArmed = false
                expandHotWindowOlder(reason: reason)
            } else {
                cacheMoreNewerEdgeArmed = false
                expandHotWindowNewer(reason: reason)
            }
            return
        }

        if shouldExpandOlder {
            cacheMoreOlderEdgeArmed = false
            expandHotWindowOlder(reason: reason)
        } else if shouldExpandNewer {
            cacheMoreNewerEdgeArmed = false
            expandHotWindowNewer(reason: reason)
        }
    }

    func expandHotWindowOlder(reason: String) {
        guard let currentRange = hotWindowRange else { return }
        let newLowerBound = max(0, currentRange.lowerBound - Self.cacheMoreBatchSize)
        guard newLowerBound < currentRange.lowerBound else { return }
        let expansionRange = newLowerBound...(currentRange.lowerBound - 1)
        hotWindowRange = newLowerBound...currentRange.upperBound
        queueCacheMoreFrames(for: expansionRange, direction: .older, reason: reason)
    }

    func expandHotWindowNewer(reason: String) {
        guard let currentRange = hotWindowRange else { return }
        let newUpperBound = min(frames.count - 1, currentRange.upperBound + Self.cacheMoreBatchSize)
        guard newUpperBound > currentRange.upperBound else { return }
        let expansionRange = (currentRange.upperBound + 1)...newUpperBound
        hotWindowRange = currentRange.lowerBound...newUpperBound
        queueCacheMoreFrames(for: expansionRange, direction: .newer, reason: reason)
    }

    func queueCacheMoreFrames(
        for indexRange: ClosedRange<Int>,
        direction: CacheExpansionDirection,
        reason: String
    ) {
        guard !frames.isEmpty else { return }
        guard indexRange.lowerBound >= 0, indexRange.upperBound < frames.count else { return }

        let orderedIndices = makeCacheMoreOrderedIndices(for: indexRange, direction: direction)
        var queuedCount = 0

        for index in orderedIndices {
            guard index >= 0 && index < frames.count else { continue }
            let timelineFrame = frames[index]
            guard let videoInfo = timelineFrame.videoInfo else { continue }
            let descriptor = CacheMoreFrameDescriptor(
                frameID: timelineFrame.frame.id,
                videoPath: videoInfo.videoPath,
                frameIndex: videoInfo.frameIndex
            )

            if containsFrameInDiskFrameBuffer(descriptor.frameID)
                || queuedOrInFlightCacheExpansionFrameIDs.contains(descriptor.frameID) {
                diskFrameBufferTelemetry.cacheMoreSkippedBuffered += 1
                continue
            }

            pendingCacheExpansionQueue.append(descriptor)
            queuedOrInFlightCacheExpansionFrameIDs.insert(descriptor.frameID)
            queuedCount += 1
        }

        guard queuedCount > 0 else { return }

        diskFrameBufferTelemetry.cacheMoreRequests += 1
        diskFrameBufferTelemetry.cacheMoreFramesQueued += queuedCount

        if Self.isVerboseTimelineLoggingEnabled {
            let pendingCount = pendingCacheExpansionQueue.count - pendingCacheExpansionReadIndex
            Log.debug(
                "[Timeline-DiskBuffer] cacheMore queued direction=\(direction.rawValue) added=\(queuedCount) pending=\(max(pendingCount, 0)) reason=\(reason)",
                category: .ui
            )
        }

        guard cacheExpansionTask == nil else { return }
        cacheExpansionTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runCacheMoreWorker()
        }
    }

    func runCacheMoreWorker() async {
        defer {
            cacheExpansionTask = nil
            pendingCacheExpansionQueue.removeAll()
            pendingCacheExpansionReadIndex = 0
            queuedOrInFlightCacheExpansionFrameIDs.removeAll()
        }

        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[Timeline-DiskBuffer] cacheMore worker started", category: .ui)
        }

        while let descriptor = dequeueNextPendingCacheExpansionDescriptor() {
            defer { queuedOrInFlightCacheExpansionFrameIDs.remove(descriptor.frameID) }

            if Task.isCancelled {
                diskFrameBufferTelemetry.cacheMoreCancelled += 1
                return
            }

            if containsFrameInDiskFrameBuffer(descriptor.frameID) {
                diskFrameBufferTelemetry.cacheMoreSkippedBuffered += 1
                continue
            }

            while hasForegroundFrameLoadPressure || isActivelyScrolling {
                if Task.isCancelled {
                    diskFrameBufferTelemetry.cacheMoreCancelled += 1
                    return
                }
                try? await Task.sleep(for: .milliseconds(20), clock: .continuous)
            }

            do {
                let storageReadStart = CFAbsoluteTimeGetCurrent()
                let imageData = try await coordinator.getFrameImageFromPath(
                    videoPath: descriptor.videoPath,
                    frameIndex: descriptor.frameIndex
                )
                let storageReadMs = (CFAbsoluteTimeGetCurrent() - storageReadStart) * 1000
                let shouldEmitInteractiveSlowSampleAlerts = TimelineWindowController.shared.isVisible
                Log.recordLatency(
                    "timeline.cache_more.storage_read_ms",
                    valueMs: storageReadMs,
                    category: .ui,
                    summaryEvery: 25,
                    warningThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? 55 : nil,
                    criticalThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? 180 : nil
                )

                if Task.isCancelled {
                    diskFrameBufferTelemetry.cacheMoreCancelled += 1
                    return
                }

                await storeFrameDataInDiskFrameBuffer(frameID: descriptor.frameID, data: imageData)
                diskFrameBufferTelemetry.cacheMoreStored += 1
            } catch is CancellationError {
                diskFrameBufferTelemetry.cacheMoreCancelled += 1
                return
            } catch {
                diskFrameBufferTelemetry.cacheMoreFailures += 1
            }
        }

        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[Timeline-DiskBuffer] cacheMore worker drained queue", category: .ui)
        }
    }

    func dequeueNextPendingCacheExpansionDescriptor() -> CacheMoreFrameDescriptor? {
        guard pendingCacheExpansionReadIndex < pendingCacheExpansionQueue.count else {
            pendingCacheExpansionQueue.removeAll(keepingCapacity: true)
            pendingCacheExpansionReadIndex = 0
            return nil
        }

        let descriptor = pendingCacheExpansionQueue[pendingCacheExpansionReadIndex]
        pendingCacheExpansionReadIndex += 1

        if pendingCacheExpansionReadIndex >= 128
            && pendingCacheExpansionReadIndex * 2 >= pendingCacheExpansionQueue.count {
            pendingCacheExpansionQueue.removeFirst(pendingCacheExpansionReadIndex)
            pendingCacheExpansionReadIndex = 0
        }

        return descriptor
    }

    func makeCacheMoreOrderedIndices(
        for indexRange: ClosedRange<Int>,
        direction: CacheExpansionDirection
    ) -> [Int] {
        var ordered = Array(indexRange)
        switch direction {
        case .older:
            ordered.reverse()
        case .newer:
            break
        case .centered:
            ordered.sort { lhs, rhs in
                let lhsDistance = abs(lhs - currentIndex)
                let rhsDistance = abs(rhs - currentIndex)
                if lhsDistance == rhsDistance {
                    return lhs < rhs
                }
                return lhsDistance < rhsDistance
            }
        }
        return ordered
    }

    func resetCacheMoreEdgeHysteresis() {
        cacheMoreOlderEdgeArmed = true
        cacheMoreNewerEdgeArmed = true
    }
}
