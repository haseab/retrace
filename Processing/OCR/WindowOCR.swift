import Foundation
import CoreGraphics
import Vision
import Shared

/// Validates saved geometry before using it to crop screenshot pixels.
enum WindowOCRPlanner {
    static func pixelRegions(_ normalized: [CGRect], width: Int, height: Int) -> [CGRect]? {
        guard width > 0, height > 0, normalized.count <= 16 else { return nil }
        var result: [CGRect] = []
        for rect in normalized {
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width > 0, rect.height > 0, rect.minX >= 0, rect.minY >= 0,
                  rect.maxX <= 1.000001, rect.maxY <= 1.000001 else { return nil }
            let x = (rect.minX * CGFloat(width)).rounded()
            let y = (rect.minY * CGFloat(height)).rounded()
            let right = min(CGFloat(width), (rect.maxX * CGFloat(width)).rounded())
            let bottom = min(CGFloat(height), (rect.maxY * CGFloat(height)).rounded())
            let pixels = CGRect(x: x, y: y, width: right - x, height: bottom - y)
            guard !pixels.isEmpty else { continue }
            result.append(pixels)
        }
        return result
    }

    /// Saved window order defines ownership of composited screenshot pixels.
    static func owns(_ box: CGRect, at index: Int, in windows: [CGRect]) -> Bool {
        windows[index].contains(box) && !windows.prefix(index).contains {
            !$0.intersection(box).isEmpty
        }
    }

    static func visiblePieces(at index: Int, in windows: [CGRect]) -> [CGRect] {
        var pieces = [windows[index]]
        for front in windows.prefix(index) {
            pieces = pieces.flatMap { rect -> [CGRect] in
                let overlap = rect.intersection(front)
                guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
                return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                        CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                        CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                        CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)]
                    .filter { !$0.isEmpty }
            }
        }
        return pieces
    }
}

enum OCRReadingOrder {
    /// Order existing nodes without rebuilding them, so text assembly and node
    /// offsets share the same sequence while identities and rectangles survive.
    static func ordered(_ regions: [TextRegion], windows: [CGRect]? = nil) -> [TextRegion] {
        guard regions.count > 1 else { return regions }
        guard let windows, windows.count <= 16 else {
            return indices(Array(regions.indices), bounds: { regions[$0].bounds }).map { regions[$0] }
        }
        var result: [Int] = [], owned = Set<Int>()
        for index in windows.indices {
            let group = regions.indices.filter { WindowOCRPlanner.owns(regions[$0].bounds, at: index, in: windows) }
            result += indices(group, bounds: { regions[$0].bounds })
            owned.formUnion(group)
        }
        // Ordering is not an exclusion filter. Keep unmatched legacy/cached
        // nodes exactly once; the capture/OCR planners own pixel eligibility.
        result += indices(regions.indices.filter { !owned.contains($0) }, bounds: { regions[$0].bounds })
        return result.map { regions[$0] }
    }

    /// Use vertical centers with half a smaller line-height tolerance, then X.
    /// A row's first box stays fixed so a chain of offsets cannot merge lines.
    static func indices(_ indices: [Int], bounds: (Int) -> CGRect) -> [Int] {
        let boxes = Dictionary(uniqueKeysWithValues: indices.map { ($0, bounds($0)) })
        let valid = indices.filter { index in
            let box = boxes[index]!
            return [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite)
                && box.width > 0 && box.height > 0
        }
        let sorted = valid.sorted {
            let a = boxes[$0]!, b = boxes[$1]!
            if a.midY != b.midY { return a.midY < b.midY }
            if a.minX != b.minX { return a.minX < b.minX }
            return $0 < $1
        }
        var rows: [[Int]] = []
        for index in sorted {
            let box = boxes[index]!
            if let first = rows.last?.first, let row = boxes[first],
               abs(row.midY - box.midY) <= min(row.height, box.height) * 0.5 {
                rows[rows.count - 1].append(index)
            } else {
                rows.append([index])
            }
        }
        let ordered = rows.flatMap { row in
            row.sorted {
                let a = boxes[$0]!, b = boxes[$1]!
                return a.minX == b.minX ? $0 < $1 : a.minX < b.minX
            }
        }
        let seen = Set(valid)
        return ordered + indices.filter { !seen.contains($0) }
    }
}

/// Global bound across OCR workers, not just within one frame. No blocking semaphores.
private actor WindowOCRLimiter {
    static let shared = WindowOCRLimiter()
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().resume() }
    }
}

/// Core Graphics images are immutable. Sharing retains the source image without copying pixels.
private struct WindowOCRImage: @unchecked Sendable { let image: CGImage }

extension VisionOCR {
    func recognizeWindowRegions(
        frame: CapturedFrame, previousFrame: CapturedFrame?, cache: FullFrameOCRCache,
        config: ProcessingConfig, pixelRegions: [CGRect], maximumConcurrentRequests: Int = 2
    ) async throws -> RegionOCRResult {
        let start = ContinuousClock.now
        let invalidated = await cache.validateForFrame(width: frame.width, height: frame.height,
            appBundleID: frame.metadata.appBundleID, ocrRegions: frame.metadata.ocrRegions,
            displayID: frame.metadata.displayID)
        let detector = TileChangeDetector(config: .default)
        let allTiles = detector.createTileGrid(frameWidth: frame.width, frameHeight: frame.height)
        let processed = await cache.hasProcessedFrame()
        let changes = previousFrame.flatMap { detector.detectChanges(current: frame, previous: $0) }
        let needsBaseline = invalidated || !processed || changes == nil
        let changedTiles = needsBaseline ? allTiles : changes!.changedTiles
        let visible = pixelRegions.indices.map { WindowOCRPlanner.visiblePieces(at: $0, in: pixelRegions) }
        let dirty = pixelRegions.indices.filter { index in
            changedTiles.contains { tile in visible[index].contains { $0.intersects(tile.pixelBounds) } }
        }
        let cached = await cache.getCachedRegions()
        if dirty.isEmpty {
            // Also remember an empty result: blank or fully excluded frames need no repeated OCR.
            if needsBaseline { await cache.setFullFrameResults(regions: [], tileGrid: allTiles) }
            return RegionOCRResult(regions: needsBaseline ? [] : cached,
                stats: RegionOCRStats(tilesOCRed: 0, tilesCached: allTiles.count, totalTiles: allTiles.count,
                    changeDetectionTimeMs: changes?.detectionTimeMs ?? 0, ocrTimeMs: 0, mergeTimeMs: 0))
        }
        guard let source = createCGImage(from: frame.imageData, width: frame.width,
            height: frame.height, bytesPerRow: frame.bytesPerRow) else { throw ProcessingError.imageConversionFailed }
        let sharedImage = WindowOCRImage(image: source)
        var fresh: [Int: [TextRegion]] = [:]
        let ocrStart = ContinuousClock.now
        // At most two tasks per frame are queued, and the limiter caps all workers at two requests.
        let batchSize = min(2, max(1, maximumConcurrentRequests))
        for offset in stride(from: 0, to: dirty.count, by: batchSize) {
            let batch = Array(dirty[offset..<min(offset + batchSize, dirty.count)])
            let results = try await withThrowingTaskGroup(of: (Int, [TextRegion]).self) { group in
                for index in batch {
                    group.addTask {
                        let regions = try await self.recognizeWindowCrop(image: sharedImage,
                            bounds: pixelRegions[index], coveredBy: Array(pixelRegions.prefix(index)), config: config)
                        return (index, regions)
                    }
                }
                var output: [(Int, [TextRegion])] = []
                for try await result in group { output.append(result) }
                return output
            }
            for (index, regions) in results { fresh[index] = regions }
        }
        try Task.checkCancellation()
        // Replace whole affected rectangles. Removed text must never linger in the cache.
        var merged: [TextRegion] = []
        for index in pixelRegions.indices {
            merged += fresh[index] ?? cached.filter { WindowOCRPlanner.owns($0.bounds, at: index, in: pixelRegions) }
        }
        await cache.setFullFrameResults(regions: merged, tileGrid: allTiles)
        let recognizedTiles = allTiles.filter { tile in dirty.contains { index in visible[index].contains { $0.intersects(tile.pixelBounds) } } }.count
        let ocrMs = Self.windowMilliseconds(ContinuousClock.now - ocrStart)
        Log.recordLatency("ocr.window_regions", valueMs: Self.windowMilliseconds(ContinuousClock.now - start))
        return RegionOCRResult(regions: merged,
            stats: RegionOCRStats(tilesOCRed: recognizedTiles, tilesCached: allTiles.count - recognizedTiles,
                totalTiles: allTiles.count, changeDetectionTimeMs: changes?.detectionTimeMs ?? 0,
                ocrTimeMs: ocrMs, mergeTimeMs: 0))
    }

    private func recognizeWindowCrop(image: WindowOCRImage, bounds: CGRect, coveredBy: [CGRect], config: ProcessingConfig) async throws -> [TextRegion] {
        await WindowOCRLimiter.shared.acquire()
        do {
            try Task.checkCancellation()
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let tag = "processing.ocr.windowCrop.\(UUID().uuidString)"
                do {
                    let result: [TextRegion] = try autoreleasepool {
                        guard let rawCrop = image.image.cropping(to: bounds) else { throw ProcessingError.imageConversionFailed }
                        let masks = coveredBy.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
                        let crop: CGImage
                        if masks.isEmpty {
                            crop = rawCrop
                        } else {
                            guard let context = CGContext(data: nil, width: rawCrop.width, height: rawCrop.height,
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                                throw ProcessingError.imageConversionFailed
                            }
                            context.draw(rawCrop, in: CGRect(origin: .zero, size: bounds.size))
                            context.setFillColor(CGColor(gray: 1, alpha: 1))
                            for mask in masks {
                                context.fill(CGRect(x: mask.minX - bounds.minX, y: bounds.maxY - mask.maxY,
                                                    width: mask.width, height: mask.height))
                            }
                            guard let masked = context.makeImage() else { throw ProcessingError.imageConversionFailed }
                            crop = masked
                        }
                        MemoryLedger.set(tag: tag, bytes: Int64(crop.width) * Int64(crop.height) * (masks.isEmpty ? 4 : 8),
                            count: 1, unit: "crops", function: "processing.ocr.window", kind: "crop-pixels")
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = Self.recognitionLevel(for: config)
                        request.recognitionLanguages = self.recognitionLanguages
                        request.usesLanguageCorrection = Self.fullFrameRecognitionRequestConfig().usesLanguageCorrection
                        request.preferBackgroundProcessing = config.preferBackgroundProcessing
                        do { try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request]) }
                        catch { throw ProcessingError.ocrFailed(underlying: error.localizedDescription) }
                        try Task.checkCancellation()
                        let recognized = (request.results ?? []).compactMap { observation -> TextRegion? in
                            guard let candidate = observation.topCandidates(1).first,
                                  candidate.confidence >= config.minimumConfidence,
                                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                            let box = observation.boundingBox
                            let mapped = CGRect(x: bounds.minX + box.minX * bounds.width,
                                y: bounds.minY + (1 - box.maxY) * bounds.height,
                                width: box.width * bounds.width, height: box.height * bounds.height).intersection(bounds)
                            guard !masks.contains(where: { !$0.intersection(mapped).isEmpty }) else { return nil }
                            return TextRegion(frameID: .init(value: 0), text: candidate.string,
                                bounds: mapped, confidence: Double(candidate.confidence))
                        }
                        return OCRReadingOrder.ordered(recognized)
                    }
                    await MemoryLedger.remove(tag: tag)
                    return result
                } catch {
                    // Cleanup also completes on OCR failure and cancellation.
                    await MemoryLedger.remove(tag: tag)
                    throw error
                }
            }
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            await WindowOCRLimiter.shared.release()
            return result
        } catch {
            await WindowOCRLimiter.shared.release()
            throw error
        }
    }

    private static func windowMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
