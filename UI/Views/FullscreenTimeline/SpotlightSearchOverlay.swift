import SwiftUI
import Shared
import App

private let searchLog = "[SpotlightSearch]"

/// Spotlight-style search overlay that appears center-screen
/// Triggered by Cmd+F or search icon click
public struct SpotlightSearchOverlay: View {

    // MARK: - Properties

    let coordinator: AppCoordinator
    let onResultSelected: (SearchResult, String) -> Void  // Result + search query for highlighting
    let onDismiss: () -> Void

    /// External SearchViewModel that persists across overlay open/close
    /// This allows search results to be preserved when clicking on a result
    @ObservedObject private var viewModel: SearchViewModel
    @State private var isVisible = false
    @State private var resultsHeight: CGFloat = 0

    private let panelWidth: CGFloat = 900
    private let maxResultsHeight: CGFloat = 550
    private let thumbnailSize = CGSize(width: 280, height: 175)
    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    // MARK: - Initialization

    public init(
        coordinator: AppCoordinator,
        viewModel: SearchViewModel,
        onResultSelected: @escaping (SearchResult, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.viewModel = viewModel
        self.onResultSelected = onResultSelected
        self.onDismiss = onDismiss
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Backdrop - also dismisses dropdowns if open
            Color.black.opacity(isVisible ? 0.6 : 0)
                .ignoresSafeArea()
                .onTapGesture {
                    if viewModel.isDropdownOpen {
                        viewModel.closeDropdownsSignal += 1
                    } else {
                        dismissOverlay()
                    }
                }

            // Search panel
            VStack(spacing: 0) {
                searchBar

                Divider()
                    .background(Color.white.opacity(0.1))

                // Filter bar and results in a ZStack so dropdowns can overlay results
                ZStack(alignment: .top) {
                    // Results area (bottom layer)
                    VStack(spacing: 0) {
                        // Spacer for the filter bar height (chips ~40px + vertical padding 24px = ~64px)
                        Color.clear
                            .frame(height: 56)

                        if hasResults {
                            let _ = print("[SpotlightSearchOverlay] Rendering results area (zIndex=0)")
                            // Small gap before divider to maintain visual spacing below filter bar
                            Color.clear.frame(height: 4)

                            Divider()
                                .background(Color.white.opacity(0.1))

                            resultsArea
                        }
                    }
                    .zIndex(0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Dismiss dropdown when tapping on results area
                        if viewModel.isDropdownOpen {
                            viewModel.closeDropdownsSignal += 1
                        }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.onAppear {
                            print("[SpotlightSearchOverlay] Results VStack frame: \(geo.frame(in: .global))")
                        }
                    })

                    // Filter bar (top layer, dropdowns will be above results)
                    VStack(spacing: 0) {
                        let _ = print("[SpotlightSearchOverlay] Rendering filter bar (zIndex=100)")
                        SearchFilterBar(viewModel: viewModel)
                    }
                    .zIndex(100)
                    .background(GeometryReader { geo in
                        Color.clear.onAppear {
                            print("[SpotlightSearchOverlay] FilterBar VStack frame: \(geo.frame(in: .global))")
                        }
                    })
                }
                .background(GeometryReader { geo in
                    Color.clear.onAppear {
                        print("[SpotlightSearchOverlay] Inner ZStack frame: \(geo.frame(in: .global))")
                    }
                })
            }
            .frame(width: panelWidth)
            .retraceMenuContainer(addPadding: false)
            .background(GeometryReader { geo in
                Color.clear.onAppear {
                    print("[SpotlightSearchOverlay] Outer panel frame (after retraceMenuContainer): \(geo.frame(in: .global))")
                }
            })
            .scaleEffect(isVisible ? 1.0 : 0.95)
            .opacity(isVisible ? 1.0 : 0)
        }
        .onAppear {
            Log.debug("\(searchLog) Search overlay opened", category: .ui)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isVisible = true
            }
        }
        .onExitCommand {
            Log.debug("\(searchLog) Exit command received, isDropdownOpen=\(viewModel.isDropdownOpen)", category: .ui)
            // If a dropdown is open, close it instead of dismissing the entire overlay
            if viewModel.isDropdownOpen {
                viewModel.closeDropdownsSignal += 1
            } else {
                dismissOverlay()
            }
        }
        .onChange(of: viewModel.searchQuery) { newValue in
            Log.debug("\(searchLog) Query changed to: '\(newValue)'", category: .ui)
        }
        .onChange(of: viewModel.isSearching) { isSearching in
            Log.debug("\(searchLog) isSearching: \(isSearching)", category: .ui)
            // Log results when search completes
            if !isSearching {
                if let results = viewModel.results {
                    Log.info("\(searchLog) Results received: \(results.results.count) results, totalCount=\(results.totalCount), searchTime=\(results.searchTimeMs)ms", category: .ui)
                }
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.retraceTitle3)
                .foregroundColor(.white.opacity(0.5))

            SpotlightSearchField(
                text: $viewModel.searchQuery,
                onSubmit: {
                    if !viewModel.searchQuery.isEmpty {
                        Log.debug("\(searchLog) Submit pressed, triggering search", category: .ui)
                        viewModel.submitSearch()
                    }
                },
                onEscape: {
                    if viewModel.isDropdownOpen {
                        viewModel.closeDropdownsSignal += 1
                    } else {
                        dismissOverlay()
                    }
                },
                placeholder: "Search your screen history..."
            )
            .frame(height: 24)

            // Clear button when there's text
            if !viewModel.searchQuery.isEmpty && !viewModel.isSearching {
                Button(action: {
                    viewModel.searchQuery = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.retraceHeadline)
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            // Search button
            if viewModel.isSearching {
                SpinnerView(size: 20, lineWidth: 2, color: .white)
                    .frame(width: 32, height: 32)
            } else {
                Button(action: {
                    if !viewModel.searchQuery.isEmpty {
                        Log.debug("\(searchLog) Search button clicked, triggering search", category: .ui)
                        viewModel.submitSearch()
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(viewModel.searchQuery.isEmpty ? Color.white.opacity(0.2) : Color.retraceSubmitAccent)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.searchQuery.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Results Area

    private var hasResults: Bool {
        !viewModel.searchQuery.isEmpty && (viewModel.isSearching || viewModel.results != nil)
    }

    @ViewBuilder
    private var resultsArea: some View {
        if viewModel.isSearching && viewModel.results == nil {
            searchingView
                .frame(height: 150)
        } else if let results = viewModel.results {
            if results.isEmpty {
                noResultsView
                    .frame(height: 150)
            } else {
                resultsList(results.results)
            }
        }
    }

    // MARK: - Results List

    /// Filter out results where the search term only appears in a URL (not in actual content)
    private func filterURLOnlyResults(_ results: [SearchResult]) -> [SearchResult] {
        let query = viewModel.searchQuery.lowercased()
        return results.filter { result in
            // Check if the match appears in the snippet (actual content)
            let snippetContainsQuery = result.snippet.lowercased().contains(query)

            // If it's in the snippet, keep it
            if snippetContainsQuery {
                return true
            }

            // If it's NOT in the snippet, check if it's only in the URL
            // If url contains query but snippet doesn't, filter it out
            if let url = result.url, url.lowercased().contains(query) {
                Log.debug("\(searchLog) Filtering out URL-only result: '\(url)'", category: .ui)
                return false
            }

            // Also check window name for URL patterns
            if let windowName = result.windowName,
               windowName.lowercased().contains(query),
               (windowName.contains("http://") || windowName.contains("https://") || windowName.contains("www.")) {
                Log.debug("\(searchLog) Filtering out window title URL result: '\(windowName)'", category: .ui)
                return false
            }

            // Keep the result (match might be in other metadata)
            return true
        }
    }

    private func resultsList(_ results: [SearchResult]) -> some View {
        let filteredResults = filterURLOnlyResults(results)

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(Array(filteredResults.enumerated()), id: \.offset) { index, result in
                        GalleryResultCard(
                            result: result,
                            thumbnailKey: thumbnailKey(for: result),
                            thumbnailSize: thumbnailSize,
                            index: index,
                            onSelect: {
                                // Save scroll position before selecting result
                                viewModel.savedScrollPosition = CGFloat(index)
                                selectResult(result)
                            },
                            viewModel: viewModel
                        )
                        .onAppear {
                            Log.debug("\(searchLog) Result card appeared: index=\(index), frameID=\(result.frameID.stringValue), generation=\(viewModel.searchGeneration)", category: .ui)
                            loadThumbnail(for: result)
                            loadAppIcon(for: result)

                            // Infinite scroll: load more when near the end
                            if index >= filteredResults.count - 3 && viewModel.canLoadMore {
                                Task {
                                    await viewModel.loadMore()
                                }
                            }
                        }
                    }
                }
                .id(viewModel.searchGeneration)  // Force recreate entire grid when search changes
                .padding(16)

                // Loading more indicator
                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        SpinnerView(size: 16, lineWidth: 2, color: .white)
                        Text("Loading more...")
                            .font(.retraceCaption2)
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: maxResultsHeight)
            .onAppear {
                // Restore scroll position when overlay appears
                if viewModel.savedScrollPosition > 0 {
                    let targetIndex = Int(viewModel.savedScrollPosition)
                    // Scroll to the saved position with a slight delay to ensure layout is complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(targetIndex, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty States

    private var searchingView: some View {
        VStack(spacing: 12) {
            SpinnerView(size: 28, lineWidth: 3, color: .white)

            Text("Searching...")
                .font(.retraceCallout)
                .foregroundColor(.white.opacity(0.5))

            // Show slow query alert when filtering by app with "All" mode
            if viewModel.selectedAppFilters != nil && !viewModel.selectedAppFilters!.isEmpty && viewModel.searchMode == .all {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.retraceCaption2)
                    Text("\"All\" queries with app filters are slower")
                        .font(.retraceCaption2)
                }
                .foregroundColor(.yellow.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.yellow.opacity(0.15))
                )
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.retraceDisplay2)
                .foregroundColor(.white.opacity(0.3))

            Text("No results found")
                .font(.retraceBodyMedium)
                .foregroundColor(.white.opacity(0.6))

            Text("Try a different search term")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Thumbnail Loading

    private func thumbnailKey(for result: SearchResult) -> String {
        // Use committedSearchQuery (set on Enter) instead of live searchQuery
        // This prevents thumbnails from reloading while user is typing
        "\(result.segmentID.stringValue)_\(result.timestamp.timeIntervalSince1970)_\(viewModel.committedSearchQuery)"
    }

    private func loadThumbnail(for result: SearchResult) {
        let key = thumbnailKey(for: result)
        // Use committedSearchQuery for highlighting (the query that was actually searched)
        let searchQuery = viewModel.committedSearchQuery
        let currentGeneration = viewModel.searchGeneration

        guard viewModel.thumbnailCache[key] == nil, !viewModel.loadingThumbnails.contains(key) else {
            if viewModel.thumbnailCache[key] != nil {
                Log.debug("\(searchLog) Thumbnail already cached for: \(key)", category: .ui)
            }
            return
        }

        viewModel.loadingThumbnails.insert(key)
        let startTime = Date()
        Log.debug("\(searchLog) Starting highlighted thumbnail load for: segmentID=\(result.segmentID.stringValue), timestamp=\(result.timestamp), query='\(searchQuery)', generation=\(currentGeneration)", category: .ui)

        Task {
            do {
                // 1. Fetch frame image using frameIndex (more reliable than timestamp matching)
                let fetchStart = Date()
                let imageData = try await coordinator.getFrameImageByIndex(
                    videoID: result.videoID,
                    frameIndex: result.frameIndex,
                    source: result.source
                )
                let fetchDuration = Date().timeIntervalSince(fetchStart) * 1000
                Log.debug("\(searchLog) Image data fetched in \(Int(fetchDuration))ms, size=\(imageData.count) bytes, source=\(result.source)", category: .ui)

                // Check if search generation changed (user started a new search)
                guard viewModel.searchGeneration == currentGeneration else {
                    Log.debug("\(searchLog) Search generation changed (\(currentGeneration)->\(viewModel.searchGeneration)), discarding thumbnail for: \(key)", category: .ui)
                    return
                }

                guard let fullImage = NSImage(data: imageData) else {
                    Log.error("\(searchLog) Failed to create NSImage from data", category: .ui)
                    viewModel.loadingThumbnails.remove(key)
                    return
                }

                // 2. Get OCR nodes for this frame (use frameID for exact match)
                let ocrStart = Date()
                let ocrNodes = try await coordinator.getAllOCRNodes(
                    frameID: result.frameID,
                    source: result.source
                )
                let ocrDuration = Date().timeIntervalSince(ocrStart) * 1000
                Log.debug("\(searchLog) OCR nodes fetched in \(Int(ocrDuration))ms, count=\(ocrNodes.count), source=\(result.source)", category: .ui)

                // Check if search generation changed again
                guard viewModel.searchGeneration == currentGeneration else {
                    Log.debug("\(searchLog) Search generation changed (\(currentGeneration)->\(viewModel.searchGeneration)), discarding thumbnail for: \(key)", category: .ui)
                    return
                }

                // 3. Find the matching OCR node for the search query
                let matchingNode = findMatchingOCRNode(query: searchQuery, nodes: ocrNodes)

                // 4. Create the highlighted thumbnail
                let resizeStart = Date()
                let thumbnail: NSImage
                if let matchNode = matchingNode {
                    Log.debug("\(searchLog) Found matching node: '\(matchNode.text.prefix(30))...' at (\(matchNode.x), \(matchNode.y))", category: .ui)
                    thumbnail = createHighlightedThumbnail(
                        from: fullImage,
                        matchingNode: matchNode,
                        size: thumbnailSize
                    )
                } else {
                    Log.debug("\(searchLog) No matching node found, creating standard thumbnail", category: .ui)
                    thumbnail = createThumbnail(from: fullImage, size: thumbnailSize)
                }
                let resizeDuration = Date().timeIntervalSince(resizeStart) * 1000
                let totalDuration = Date().timeIntervalSince(startTime) * 1000
                Log.debug("\(searchLog) Thumbnail created: \(Int(thumbnail.size.width))x\(Int(thumbnail.size.height)), resize=\(Int(resizeDuration))ms, total=\(Int(totalDuration))ms", category: .ui)

                // Only update cache if still same generation
                if viewModel.searchGeneration == currentGeneration {
                    viewModel.thumbnailCache[key] = thumbnail
                    viewModel.loadingThumbnails.remove(key)
                }
            } catch {
                let duration = Date().timeIntervalSince(startTime) * 1000
                Log.error("\(searchLog) Failed to load thumbnail after \(Int(duration))ms: \(error.localizedDescription)", category: .ui)

                // Create a placeholder thumbnail so the UI doesn't show infinite loading
                let placeholder = createPlaceholderThumbnail(size: thumbnailSize)
                // Only update if still same generation
                if viewModel.searchGeneration == currentGeneration {
                    viewModel.thumbnailCache[key] = placeholder
                    viewModel.loadingThumbnails.remove(key)
                }
            }
        }
    }

    /// Create a placeholder thumbnail when frame extraction fails
    private func createPlaceholderThumbnail(size: CGSize) -> NSImage {
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()

        // Dark gray background
        NSColor(white: 0.15, alpha: 1.0).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Draw "unavailable" icon
        let iconSize: CGFloat = 40
        let iconRect = NSRect(
            x: (size.width - iconSize) / 2,
            y: (size.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        NSColor.white.withAlphaComponent(0.3).setStroke()
        let iconPath = NSBezierPath(ovalIn: iconRect.insetBy(dx: 5, dy: 5))
        iconPath.lineWidth = 2
        iconPath.stroke()

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

    /// Find the OCR node that best matches the search query
    /// Prioritizes exact word matches, then prefix matches (for stemmed/nominalized words)
    private func findMatchingOCRNode(query: String, nodes: [OCRNodeWithText]) -> OCRNodeWithText? {
        let lowercaseQuery = query.lowercased()

        // First pass: find exact word boundary match (e.g., "@glean" or "glean," or " glean ")
        // This is better than finding "glean" inside "gleanings"
        for node in nodes {
            let nodeText = node.text.lowercased()
            // Check if query appears as a standalone word (with word boundaries)
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: lowercaseQuery))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: nodeText, options: [], range: NSRange(nodeText.startIndex..., in: nodeText)) != nil {
                return node
            }
        }

        // Second pass: find prefix match for stemmed words (e.g., "calling" matches "call", "calls")
        // FTS5 uses porter stemmer, so "calling" -> "call" which matches "call", "calls", "called"
        // We check if any word in the node starts with a common stem of the query
        let queryStem = getWordStem(lowercaseQuery)
        if queryStem.count >= 3 {  // Only use stems of 3+ characters
            for node in nodes {
                let nodeText = node.text.lowercased()
                // Check if any word in the node starts with the query stem
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
    /// This mimics basic porter stemmer behavior for common English suffixes
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

        // OCR coordinates use top-left origin (y=0 at top), but NSImage uses bottom-left origin (y=0 at bottom)
        // We need to flip the Y coordinate: flippedY = 1.0 - y - height
        let flippedNodeY = 1.0 - matchingNode.y - matchingNode.height

        // Calculate the crop region centered on the match with padding
        // OCR coordinates are normalized (0.0-1.0), convert to pixel coordinates
        let matchCenterX = (matchingNode.x + matchingNode.width / 2) * imageSize.width
        let matchCenterY = (flippedNodeY + matchingNode.height / 2) * imageSize.height

        // Determine crop size to maintain aspect ratio of thumbnail
        // Use a zoom factor to show context around the match
        let zoomFactor: CGFloat = 3.5  // How much to zoom in (higher = more zoom)
        let cropWidth = imageSize.width / zoomFactor
        let cropHeight = cropWidth * (size.height / size.width)  // Maintain aspect ratio

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

        // Draw the cropped region of the source image
        let destRect = NSRect(origin: .zero, size: size)
        image.draw(in: destRect, from: cropRect, operation: .copy, fraction: 1.0)

        // Calculate where the highlight box should be drawn in the thumbnail
        // Convert match coordinates from image space to crop space, then to thumbnail space
        // Use the flipped Y coordinate for NSImage drawing
        let matchXInCrop = (matchingNode.x * imageSize.width - cropX) / cropWidth * size.width
        let matchYInCrop = (flippedNodeY * imageSize.height - cropY) / cropHeight * size.height
        let matchWidthInThumb = (matchingNode.width * imageSize.width) / cropWidth * size.width
        let matchHeightInThumb = (matchingNode.height * imageSize.height) / cropHeight * size.height

        // Add some padding to the highlight box
        let padding: CGFloat = 4
        let highlightRect = NSRect(
            x: matchXInCrop - padding,
            y: matchYInCrop - padding,
            width: matchWidthInThumb + padding * 2,
            height: matchHeightInThumb + padding * 2
        )

        // Draw yellow highlight box (matching the style used in SimpleTimelineView)
        // Use explicit RGB to match SwiftUI's Color.yellow exactly
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

    // MARK: - App Icon Loading

    private func loadAppIcon(for result: SearchResult) {
        guard let bundleID = result.appBundleID else { return }
        guard viewModel.appIconCache[bundleID] == nil else { return }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 20, height: 20)
            viewModel.appIconCache[bundleID] = icon
        }
    }

    // MARK: - Actions

    private func selectResult(_ result: SearchResult) {
        let query = viewModel.searchQuery
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.timeZone = .current
        Log.info("\(searchLog) Result selected: query='\(query)', frameID=\(result.frameID.stringValue), timestamp=\(df.string(from: result.timestamp)) (epoch: \(result.timestamp.timeIntervalSince1970)), segmentID=\(result.segmentID.stringValue), app=\(result.appName ?? "unknown")", category: .ui)
        dismissOverlay()

        // Small delay to allow dismiss animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Log.debug("\(searchLog) Calling onResultSelected callback with timestamp: \(df.string(from: result.timestamp))", category: .ui)
            onResultSelected(result, query)
        }
    }

    private func dismissOverlay() {
        Log.debug("\(searchLog) Dismissing overlay", category: .ui)

        // Cancel any in-flight search tasks to prevent blocking
        viewModel.cancelSearch()

        withAnimation(.easeOut(duration: 0.15)) {
            isVisible = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDismiss()
        }
    }
}

// MARK: - Gallery Result Card

private struct GalleryResultCard: View {
    let result: SearchResult
    let thumbnailKey: String
    let thumbnailSize: CGSize
    let index: Int
    let onSelect: () -> Void
    @ObservedObject var viewModel: SearchViewModel

    @State private var isHovered = false

    private var thumbnail: NSImage? {
        viewModel.thumbnailCache[thumbnailKey]
    }

    private var appIcon: NSImage? {
        viewModel.appIconCache[result.appBundleID ?? ""]
    }

    /// Display title: window name (c2) if available, otherwise app name
    private var displayTitle: String {
        if let windowName = result.windowName, !windowName.isEmpty {
            return windowName
        }
        return result.appName ?? "Unknown"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail (highlight is baked into the cropped thumbnail)
                thumbnailView

                // Title bar with app icon
                HStack(spacing: 8) {
                    // App icon
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                    } else {
                        Circle()
                            .fill(Color.segmentColor(for: result.appBundleID ?? ""))
                            .frame(width: 20, height: 20)
                    }

                    // Title and timestamp
                    VStack(alignment: .leading, spacing: 2) {
                        // Title with source badge
                        HStack(spacing: 6) {
                            Text(displayTitle)
                                .font(.retraceCaption2Medium)
                                .foregroundColor(.white)
                                .lineLimit(1)

                            // Source badge
                            Text(result.source == .native ? "Retrace" : "Rewind")
                                .font(.retraceTinyBold)
                                .foregroundColor(result.source == .native ? RetraceMenuStyle.actionBlue : .purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(result.source == .native ? RetraceMenuStyle.actionBlue.opacity(0.2) : Color.purple.opacity(0.2))
                                .cornerRadius(3)
                        }

                        // Timestamp and relevance
                        HStack(spacing: 6) {
                            Text(formatTimestamp(result.timestamp))
                                .font(.retraceTiny)
                                .foregroundColor(.white.opacity(0.5))

                            Text("•")
                                .font(.retraceTiny)
                                .foregroundColor(.white.opacity(0.3))

                            Text(String(format: "relevance: %.0f%%", result.relevanceScore * 100))
                                .font(.retraceMonoSmall)
                                .foregroundColor(.yellow.opacity(0.7))
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.3))
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? Color.white.opacity(0.3) : Color.white.opacity(0.1), lineWidth: isHovered ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 8 : 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.2).delay(Double(index) * 0.03), value: true)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            Color.black

            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipped()
            } else {
                SpinnerView(size: 16, lineWidth: 2, color: .white.opacity(0.4))
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Spotlight Search Field

/// NSViewRepresentable text field for the spotlight search overlay
/// Uses manual makeFirstResponder for reliable focus in borderless windows
struct SpotlightSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onEscape: () -> Void
    var placeholder: String = "Search your screen history..."

    func makeNSView(context: Context) -> FocusableTextField {
        let textField = FocusableTextField()
        textField.placeholderString = placeholder
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 17, weight: .medium)
            ]
        )
        textField.font = .systemFont(ofSize: 17, weight: .medium)
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.focusRingType = .none
        textField.alignment = .left
        textField.delegate = context.coordinator
        textField.drawsBackground = false
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.cell?.usesSingleLineMode = true
        textField.isEditable = true
        textField.isSelectable = true

        textField.onCancelCallback = onEscape

        // Focus the text field with retry logic for external monitors
        focusTextField(textField, attempt: 1)

        return textField
    }

    func updateNSView(_ textField: FocusableTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    private func focusTextField(_ textField: FocusableTextField, attempt: Int) {
        let maxAttempts = 5
        let delay: TimeInterval = attempt == 1 ? 0.0 : Double(attempt) * 0.05

        let schedule = {
            guard let window = textField.window else {
                if attempt < maxAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.focusTextField(textField, attempt: attempt + 1)
                    }
                }
                return
            }
            self.performFocus(textField, in: window, attempt: attempt)
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: schedule)
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    private func performFocus(_ textField: FocusableTextField, in window: NSWindow, attempt: Int) {
        let maxAttempts = 5

        // Activate the app first — required for makeKey to work on external monitors
        // where NSApp.isActive may be false when the overlay opens
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        let isKeyAfterMakeKey = window.isKeyWindow
        let success = window.makeFirstResponder(textField)

        // Ensure field editor exists for caret to appear
        if window.fieldEditor(false, for: textField) == nil {
            _ = window.fieldEditor(true, for: textField)
        }

        // If the window isn't key yet (activation is async on external monitors),
        // retry so keystrokes actually reach the text field
        if !isKeyAfterMakeKey && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(textField, attempt: attempt + 1)
            }
        } else if !success && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(textField, attempt: attempt + 1)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onEscape: onEscape)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onEscape: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onEscape: @escaping () -> Void) {
            self._text = text
            self.onSubmit = onSubmit
            self.onEscape = onEscape
        }

        func controlTextDidChange(_ notification: Notification) {
            if let textField = notification.object as? NSTextField {
                text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            }
            return false
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SpotlightSearchOverlay_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        SpotlightSearchOverlay(
            coordinator: coordinator,
            viewModel: SearchViewModel(coordinator: coordinator),
            onResultSelected: { _, _ in },
            onDismiss: {}
        )
        .frame(width: 800, height: 600)
        .background(Color.gray.opacity(0.3))
        .preferredColorScheme(.dark)
    }
}
#endif
