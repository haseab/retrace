import AppKit
import Shared

enum UIMemoryEstimator {
    static func imageBytes(for image: NSImage?) -> Int64 {
        guard let image else { return 0 }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return Int64(cgImage.bytesPerRow * cgImage.height)
        }
        if let bitmapRep = image.representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep {
            return Int64(bitmapRep.bytesPerRow * bitmapRep.pixelsHigh)
        }

        let width = max(Int(image.size.width.rounded()), 1)
        let height = max(Int(image.size.height.rounded()), 1)
        return Int64(width * height * 4)
    }

    static func imageDictionaryBytes(_ images: [String: NSImage]) -> Int64 {
        images.values.reduce(into: Int64(0)) { total, image in
            total += imageBytes(for: image)
        }
    }

    static func stringBytes(_ string: String) -> Int64 {
        Int64(MemoryLayout<String>.stride + string.utf8.count)
    }

    static func optionalStringBytes(_ string: String?) -> Int64 {
        guard let string else { return 0 }
        return stringBytes(string)
    }

    static func stringArrayBytes(_ strings: [String]) -> Int64 {
        strings.reduce(into: Int64(MemoryLayout<String>.stride * strings.count)) { total, string in
            total += stringBytes(string)
        }
    }
}

enum SearchMemoryEstimator {
    static func searchResultsBytes(_ results: [SearchResult]) -> Int64 {
        results.reduce(into: Int64(0)) { total, result in
            total += searchResultBytes(result)
        }
    }

    static func recentSearchEntriesBytes(_ entries: [SearchViewModel.RecentSearchEntry]) -> Int64 {
        entries.reduce(into: Int64(0)) { total, entry in
            total += recentSearchEntryBytes(entry)
        }
    }

    private static func searchResultBytes(_ result: SearchResult) -> Int64 {
        var total = Int64(MemoryLayout<SearchResult>.stride)
        total += UIMemoryEstimator.stringBytes(result.snippet)
        total += UIMemoryEstimator.stringBytes(result.matchedText)
        total += UIMemoryEstimator.optionalStringBytes(result.videoPath)
        total += UIMemoryEstimator.optionalStringBytes(result.metadata.appBundleID)
        total += UIMemoryEstimator.optionalStringBytes(result.metadata.appName)
        total += UIMemoryEstimator.optionalStringBytes(result.metadata.windowName)
        total += UIMemoryEstimator.optionalStringBytes(result.metadata.browserURL)
        total += UIMemoryEstimator.optionalStringBytes(result.metadata.redactionReason)
        return total
    }

    private static func recentSearchEntryBytes(_ entry: SearchViewModel.RecentSearchEntry) -> Int64 {
        var total = Int64(MemoryLayout<SearchViewModel.RecentSearchEntry>.stride)
        total += UIMemoryEstimator.stringBytes(entry.key)
        total += UIMemoryEstimator.stringBytes(entry.query)
        total += recentSearchFiltersBytes(entry.filters)
        return total
    }

    private static func recentSearchFiltersBytes(_ filters: SearchViewModel.RecentSearchFilters) -> Int64 {
        var total = Int64(MemoryLayout<SearchViewModel.RecentSearchFilters>.stride)
        total += UIMemoryEstimator.stringArrayBytes(filters.appBundleIDs)
        total += Int64(MemoryLayout<Int64>.stride * filters.tagIDs.count)
        total += Int64(MemoryLayout<DateRangeCriterion>.stride * filters.dateRanges.count)
        total += UIMemoryEstimator.stringArrayBytes(filters.windowNameTerms)
        total += UIMemoryEstimator.stringArrayBytes(filters.windowNameExcludedTerms)
        total += UIMemoryEstimator.stringArrayBytes(filters.browserUrlTerms)
        total += UIMemoryEstimator.stringArrayBytes(filters.browserUrlExcludedTerms)
        total += UIMemoryEstimator.optionalStringBytes(filters.windowNameFilter)
        total += UIMemoryEstimator.optionalStringBytes(filters.browserUrlFilter)
        total += UIMemoryEstimator.stringArrayBytes(filters.excludedQueryTerms)
        return total
    }
}

enum TimelineMemoryEstimator {
    private static let bytesPerPixel: Int64 = 4
    private static let retainedSurfaceMultiplier: Int64 = 2
    private static let generatorOverheadBytes: Int64 = 512 * 1024
    private static let minimumEstimatedGeneratorBytes: Int64 = 4 * 1024 * 1024

    static func directDecodeGeneratorBytes(for videoInfo: FrameVideoInfo?) -> Int64 {
        guard let width = videoInfo?.width,
              let height = videoInfo?.height,
              width > 0,
              height > 0 else {
            return minimumEstimatedGeneratorBytes
        }

        let surfaceBytes = Int64(width) * Int64(height) * bytesPerPixel
        return max(
            surfaceBytes * retainedSurfaceMultiplier + generatorOverheadBytes,
            minimumEstimatedGeneratorBytes
        )
    }

    static func frameWindowBytes(_ frames: [TimelineFrame]) -> Int64 {
        frames.reduce(into: Int64(0)) { total, frame in
            total += timelineFrameBytes(frame)
        }
    }

    static func ocrNodeBytes(_ nodes: [OCRNodeWithText]) -> Int64 {
        nodes.reduce(into: Int64(0)) { total, node in
            total += Int64(MemoryLayout<OCRNodeWithText>.stride)
            total += UIMemoryEstimator.stringBytes(node.text)
        }
    }

    static func hyperlinkBytes(_ matches: [OCRHyperlinkMatch]) -> Int64 {
        matches.reduce(into: Int64(0)) { total, match in
            total += Int64(MemoryLayout<OCRHyperlinkMatch>.stride)
            total += UIMemoryEstimator.stringBytes(match.id)
            total += UIMemoryEstimator.stringBytes(match.url)
            total += UIMemoryEstimator.stringBytes(match.nodeText)
            total += UIMemoryEstimator.stringBytes(match.domText)
        }
    }

    static func appBlockSnapshotBytes(
        blocks: [AppBlock],
        frameToBlockIndexCount: Int,
        videoBoundaryCount: Int,
        segmentBoundaryCount: Int
    ) -> Int64 {
        var total = blocks.reduce(into: Int64(0)) { running, block in
            running += appBlockBytes(block)
        }
        total += Int64(MemoryLayout<Int>.stride * frameToBlockIndexCount)
        total += Int64(MemoryLayout<Int>.stride * videoBoundaryCount)
        total += Int64(MemoryLayout<Int>.stride * segmentBoundaryCount)
        return total
    }

    static func tagCatalogBytes(_ tagsByID: [Int64: Tag]) -> Int64 {
        tagsByID.values.reduce(into: Int64(0)) { total, tag in
            total += Int64(MemoryLayout<Tag>.stride)
            total += UIMemoryEstimator.stringBytes(tag.name)
        }
    }

    static func nodeSelectionCacheBytes(
        sortedNodes: [OCRNodeWithText]?,
        indexMapCount: Int
    ) -> Int64 {
        var total: Int64 = 0
        if let sortedNodes {
            total += ocrNodeBytes(sortedNodes)
        }
        total += Int64(MemoryLayout<(Int, Int)>.stride * indexMapCount)
        return total
    }

    static func pendingExpansionBytes(
        queuedVideoPaths: [String],
        queuedOrInFlightCount: Int
    ) -> Int64 {
        var total = queuedVideoPaths.reduce(into: Int64(0)) { running, videoPath in
            running += Int64(MemoryLayout<String>.stride)
            running += UIMemoryEstimator.stringBytes(videoPath)
        }
        total += Int64(MemoryLayout<FrameID>.stride * queuedOrInFlightCount)
        return total
    }

    private static func timelineFrameBytes(_ frame: TimelineFrame) -> Int64 {
        var total = Int64(MemoryLayout<TimelineFrame>.stride)
        total += frameReferenceBytes(frame.frame)
        total += frameVideoInfoBytes(frame.videoInfo)
        return total
    }

    private static func frameReferenceBytes(_ frame: FrameReference) -> Int64 {
        var total = Int64(MemoryLayout<FrameReference>.stride)
        total += UIMemoryEstimator.optionalStringBytes(frame.metadata.appBundleID)
        total += UIMemoryEstimator.optionalStringBytes(frame.metadata.appName)
        total += UIMemoryEstimator.optionalStringBytes(frame.metadata.windowName)
        total += UIMemoryEstimator.optionalStringBytes(frame.metadata.browserURL)
        total += UIMemoryEstimator.optionalStringBytes(frame.metadata.redactionReason)
        return total
    }

    private static func frameVideoInfoBytes(_ videoInfo: FrameVideoInfo?) -> Int64 {
        guard let videoInfo else { return 0 }
        return Int64(MemoryLayout<FrameVideoInfo>.stride) + UIMemoryEstimator.stringBytes(videoInfo.videoPath)
    }

    private static func appBlockBytes(_ block: AppBlock) -> Int64 {
        var total = Int64(MemoryLayout<AppBlock>.stride)
        total += UIMemoryEstimator.optionalStringBytes(block.bundleID)
        total += UIMemoryEstimator.optionalStringBytes(block.appName)
        total += Int64(MemoryLayout<Int64>.stride * block.tagIDs.count)
        return total
    }
}
