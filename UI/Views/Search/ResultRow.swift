import SwiftUI
import Shared
import App

/// Individual search result row showing frame preview and matched text
public struct ResultRow: View {

    // MARK: - Properties

    let result: SearchResult
    let searchQuery: String
    let coordinator: AppCoordinator
    let onTap: () -> Void

    @State private var thumbnailImage: NSImage?
    @State private var isHovered = false
    @State private var isLoadingThumbnail = false

    // MARK: - Body

    public var body: some View {
        HStack(spacing: .spacingM) {
            // Thumbnail
            thumbnail
                .frame(width: 120, height: 90)
                .background(Color.retraceCard)
                .cornerRadius(.cornerRadiusM)

            // Content
            VStack(alignment: .leading, spacing: .spacingS) {
                // App and timestamp header
                HStack(spacing: .spacingS) {
                    if let appName = result.appName {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.segmentColor(for: result.appBundleID ?? ""))
                                .frame(width: 8, height: 8)

                            Text(appName)
                                .font(.retraceCallout)
                                .fontWeight(.semibold)
                                .foregroundColor(.retracePrimary)
                        }
                    }

                    Text("•")
                        .foregroundColor(.retraceSecondary)

                    Text(formatTimestamp(result.timestamp))
                        .font(.retraceCallout)
                        .foregroundColor(.retraceSecondary)

                    Text("•")
                        .foregroundColor(.retraceSecondary)

                    // Source badge
                    Text(result.source == .native ? "Retrace" : "Rewind")
                        .font(.retraceCaption2)
                        .fontWeight(.medium)
                        .foregroundColor(result.source == .native ? RetraceMenuStyle.actionBlue : .purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(result.source == .native ? RetraceMenuStyle.actionBlue.opacity(0.15) : Color.purple.opacity(0.15))
                        .cornerRadius(4)

                    Spacer()

                    // Relevance score
                    if result.relevanceScore > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.retraceTiny)
                            Text(String(format: "%.0f%%", result.relevanceScore * 100))
                                .font(.retraceCaption2)
                        }
                        .foregroundStyle(LinearGradient.retraceAccentGradient)
                    }
                }

                // Snippet with highlights
                snippetView

                // Metadata (if available)
                if let windowName = result.windowName, !windowName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.retraceTiny)
                            .foregroundColor(.retraceSecondary)

                        Text(windowName)
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Chevron
            Image(systemName: "chevron.right")
                .font(.retraceCallout)
                .foregroundColor(.retraceSecondary)
                .opacity(isHovered ? 1 : 0.5)
        }
        .padding(.spacingM)
        .background(isHovered ? Color.retraceHover : Color.clear)
        .cornerRadius(.cornerRadiusM)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button("Open Frame") {
                onTap()
            }

            Button("Copy Link") {
                copyShareLink()
            }

            Divider()

            if let url = result.url {
                Button("Open URL") {
                    NSWorkspace.shared.open(URL(string: url)!)
                }
            }
        }
        .task {
            await loadThumbnail()
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        if let image = thumbnailImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 90)
                .clipped()
        } else {
            ZStack {
                Rectangle()
                    .fill(Color.retraceCard)

                SpinnerView(size: 16, lineWidth: 2)
            }
        }
    }

    // MARK: - Snippet

    private var snippetView: some View {
        Text(highlightedSnippet)
            .font(.retraceBody)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var highlightedSnippet: AttributedString {
        var attributed = AttributedString(result.snippet)

        // Highlight search query matches
        let query = searchQuery.lowercased()
        let snippet = result.snippet.lowercased()

        var searchRange = snippet.startIndex..<snippet.endIndex

        while let range = snippet.range(of: query, options: [], range: searchRange) {
            let attributedRange = Range(range, in: attributed)!

            attributed[attributedRange].backgroundColor = Color.retraceMatchHighlight
            attributed[attributedRange].foregroundColor = Color.retracePrimary
            attributed[attributedRange].font = .retraceBodyBold

            searchRange = range.upperBound..<snippet.endIndex
        }

        // Set default color for non-highlighted text
        attributed.foregroundColor = .retraceSecondary

        return attributed
    }

    // MARK: - Helpers

    private func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Today " + formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Yesterday " + formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    }

    private func copyShareLink() {
        let url = DeeplinkHandler.generateSearchLink(
            query: searchQuery,
            timestamp: result.timestamp,
            appBundleID: result.appBundleID
        )

        if let url = url {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
        }
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail() async {
        guard !isLoadingThumbnail else { return }
        isLoadingThumbnail = true

        let startTime = Date()
        Log.debug("[ResultRow] Starting thumbnail load: frameID=\(result.frameID.stringValue), videoID=\(result.videoID.stringValue), frameIndex=\(result.frameIndex), query='\(searchQuery)', source=\(result.source)", category: .ui)

        do {
            // 1. Fetch frame image using frameIndex (more reliable than timestamp matching)
            let fetchStart = Date()
            let imageData = try await coordinator.getFrameImageByIndex(
                videoID: result.videoID,
                frameIndex: result.frameIndex,
                source: result.source == .native ? .native : .rewind
            )
            let fetchDuration = Date().timeIntervalSince(fetchStart) * 1000
            Log.debug("[ResultRow] Frame image fetched: videoID=\(result.videoID.stringValue), frameIndex=\(result.frameIndex), size=\(imageData.count) bytes, time=\(Int(fetchDuration))ms", category: .ui)

            guard let fullImage = NSImage(data: imageData) else {
                Log.error("[ResultRow] Failed to create NSImage from data", category: .ui)
                isLoadingThumbnail = false
                return
            }

            // 2. Get OCR nodes for this frame (use frameID for exact match)
            let ocrStart = Date()
            let ocrNodes = try await coordinator.getAllOCRNodes(
                frameID: result.frameID,
                source: result.source == .native ? .native : .rewind
            )
            let ocrDuration = Date().timeIntervalSince(ocrStart) * 1000
            Log.debug("[ResultRow] OCR nodes fetched in \(Int(ocrDuration))ms, count=\(ocrNodes.count)", category: .ui)

            // 3. Find the matching OCR node for the search query
            Log.debug("[ResultRow] Searching for query='\(searchQuery)' in \(ocrNodes.count) OCR nodes", category: .ui)
            Log.debug("[ResultRow] First 3 OCR nodes: \(ocrNodes.prefix(3).map { $0.text.prefix(50) })", category: .ui)
            let matchingNode = findMatchingOCRNode(query: searchQuery, nodes: ocrNodes)

            // 4. Create the highlighted thumbnail
            let thumbnailSize = CGSize(width: 120, height: 90)
            let resizeStart = Date()
            let thumbnail: NSImage
            if let matchNode = matchingNode {
                Log.debug("[ResultRow] Found matching node: '\(matchNode.text.prefix(30))...' at (\(matchNode.x), \(matchNode.y))", category: .ui)
                thumbnail = createHighlightedThumbnail(
                    from: fullImage,
                    matchingNode: matchNode,
                    size: thumbnailSize
                )
            } else {
                Log.debug("[ResultRow] No matching node found, creating standard thumbnail", category: .ui)
                thumbnail = createThumbnail(from: fullImage, size: thumbnailSize)
            }
            let resizeDuration = Date().timeIntervalSince(resizeStart) * 1000
            let totalDuration = Date().timeIntervalSince(startTime) * 1000
            Log.debug("[ResultRow] Thumbnail created: \(Int(thumbnail.size.width))x\(Int(thumbnail.size.height)), resize=\(Int(resizeDuration))ms, total=\(Int(totalDuration))ms", category: .ui)

            thumbnailImage = thumbnail
            isLoadingThumbnail = false
        } catch {
            let duration = Date().timeIntervalSince(startTime) * 1000
            Log.error("[ResultRow] Failed to load thumbnail after \(Int(duration))ms: \(error.localizedDescription)", category: .ui)

            // Create a placeholder thumbnail on error
            let placeholderSize = CGSize(width: 120, height: 90)
            thumbnailImage = createPlaceholderThumbnail(size: placeholderSize)
            isLoadingThumbnail = false
        }
    }

    // MARK: - Thumbnail Creation Helpers

    /// Find the OCR node that best matches the search query
    private func findMatchingOCRNode(query: String, nodes: [OCRNodeWithText]) -> OCRNodeWithText? {
        let lowercaseQuery = query.lowercased()

        // First pass: find exact word boundary match
        for node in nodes {
            let nodeText = node.text.lowercased()
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: lowercaseQuery))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: nodeText, options: [], range: NSRange(nodeText.startIndex..., in: nodeText)) != nil {
                return node
            }
        }

        // Second pass: find prefix match for stemmed words
        let queryStem = getWordStem(lowercaseQuery)
        if queryStem.count >= 3 {
            for node in nodes {
                let nodeText = node.text.lowercased()
                let words = nodeText.components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
                for word in words {
                    if word.hasPrefix(queryStem) || queryStem.hasPrefix(word) {
                        return node
                    }
                }
            }
        }

        // Third pass: find any substring match as fallback
        for node in nodes {
            if node.text.lowercased().contains(lowercaseQuery) {
                return node
            }
        }

        return nil
    }

    /// Get a simple word stem by removing common suffixes
    private func getWordStem(_ word: String) -> String {
        let suffixes = ["ing", "ed", "er", "est", "ly", "tion", "sion", "ness", "ment", "able", "ible", "ful", "less", "ous", "ive", "al", "s"]
        var stem = word
        for suffix in suffixes {
            if stem.hasSuffix(suffix) && stem.count > suffix.count + 2 {
                stem = String(stem.dropLast(suffix.count))
                break
            }
        }
        return stem
    }

    /// Create a thumbnail cropped around the matching OCR node with a yellow highlight
    private func createHighlightedThumbnail(
        from image: NSImage,
        matchingNode: OCRNodeWithText,
        size: CGSize
    ) -> NSImage {
        let imageSize = image.size

        // OCR coordinates use top-left origin, NSImage uses bottom-left origin
        let flippedNodeY = 1.0 - matchingNode.y - matchingNode.height

        // Calculate the crop region centered on the match with padding
        let matchCenterX = (matchingNode.x + matchingNode.width / 2) * imageSize.width
        let matchCenterY = (flippedNodeY + matchingNode.height / 2) * imageSize.height

        // Determine crop size to maintain aspect ratio
        let zoomFactor: CGFloat = 3.5  // How much to zoom in
        let cropWidth = imageSize.width / zoomFactor
        let cropHeight = cropWidth * (size.height / size.width)

        // Calculate crop origin, ensuring we stay within bounds
        var cropX = matchCenterX - cropWidth / 2
        var cropY = matchCenterY - cropHeight / 2

        // Clamp to image bounds
        cropX = max(0, min(cropX, imageSize.width - cropWidth))
        cropY = max(0, min(cropY, imageSize.height - cropHeight))

        let cropRect = NSRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)

        // Create the thumbnail
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()

        // Draw the cropped region
        let destRect = NSRect(origin: .zero, size: size)
        image.draw(in: destRect, from: cropRect, operation: .copy, fraction: 1.0)

        // Calculate highlight box position in thumbnail space
        let matchXInCrop = (matchingNode.x * imageSize.width - cropX) / cropWidth * size.width
        let matchYInCrop = (flippedNodeY * imageSize.height - cropY) / cropHeight * size.height
        let matchWidthInThumb = (matchingNode.width * imageSize.width) / cropWidth * size.width
        let matchHeightInThumb = (matchingNode.height * imageSize.height) / cropHeight * size.height

        // Add padding to the highlight box
        let padding: CGFloat = 4
        let highlightRect = NSRect(
            x: matchXInCrop - padding,
            y: matchYInCrop - padding,
            width: matchWidthInThumb + padding * 2,
            height: matchHeightInThumb + padding * 2
        )

        // Draw yellow highlight box
        let highlightColor = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.9)
        let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: 3, yRadius: 3)
        highlightColor.setStroke()
        highlightPath.lineWidth = 2
        highlightPath.stroke()

        thumbnail.unlockFocus()
        return thumbnail
    }

    /// Create a standard thumbnail without highlighting
    private func createThumbnail(from image: NSImage, size: CGSize) -> NSImage {
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()

        let sourceRect = NSRect(origin: .zero, size: image.size)
        let destRect = NSRect(origin: .zero, size: size)

        image.draw(in: destRect, from: sourceRect, operation: .copy, fraction: 1.0)

        thumbnail.unlockFocus()
        return thumbnail
    }

    /// Create a placeholder thumbnail when frame extraction fails
    private func createPlaceholderThumbnail(size: CGSize) -> NSImage {
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()

        // Gray background
        NSColor.darkGray.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Draw error icon
        let iconSize: CGFloat = 40
        let iconRect = NSRect(
            x: (size.width - iconSize) / 2,
            y: (size.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        NSColor.lightGray.setFill()
        NSColor.lightGray.setStroke()

        // Draw circle
        let circlePath = NSBezierPath(ovalIn: iconRect)
        circlePath.lineWidth = 2
        circlePath.stroke()

        // Draw X through circle
        let xPath = NSBezierPath()
        xPath.move(to: NSPoint(x: iconRect.minX + 10, y: iconRect.minY + 10))
        xPath.line(to: NSPoint(x: iconRect.maxX - 10, y: iconRect.maxY - 10))
        xPath.move(to: NSPoint(x: iconRect.maxX - 10, y: iconRect.minY + 10))
        xPath.line(to: NSPoint(x: iconRect.minX + 10, y: iconRect.maxY - 10))
        xPath.lineWidth = 2
        xPath.stroke()

        thumbnail.unlockFocus()
        return thumbnail
    }
}

// MARK: - Preview

#if DEBUG
struct ResultRow_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()

        VStack(spacing: .spacingM) {
            ResultRow(
                result: SearchResult(
                    id: FrameID(value: 1),
                    timestamp: Date(),
                    snippet: "Error: Cannot read property 'user' of undefined at line 42",
                    matchedText: "error",
                    relevanceScore: 0.95,
                    metadata: FrameMetadata(
                        appBundleID: "com.google.Chrome",
                        appName: "Chrome",
                        windowName: "GitHub - retrace/main",
                        browserURL: "https://github.com",
                        displayID: 0
                    ),
                    segmentID: AppSegmentID(value: 1),
                    frameIndex: 0
                ),
                searchQuery: "error",
                coordinator: coordinator
            ) {}

            ResultRow(
                result: SearchResult(
                    id: FrameID(value: 1),
                    timestamp: Date().addingTimeInterval(-86400),
                    snippet: "TODO: Fix error handling in the authentication flow",
                    matchedText: "error",
                    relevanceScore: 0.78,
                    metadata: FrameMetadata(
                        appBundleID: "com.apple.dt.Xcode",
                        appName: "Xcode",
                        windowName: "AppDelegate.swift",
                        browserURL: nil,
                        displayID: 0
                    ),
                    segmentID: AppSegmentID(value: 1),
                    frameIndex: 10
                ),
                searchQuery: "error",
                coordinator: coordinator
            ) {}

            ResultRow(
                result: SearchResult(
                    id: FrameID(value: 1),
                    timestamp: Date().addingTimeInterval(-172800),
                    snippet: "Login successful. User authenticated with token abc123...",
                    matchedText: "login",
                    relevanceScore: 0.62,
                    metadata: FrameMetadata(
                        appBundleID: "com.apple.Terminal",
                        appName: "Terminal",
                        windowName: nil,
                        browserURL: nil,
                        displayID: 0
                    ),
                    segmentID: AppSegmentID(value: 1),
                    frameIndex: 5
                ),
                searchQuery: "login",
                coordinator: coordinator
            ) {}
        }
        .padding()
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
