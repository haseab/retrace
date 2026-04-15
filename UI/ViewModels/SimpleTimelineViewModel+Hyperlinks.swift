import App
import AppKit
import AVFoundation
import Database
import Foundation
import ImageIO
import Processing
import Shared
import SwiftUI

extension SimpleTimelineViewModel {
    func fetchPresentationHyperlinkMatches(
        for frame: FrameReference,
        nodes: [OCRNodeWithText],
        expectedGeneration: UInt64
    ) async -> [OCRHyperlinkMatch] {
        guard canPublishPresentationResult(
            frameID: frame.id,
            expectedGeneration: expectedGeneration
        ) else { return [] }
        guard Self.isInPageURLCollectionEnabled(), !nodes.isEmpty else { return [] }

        do {
            let storedRows = try await coordinator.getFrameInPageURLRows(frameID: frame.id)
            return Self.hyperlinkMatchesFromStoredRows(storedRows, nodes: nodes)
        } catch {
            Log.warning("[HyperlinkMap] DOM extraction failed: \(error)", category: .ui)
            return []
        }
    }

    func loadFrameMousePosition(expectedGeneration: UInt64 = 0) {
        guard Self.isMousePositionCaptureEnabled() else {
            setFrameMousePosition(nil)
            return
        }

        guard let timelineFrame = currentTimelineFrame else {
            setFrameMousePosition(nil)
            return
        }

        let generation = expectedGeneration == 0
            ? currentPresentationWorkGeneration()
            : expectedGeneration
        let frameID = timelineFrame.frame.id
        guard canPublishPresentationResult(
            frameID: frameID,
            expectedGeneration: generation
        ) else { return }

        let metadataMousePosition = timelineFrame.frame.metadata.mousePosition
        let nextMousePosition: CGPoint?
        if let metadataMousePosition,
           metadataMousePosition.x.isFinite,
           metadataMousePosition.y.isFinite,
           metadataMousePosition.x >= 0,
           metadataMousePosition.y >= 0 {
            nextMousePosition = metadataMousePosition
        } else {
            nextMousePosition = nil
        }

        if canPublishPresentationResult(
            frameID: frameID,
            expectedGeneration: generation
        ) {
            setFrameMousePosition(nextMousePosition)
        }
    }

    public func openURLInBrowser() {
        guard let box = urlBoundingBox,
              let url = URL(string: box.url) else {
            return
        }

        NSWorkspace.shared.open(url)
        Log.info("[URLBoundingBox] Opened URL in browser: \(box.url)", category: .ui)
    }

    @discardableResult
    public func openCurrentBrowserURL() -> Bool {
        guard let timelineFrame = currentTimelineFrame,
              let urlString = timelineFrame.frame.metadata.browserURL,
              !urlString.isEmpty else {
            return false
        }

        Log.debug(
            "[BrowserLinkOpen] start frameId=\(timelineFrame.frame.id.value) baseURL=\(urlString) videoCurrentTime=\(String(describing: timelineFrame.videoCurrentTime))",
            category: .ui
        )
        let finalURLString = timestampedCurrentBrowserURLString(
            baseURLString: urlString,
            videoCurrentTime: timelineFrame.videoCurrentTime
        )
        Log.debug(
            "[BrowserLinkOpen] resolved frameId=\(timelineFrame.frame.id.value) finalURL=\(finalURLString)",
            category: .ui
        )
        guard let finalURL = URL(string: finalURLString) else {
            Log.warning(
                "[BrowserLinkOpen] invalid final URL frameId=\(timelineFrame.frame.id.value) finalURL=\(finalURLString)",
                category: .ui
            )
            return false
        }

        let usedYouTubeTimestamp = Self.urlContainsYouTubeTimestamp(finalURLString)

        guard let browserApplicationURL = Self.hyperlinkBrowserApplicationURL(for: finalURL) else {
            let opened = NSWorkspace.shared.open(finalURL)
            if opened {
                Log.info("[Timeline] Opened current browser URL via fallback dispatch: \(finalURLString)", category: .ui)
                DashboardViewModel.recordBrowserLinkOpened(
                    coordinator: coordinator,
                    source: "current_browser_url",
                    url: finalURLString,
                    usedYouTubeTimestamp: usedYouTubeTimestamp
                )
            } else {
                Log.warning("[Timeline] Failed to open current browser URL: \(finalURLString)", category: .ui)
            }
            return true
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        NSWorkspace.shared.open([finalURL], withApplicationAt: browserApplicationURL, configuration: configuration) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    Log.warning(
                        "[Timeline] Failed to open current browser URL in explicit browser \(browserApplicationURL.path): \(finalURLString) | \(error.localizedDescription)",
                        category: .ui
                    )
                } else {
                    Log.info(
                        "[Timeline] Opened current browser URL in explicit browser \(browserApplicationURL.path): \(finalURLString)",
                        category: .ui
                    )
                    DashboardViewModel.recordBrowserLinkOpened(
                        coordinator: self.coordinator,
                        source: "current_browser_url",
                        url: finalURLString,
                        usedYouTubeTimestamp: usedYouTubeTimestamp
                    )
                }
            }
        }
        return true
    }

    @discardableResult
    public func copyCurrentBrowserURL() -> Bool {
        guard let timelineFrame = currentTimelineFrame,
              let urlString = timelineFrame.frame.metadata.browserURL,
              !urlString.isEmpty else {
            return false
        }

        let finalURLString = timestampedCurrentBrowserURLString(
            baseURLString: urlString,
            videoCurrentTime: timelineFrame.videoCurrentTime
        )
        guard URL(string: finalURLString) != nil else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(finalURLString, forType: .string)
        showToast("Link copied")
        Log.info("[Timeline] Copied current browser URL: \(finalURLString)", category: .ui)
        return true
    }

    @discardableResult
    public func copyCurrentYouTubeMarkdownLink() -> Bool {
        guard let context = currentYouTubeMarkdownCopyContext(),
              let timelineFrame = currentTimelineFrame else {
            showToast("No YouTube page to copy", icon: "exclamationmark.circle.fill")
            return false
        }

        guard let ocrMatch = Self.resolveYouTubeOCRMatch(
            windowName: context.windowName,
            nodes: ocrNodes
        ) else {
            showToast("Couldn't find YouTube channel", icon: "exclamationmark.circle.fill")
            Log.warning(
                "[Timeline] Failed to copy YouTube markdown link for frame \(timelineFrame.frame.id.value) url=\(context.urlString)",
                category: .ui
            )
            return false
        }

        copyYouTubeMarkdownLinkToPasteboard(
            match: ocrMatch,
            context: context
        )
        return true
    }

    private func copyYouTubeMarkdownLinkToPasteboard(
        match: TimelineYouTubeLinkSupport.OCRMatch,
        context: TimelineYouTubeLinkSupport.MarkdownCopyContext
    ) {
        let markdown = Self.youtubeMarkdownClipboardString(
            channelName: match.channelText,
            titleText: match.titleText,
            urlString: context.urlString
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        pasteboard.setString(markdown, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
        showToast("YouTube link copied")
        DashboardViewModel.recordTextCopy(coordinator: coordinator, text: markdown)
        Log.info("[Timeline] Copied YouTube markdown link: \(markdown)", category: .ui)
    }

    private func currentYouTubeMarkdownCopyContext() -> TimelineYouTubeLinkSupport.MarkdownCopyContext? {
        guard let timelineFrame = currentTimelineFrame else {
            return nil
        }

        return TimelineYouTubeLinkSupport.copyContext(
            windowName: normalizedMetadataString(timelineFrame.frame.metadata.windowName),
            urlString: normalizedMetadataString(timelineFrame.frame.metadata.browserURL)
        )
    }

    private func timestampedCurrentBrowserURLString(
        baseURLString: String,
        videoCurrentTime: Double?
    ) -> String {
        TimelineYouTubeLinkSupport.timestampedBrowserURLString(
            baseURLString,
            videoCurrentTime: videoCurrentTime
        )
    }

    static func youtubeTimestampedBrowserURLString(
        _ urlString: String,
        videoCurrentTime: Double?
    ) -> String {
        TimelineYouTubeLinkSupport.timestampedBrowserURLString(
            urlString,
            videoCurrentTime: videoCurrentTime
        )
    }

    static func isYouTubeMarkdownCopyCandidate(
        windowName: String?,
        urlString: String?
    ) -> Bool {
        TimelineYouTubeLinkSupport.isMarkdownCopyCandidate(
            windowName: windowName,
            urlString: urlString
        )
    }

    static func youtubeMarkdownClipboardString(
        channelName: String,
        titleText: String,
        urlString: String
    ) -> String {
        TimelineYouTubeLinkSupport.markdownClipboardString(
            channelName: channelName,
            titleText: titleText,
            urlString: urlString
        )
    }

    static func resolveYouTubeOCRMatch(
        windowName: String,
        nodes: [OCRNodeWithText]
    ) -> TimelineYouTubeLinkSupport.OCRMatch? {
        TimelineYouTubeLinkSupport.resolveOCRMatch(
            windowName: windowName,
            nodes: nodes
        )
    }

    static func makeCommentComposerTargetDisplayInfo(
        timelineFrame: TimelineFrame,
        block: AppBlock?,
        availableTagsByID: [Int64: Tag],
        selectedSegmentTagIDs: Set<Int64> = []
    ) -> CommentComposerTargetDisplayInfo {
        let metadata = timelineFrame.frame.metadata
        let candidateTagIDs: [Int64]
        if let block, !block.tagIDs.isEmpty {
            candidateTagIDs = block.tagIDs
        } else {
            candidateTagIDs = Array(selectedSegmentTagIDs).sorted()
        }

        let tagNames = candidateTagIDs
            .compactMap { availableTagsByID[$0]?.name }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return CommentComposerTargetDisplayInfo(
            frameID: timelineFrame.frame.id,
            segmentID: SegmentID(value: timelineFrame.frame.segmentID.value),
            source: timelineFrame.frame.source,
            timestamp: timelineFrame.frame.timestamp,
            appBundleID: metadata.appBundleID,
            appName: metadata.appName,
            windowName: metadata.windowName,
            browserURL: metadata.browserURL,
            tagNames: tagNames
        )
    }

    private static func urlContainsYouTubeTimestamp(_ urlString: String) -> Bool {
        TimelineYouTubeLinkSupport.urlContainsTimestamp(urlString)
    }

    static func inPageURLLinkMetricMetadata(
        url: String,
        linkText: String,
        nodeID: Int
    ) -> String? {
        UIMetricsRecorder.jsonMetadata([
            "url": url,
            "linkText": linkText,
            "nodeID": nodeID
        ])
    }

    private static func inPageURLLinkText(for match: OCRHyperlinkMatch) -> String {
        let domText = match.domText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !domText.isEmpty {
            return domText
        }
        return match.nodeText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recordInPageURLLinkMetric(
        metricType: DailyMetricsQueries.MetricType,
        url: String,
        linkText: String,
        nodeID: Int
    ) {
        UIMetricsRecorder.record(
            coordinator: coordinator,
            type: metricType,
            metadata: Self.inPageURLLinkMetricMetadata(
                url: url,
                linkText: linkText,
                nodeID: nodeID
            )
        )
    }

    static func inPageURLHoverMetricKey(
        frameID: FrameID?,
        url: String,
        nodeID: Int
    ) -> String {
        let frameToken = frameID.map { String($0.value) } ?? "none"
        return "\(frameToken)|\(nodeID)|\(url)"
    }

    @discardableResult
    func beginInPageURLHoverTracking(
        url: String,
        nodeID: Int,
        frameID: FrameID?
    ) -> Bool {
        let key = Self.inPageURLHoverMetricKey(
            frameID: frameID,
            url: url,
            nodeID: nodeID
        )
        guard activeInPageURLHoverMetricKey != key else {
            return false
        }
        activeInPageURLHoverMetricKey = key
        return true
    }

    func endInPageURLHoverTracking() {
        activeInPageURLHoverMetricKey = nil
    }

    func updateInPageURLHoverState(_ match: OCRHyperlinkMatch?) {
        guard let match else {
            endInPageURLHoverTracking()
            return
        }

        let resolvedURLString = resolvedHyperlinkURLString(for: match) ?? match.url
        guard beginInPageURLHoverTracking(
            url: resolvedURLString,
            nodeID: match.nodeID,
            frameID: currentFrame?.id
        ) else {
            return
        }

        recordInPageURLLinkMetric(
            metricType: .inPageURLHover,
            url: resolvedURLString,
            linkText: Self.inPageURLLinkText(for: match),
            nodeID: match.nodeID
        )
    }

    func recordInPageURLRightClick(for match: OCRHyperlinkMatch) {
        let resolvedURLString = resolvedHyperlinkURLString(for: match) ?? match.url
        recordInPageURLLinkMetric(
            metricType: .inPageURLRightClick,
            url: resolvedURLString,
            linkText: Self.inPageURLLinkText(for: match),
            nodeID: match.nodeID
        )
    }

    @discardableResult
    public func openHyperlinkMatch(_ match: OCRHyperlinkMatch) -> Bool {
        guard let resolvedURLString = resolvedHyperlinkURLString(for: match),
              let url = URL(string: resolvedURLString) else {
            return false
        }
        let coordinator = self.coordinator

        recordInPageURLLinkMetric(
            metricType: .inPageURLClick,
            url: resolvedURLString,
            linkText: Self.inPageURLLinkText(for: match),
            nodeID: match.nodeID
        )

        guard let browserApplicationURL = Self.hyperlinkBrowserApplicationURL(for: url) else {
            let opened = NSWorkspace.shared.open(url)
            if opened {
                Log.info("[HyperlinkMap] Opened mapped hyperlink via fallback dispatch: \(resolvedURLString)", category: .ui)
                DashboardViewModel.recordBrowserLinkOpened(
                    coordinator: coordinator,
                    source: "in_page_url_hyperlink",
                    url: resolvedURLString,
                    usedYouTubeTimestamp: false
                )
            } else {
                Log.warning("[HyperlinkMap] Failed to open mapped hyperlink: \(resolvedURLString)", category: .ui)
            }
            return opened
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        NSWorkspace.shared.open([url], withApplicationAt: browserApplicationURL, configuration: configuration) { _, error in
            if let error {
                Log.warning(
                    "[HyperlinkMap] Failed to open mapped hyperlink in explicit browser \(browserApplicationURL.path): \(resolvedURLString) | \(error.localizedDescription)",
                    category: .ui
                )
            } else {
                Log.info(
                    "[HyperlinkMap] Opened mapped hyperlink in explicit browser \(browserApplicationURL.path): \(resolvedURLString)",
                    category: .ui
                )
                Task { @MainActor in
                    DashboardViewModel.recordBrowserLinkOpened(
                        coordinator: coordinator,
                        source: "in_page_url_hyperlink",
                        url: resolvedURLString,
                        usedYouTubeTimestamp: false
                    )
                }
            }
        }
        return true
    }

    public func resolvedHyperlinkURLString(for match: OCRHyperlinkMatch) -> String? {
        let resolvedURLString = Self.resolveStoredHyperlinkURL(
            match.url,
            baseURL: currentFrame?.metadata.browserURL
        )
        guard URL(string: resolvedURLString) != nil else {
            return nil
        }
        return resolvedURLString
    }

    @discardableResult
    public func copyHyperlinkMatch(_ match: OCRHyperlinkMatch) -> Bool {
        guard let resolvedURLString = resolvedHyperlinkURLString(for: match) else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(resolvedURLString, forType: .string)
        recordInPageURLLinkMetric(
            metricType: .inPageURLCopyLink,
            url: resolvedURLString,
            linkText: Self.inPageURLLinkText(for: match),
            nodeID: match.nodeID
        )
        showToast("Link copied")
        Log.info("[HyperlinkMap] Copied mapped hyperlink: \(resolvedURLString)", category: .ui)
        return true
    }

    func clearHyperlinkMatches() {
        endInPageURLHoverTracking()
        setHyperlinkMatches([])
    }

    nonisolated static func hyperlinkMatchesFromStoredRows(
        _ rows: [AppCoordinator.FrameInPageURLRow],
        nodes: [OCRNodeWithText]
    ) -> [OCRHyperlinkMatch] {
        guard !rows.isEmpty else { return [] }
        var nodesByID: [Int: OCRNodeWithText] = [:]
        nodesByID.reserveCapacity(nodes.count)
        var nodesByNodeOrder: [Int: OCRNodeWithText] = [:]
        nodesByNodeOrder.reserveCapacity(nodes.count)
        var duplicateNodeIDs: [Int] = []
        var loggedDuplicateNodeIDs: Set<Int> = []
        loggedDuplicateNodeIDs.reserveCapacity(min(nodes.count, 8))

        for node in nodes {
            if nodesByID[node.id] == nil {
                nodesByID[node.id] = node
            } else if loggedDuplicateNodeIDs.insert(node.id).inserted {
                duplicateNodeIDs.append(node.id)
            }

            if nodesByNodeOrder[node.nodeOrder] == nil {
                nodesByNodeOrder[node.nodeOrder] = node
            }
        }

        if !duplicateNodeIDs.isEmpty {
            let sampleIDs = duplicateNodeIDs.prefix(3).map(String.init).joined(separator: ", ")
            let frameIDDescription = nodes.first.map { String($0.frameId) } ?? "unknown"
            Log.warning(
                "[HyperlinkMap] Duplicate OCR node IDs for frame \(frameIDDescription); duplicates=\(duplicateNodeIDs.count); sampleIDs=[\(sampleIDs)]. Using first occurrence.",
                category: .ui
            )
        }

        var parsedMatches: [OCRHyperlinkMatch] = []
        parsedMatches.reserveCapacity(rows.count)
        var seenKeys: Set<String> = []
        seenKeys.reserveCapacity(rows.count)

        for row in rows {
            guard let resolvedNode = nodesByID[row.nodeID] ?? nodesByNodeOrder[row.nodeID] else {
                continue
            }
            let x = resolvedNode.x
            let y = resolvedNode.y
            let width = resolvedNode.width
            let height = resolvedNode.height
            guard width > 0, height > 0 else { continue }

            let nodeText = resolvedNode.text
            let highlightEndIndex = max(nodeText.count, 1)
            let key = "\(row.order)|\(row.nodeID)|\(row.url)"
            guard seenKeys.insert(key).inserted else { continue }

            parsedMatches.append(
                OCRHyperlinkMatch(
                    id: key,
                    nodeID: row.nodeID,
                    x: x,
                    y: y,
                    width: width,
                    height: height,
                    url: row.url,
                    nodeText: nodeText,
                    domText: nodeText,
                    highlightStartIndex: 0,
                    highlightEndIndex: highlightEndIndex,
                    confidence: 1.0
                )
            )
        }

        return parsedMatches
    }

    static func resolveStoredHyperlinkURL(_ storedURL: String, baseURL: String?) -> String {
        if let parsed = URL(string: storedURL),
           parsed.scheme != nil {
            return storedURL
        }

        guard let baseURL,
              let base = hostRootURL(from: baseURL),
              let resolved = URL(string: storedURL, relativeTo: base)?.absoluteURL else {
            return storedURL
        }
        return resolved.absoluteString
    }

    static func hyperlinkBrowserApplicationURL(
        for url: URL,
        browserResolver: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    ) -> URL? {
        browserResolver(url)
    }

    private static func hostRootURL(from rawURL: String) -> URL? {
        guard let parsed = URL(string: rawURL),
              var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }
        components.percentEncodedPath = "/"
        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil
        return components.url
    }
}
