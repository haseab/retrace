import SwiftUI
import Shared
import App

/// A segment stack row showing representative frame with expansion capability
/// Displays thumbnail, metadata, snippet, and "+N more" badge for multi-match segments
struct SegmentStackRow: View {
    let stack: SegmentSearchStack
    let searchQuery: String
    let coordinator: AppCoordinator
    let onSelect: (SearchResult) -> Void
    let onToggle: () -> Void

    @State private var thumbnailImage: NSImage?
    @State private var isHovered = false
    @State private var isLoadingThumbnail = false

    private var result: SearchResult { stack.representativeResult }

    var body: some View {
        VStack(spacing: 0) {
            // Main row (always visible)
            mainRow

            // Expanded results (when stack.isExpanded and has multiple matches)
            if stack.isExpanded, let expandedResults = stack.expandedResults, expandedResults.count > 1 {
                expandedResultsList(expandedResults)
            }
        }
        .background(Color.retraceCard.opacity(isHovered && !stack.isExpanded ? 0.5 : 0))
        .cornerRadius(.cornerRadiusM)
        .onHover { isHovered = $0 }
    }

    // MARK: - Main Row

    private var mainRow: some View {
        HStack(spacing: .spacingM) {
            // Thumbnail with stack indicator
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .frame(width: 120, height: 90)
                    .background(Color.retraceCard)
                    .cornerRadius(.cornerRadiusM)

                // Stack indicator for multiple matches
                if stack.matchCount > 1 {
                    stackIndicator
                }
            }

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

                // Snippet
                snippetView

                // Window name
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

            // Right side: match count badge + chevron
            VStack(alignment: .trailing, spacing: .spacingS) {
                if stack.matchCount > 1 {
                    matchCountBadge
                }

                // Chevron for expandable stacks, or right arrow for single results
                if stack.matchCount > 1 {
                    Image(systemName: stack.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.retraceCallout)
                        .foregroundColor(.retraceSecondary)
                        .opacity(isHovered ? 1 : 0.5)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.retraceCallout)
                        .foregroundColor(.retraceSecondary)
                        .opacity(isHovered ? 1 : 0.5)
                }
            }
        }
        .padding(.spacingM)
        .contentShape(Rectangle())
        .onTapGesture {
            if stack.matchCount > 1 {
                onToggle()
            } else {
                onSelect(result)
            }
        }
        .task {
            await loadThumbnail()
        }
    }

    // MARK: - Stack Indicator

    private var stackIndicator: some View {
        // Visual stack effect (layered cards behind thumbnail)
        ZStack {
            // Shadow layers to create depth
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.retraceCard.opacity(0.6))
                .frame(width: 110, height: 80)
                .offset(x: 4, y: 4)

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.retraceCard.opacity(0.3))
                .frame(width: 100, height: 70)
                .offset(x: 8, y: 8)
        }
        .offset(x: -55, y: -40)  // Position behind thumbnail
        .allowsHitTesting(false)
    }

    // MARK: - Match Count Badge

    private var matchCountBadge: some View {
        Text("+\(stack.matchCount - 1) more")
            .font(.retraceCaption2)
            .fontWeight(.medium)
            .foregroundColor(.retraceAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.retraceAccent.opacity(0.15))
            .cornerRadius(12)
    }

    // MARK: - Expanded Results

    @ViewBuilder
    private func expandedResultsList(_ results: [SearchResult]) -> some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.leading, 140) // Align with content after thumbnail

            // Show all results except the representative (which is already shown)
            ForEach(results.filter { $0.frameID != stack.representativeResult.frameID }, id: \.frameID) { expandedResult in
                ExpandedResultRow(
                    result: expandedResult,
                    searchQuery: searchQuery
                ) {
                    onSelect(expandedResult)
                }
            }
        }
        .background(Color.retraceSecondaryBackground.opacity(0.5))
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
        let query = searchQuery.lowercased().replacingOccurrences(of: "\"", with: "")
        let snippet = result.snippet.lowercased()

        var searchRange = snippet.startIndex..<snippet.endIndex

        while let range = snippet.range(of: query, options: [], range: searchRange) {
            if let attributedRange = Range(range, in: attributed) {
                attributed[attributedRange].backgroundColor = Color.retraceMatchHighlight
                attributed[attributedRange].foregroundColor = Color.retracePrimary
                attributed[attributedRange].font = .retraceBodyBold
            }
            searchRange = range.upperBound..<snippet.endIndex
        }

        // Set default color for non-highlighted text
        attributed.foregroundColor = .retraceSecondary

        return attributed
    }

    // MARK: - Helpers

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail() async {
        guard !isLoadingThumbnail else { return }
        isLoadingThumbnail = true

        do {
            // Fetch frame image using frameIndex
            let imageData = try await coordinator.getFrameImageByIndex(
                videoID: result.videoID,
                frameIndex: result.frameIndex,
                source: result.source == .native ? .native : .rewind
            )

            guard let fullImage = NSImage(data: imageData) else {
                isLoadingThumbnail = false
                return
            }

            // Get OCR nodes for highlighting
            let ocrNodes = try await coordinator.getAllOCRNodes(
                frameID: result.frameID,
                source: result.source == .native ? .native : .rewind
            )

            // Find matching node and create thumbnail
            let thumbnailSize = CGSize(width: 120, height: 90)
            let matchingNode = findMatchingOCRNode(query: searchQuery, nodes: ocrNodes)

            if let matchNode = matchingNode {
                thumbnailImage = createHighlightedThumbnail(
                    from: fullImage,
                    matchingNode: matchNode,
                    size: thumbnailSize
                )
            } else {
                thumbnailImage = createThumbnail(from: fullImage, size: thumbnailSize)
            }

            isLoadingThumbnail = false
        } catch {
            Log.error("[SegmentStackRow] Failed to load thumbnail: \(error.localizedDescription)", category: .ui)
            thumbnailImage = createPlaceholderThumbnail(size: CGSize(width: 120, height: 90))
            isLoadingThumbnail = false
        }
    }

    // MARK: - Thumbnail Helpers (same as ResultRow)

    private func findMatchingOCRNode(query: String, nodes: [OCRNodeWithText]) -> OCRNodeWithText? {
        let cleanedQuery = query.lowercased().replacingOccurrences(of: "\"", with: "")
        let queryTerms = cleanedQuery.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        // First pass: exact word match
        for node in nodes {
            let nodeText = node.text.lowercased()
            for term in queryTerms {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: term))\\b"
                if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                   regex.firstMatch(in: nodeText, options: [], range: NSRange(nodeText.startIndex..., in: nodeText)) != nil {
                    return node
                }
            }
        }

        // Second pass: substring match
        for node in nodes {
            let nodeText = node.text.lowercased()
            for term in queryTerms {
                if nodeText.contains(term) {
                    return node
                }
            }
        }

        return nil
    }

    private func createHighlightedThumbnail(from image: NSImage, matchingNode: OCRNodeWithText, size: CGSize) -> NSImage {
        let imageSize = image.size
        let flippedNodeY = 1.0 - matchingNode.y - matchingNode.height

        let matchCenterX = (matchingNode.x + matchingNode.width / 2) * imageSize.width
        let matchCenterY = (flippedNodeY + matchingNode.height / 2) * imageSize.height

        let zoomFactor: CGFloat = 3.5
        let cropWidth = imageSize.width / zoomFactor
        let cropHeight = cropWidth * (size.height / size.width)

        var cropX = matchCenterX - cropWidth / 2
        var cropY = matchCenterY - cropHeight / 2

        cropX = max(0, min(cropX, imageSize.width - cropWidth))
        cropY = max(0, min(cropY, imageSize.height - cropHeight))

        let cropRect = NSRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)

        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()

        let destRect = NSRect(origin: .zero, size: size)
        image.draw(in: destRect, from: cropRect, operation: .copy, fraction: 1.0)

        let matchXInCrop = (matchingNode.x * imageSize.width - cropX) / cropWidth * size.width
        let matchYInCrop = (flippedNodeY * imageSize.height - cropY) / cropHeight * size.height
        let matchWidthInThumb = (matchingNode.width * imageSize.width) / cropWidth * size.width
        let matchHeightInThumb = (matchingNode.height * imageSize.height) / cropHeight * size.height

        let padding: CGFloat = 4
        let highlightRect = NSRect(
            x: matchXInCrop - padding,
            y: matchYInCrop - padding,
            width: matchWidthInThumb + padding * 2,
            height: matchHeightInThumb + padding * 2
        )

        let highlightColor = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.9)
        let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: 3, yRadius: 3)
        highlightColor.setStroke()
        highlightPath.lineWidth = 2
        highlightPath.stroke()

        thumbnail.unlockFocus()
        return thumbnail
    }

    private func createThumbnail(from image: NSImage, size: CGSize) -> NSImage {
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()

        let sourceRect = NSRect(origin: .zero, size: image.size)
        let destRect = NSRect(origin: .zero, size: size)
        image.draw(in: destRect, from: sourceRect, operation: .copy, fraction: 1.0)

        thumbnail.unlockFocus()
        return thumbnail
    }

    private func createPlaceholderThumbnail(size: CGSize) -> NSImage {
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()

        NSColor.darkGray.setFill()
        NSRect(origin: .zero, size: size).fill()

        let iconSize: CGFloat = 40
        let iconRect = NSRect(
            x: (size.width - iconSize) / 2,
            y: (size.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        NSColor.lightGray.setStroke()
        let circlePath = NSBezierPath(ovalIn: iconRect)
        circlePath.lineWidth = 2
        circlePath.stroke()

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
struct SegmentStackRow_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()

        VStack(spacing: .spacingM) {
            // Single match stack
            SegmentStackRow(
                stack: SegmentSearchStack(
                    segmentID: AppSegmentID(value: 1),
                    representativeResult: SearchResult(
                        id: FrameID(value: 1),
                        timestamp: Date(),
                        snippet: "Error: Cannot read property 'user' of undefined",
                        matchedText: "error",
                        relevanceScore: 0.95,
                        metadata: FrameMetadata(
                            appBundleID: "com.google.Chrome",
                            appName: "Chrome",
                            windowName: "GitHub - retrace/main",
                            browserURL: nil,
                            displayID: 0
                        ),
                        segmentID: AppSegmentID(value: 1),
                        frameIndex: 0
                    ),
                    matchCount: 1
                ),
                searchQuery: "error",
                coordinator: coordinator,
                onSelect: { _ in },
                onToggle: {}
            )

            // Multi-match stack
            SegmentStackRow(
                stack: SegmentSearchStack(
                    segmentID: AppSegmentID(value: 2),
                    representativeResult: SearchResult(
                        id: FrameID(value: 2),
                        timestamp: Date().addingTimeInterval(-300),
                        snippet: "TODO: Fix error handling in authentication flow",
                        matchedText: "error",
                        relevanceScore: 0.85,
                        metadata: FrameMetadata(
                            appBundleID: "com.apple.dt.Xcode",
                            appName: "Xcode",
                            windowName: "AppDelegate.swift",
                            browserURL: nil,
                            displayID: 0
                        ),
                        segmentID: AppSegmentID(value: 2),
                        frameIndex: 5
                    ),
                    matchCount: 4
                ),
                searchQuery: "error",
                coordinator: coordinator,
                onSelect: { _ in },
                onToggle: {}
            )
        }
        .padding()
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
