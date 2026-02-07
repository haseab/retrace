import SwiftUI
import Shared
import App
import AppKit

private let searchLog = "[SpotlightSearch]"

/// Debug logging to file
private func debugLog(_ message: String) {
    let line = "[\(Log.timestamp())] \(message)\n"
    let path = "/tmp/retrace_debug.log"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

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
    @State private var isExpanded = false  // Whether to show filters and results (expanded view)
    @State private var refocusSearchField: UUID = UUID()  // Trigger to refocus search field
    @State private var keyboardSelectedResultIndex: Int?
    @State private var isResultKeyboardNavigationActive = false
    @State private var shouldFocusFirstResultAfterSubmit = false
    @State private var keyEventMonitor: Any?

    private let panelWidth: CGFloat = 900
    private let collapsedWidth: CGFloat = 400
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
            // Only show backdrop when expanded
            if isExpanded {
                Color.black.opacity(isVisible ? 0.6 : 0)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if viewModel.isDropdownOpen {
                            viewModel.closeDropdownsSignal += 1
                        } else {
                            dismissOverlay()
                        }
                    }
            }

            // Search panel - use ZStack to allow dropdowns to escape clipping
            ZStack(alignment: .top) {
                // Main panel content (clipped)
                VStack(spacing: 0) {
                    searchBar

                    // Only show filter bar and results when expanded
                    if isExpanded {
                        Divider()
                            .background(Color.white.opacity(0.1))

                        // Filter bar placeholder + results
                        VStack(spacing: 0) {
                            // Spacer for the filter bar height (chips ~40px + vertical padding 24px = ~64px)
                            Color.clear
                                .frame(height: 56)
                                .allowsHitTesting(false)

                            if hasResults {
                                // Small gap before divider to maintain visual spacing below filter bar
                                Color.clear.frame(height: 4)

                                Divider()
                                    .background(Color.white.opacity(0.1))

                                resultsArea
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // Dismiss dropdown when tapping on results area
                                        if viewModel.isDropdownOpen {
                                            viewModel.closeDropdownsSignal += 1
                                        }
                                    }
                            }
                        }
                    }
                }
                .frame(width: isExpanded ? panelWidth : collapsedWidth)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.4))
                        .background(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)

                // Filter bar overlay (NOT clipped, so dropdowns can extend beyond panel)
                if isExpanded {
                    VStack(spacing: 0) {
                        // Offset to position below search bar + divider
                        Color.clear.frame(height: 57) // searchBar height (~56px) + divider (1px)
                        SearchFilterBar(viewModel: viewModel)
                    }
                    .frame(width: panelWidth)
                }
            }
            .scaleEffect(isVisible ? 1.0 : 0.95)
            .opacity(isVisible ? 1.0 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
        }
        .onAppear {
            Log.debug("\(searchLog) Search overlay opened", category: .ui)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isVisible = true
                // If there are existing results, expand to show them
                if viewModel.results != nil && !viewModel.searchQuery.isEmpty {
                    isExpanded = true
                }
            }
            installKeyEventMonitor()
        }
        .onDisappear {
            removeKeyEventMonitor()
            clearResultKeyboardNavigation()
        }
        .onExitCommand {
            Log.debug("\(searchLog) Exit command received, isDropdownOpen=\(viewModel.isDropdownOpen), searchQuery='\(viewModel.searchQuery)'", category: .ui)
            // If a dropdown is open, close it instead of dismissing the entire overlay
            if viewModel.isDropdownOpen {
                viewModel.closeDropdownsSignal += 1
            } else {
                // Always dismiss the overlay on Escape (clearing happens in dismissOverlay)
                dismissOverlay()
            }
        }
        .onChange(of: viewModel.searchQuery) { newValue in
            Log.debug("\(searchLog) Query changed to: '\(newValue)'", category: .ui)
            if newValue != viewModel.committedSearchQuery {
                clearResultKeyboardNavigation()
            }
        }
        .onChange(of: viewModel.isSearching) { isSearching in
            Log.debug("\(searchLog) isSearching: \(isSearching)", category: .ui)
            // Log results when search completes
            if !isSearching {
                if let results = viewModel.results {
                    Log.info("\(searchLog) Results received: \(results.results.count) results, totalCount=\(results.totalCount), searchTime=\(results.searchTimeMs)ms", category: .ui)
                }
                if shouldFocusFirstResultAfterSubmit {
                    focusFirstResultIfAvailable()
                }
            }
        }
        .onChange(of: viewModel.results?.results.count ?? 0) { _ in
            syncKeyboardSelectionWithCurrentResults()
        }
        .onChange(of: viewModel.openFilterSignal.id) { _ in
            // When Tab cycles back to search field (index 0), trigger refocus
            if viewModel.openFilterSignal.index == 0 {
                Log.debug("\(searchLog) Tab navigation returned to search field, triggering refocus", category: .ui)
                refocusSearchField = UUID()
            }
        }
        .onChange(of: viewModel.isDropdownOpen) { isOpen in
            // When a dropdown closes (Escape or Enter selection), refocus the search field
            if !isOpen {
                refocusSearchField = UUID()
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
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded = true
                        }
                        prepareResultKeyboardNavigationAfterSubmit()
                        viewModel.submitSearch()
                    }
                },
                onEscape: {
                    if viewModel.isDropdownOpen {
                        viewModel.closeDropdownsSignal += 1
                    } else {
                        // Always dismiss the overlay on Escape (clearing happens in dismissOverlay)
                        dismissOverlay()
                    }
                },
                onTab: {
                    // Tab from search field opens Apps filter (first filter)
                    Log.debug("\(searchLog) Tab pressed, opening Apps filter", category: .ui)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded = true
                    }
                    // Signal to open Apps filter (index 1)
                    viewModel.openFilterSignal = (1, UUID())
                },
                onFocus: {
                    clearResultKeyboardNavigation()
                    // Close any open dropdowns when search field gains focus
                    if viewModel.isDropdownOpen {
                        viewModel.closeDropdownsSignal += 1
                    }
                },
                placeholder: "Search your screen history...",
                refocusTrigger: refocusSearchField
            )
            .frame(height: 24)

            // Loading spinner (shown while searching)
            if viewModel.isSearching {
                SpinnerView(size: 20, lineWidth: 2, color: .white)
                    .frame(width: 32, height: 32)
            }

            // Filter button (expands to show filters)
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded = true
                }
            }) {
                ZStack {
                    Circle()
                        .fill(isExpanded || viewModel.hasActiveFilters ? Color.white.opacity(0.2) : Color.white.opacity(0.1))
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isExpanded || viewModel.hasActiveFilters ? .white : .white.opacity(0.6))
                }
                .frame(width: 24, height: 24)
                .overlay(alignment: .topTrailing) {
                    if viewModel.activeFilterCount > 0 {
                        Text("\(viewModel.activeFilterCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 14, height: 14)
                            .background(Color.red)
                            .clipShape(Circle())
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)

            // Close button
            Button(action: {
                dismissOverlay()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
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
                            isKeyboardSelected: isResultKeyboardNavigationActive && keyboardSelectedResultIndex == index,
                            onSelect: {
                                // Save scroll position before selecting result
                                viewModel.savedScrollPosition = CGFloat(index)
                                keyboardSelectedResultIndex = index
                                isResultKeyboardNavigationActive = true
                                selectResult(result)
                            },
                            viewModel: viewModel
                        )
                        .id(index)
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
            .onChange(of: keyboardSelectedResultIndex) { selectedIndex in
                guard let selectedIndex else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(selectedIndex)
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
                Log.error("\(searchLog) ❌ THUMBNAIL FAILED after \(Int(duration))ms: \(error)", category: .ui)
                Log.error("\(searchLog) ❌ Details: videoID=\(result.videoID), frameIndex=\(result.frameIndex), source=\(result.source)", category: .ui)

                // Write to debug log file
                let logMessage = "[\(Log.timestamp())] ❌ THUMBNAIL FAILED: \(error)\n  videoID=\(result.videoID), frameID=\(result.frameID), frameIndex=\(result.frameIndex), source=\(result.source)\n"
                if let data = logMessage.data(using: .utf8) {
                    let logPath = "/tmp/retrace_debug.log"
                    if !FileManager.default.fileExists(atPath: logPath) {
                        FileManager.default.createFile(atPath: logPath, contents: nil)
                    }
                    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                }

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
    /// Handles both exact phrase matching (quoted queries) and individual term matching
    private func findMatchingOCRNode(query: String, nodes: [OCRNodeWithText]) -> OCRNodeWithText? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)

        // Check if this is an exact phrase search (wrapped in quotes)
        let isExactPhraseSearch = trimmedQuery.hasPrefix("\"") && trimmedQuery.hasSuffix("\"") && trimmedQuery.count > 2

        if isExactPhraseSearch {
            // Extract phrase without quotes and search for exact consecutive match
            let phrase = String(trimmedQuery.dropFirst().dropLast()).lowercased()

            // Only match if the exact phrase appears in the node
            for node in nodes {
                if node.text.lowercased().contains(phrase) {
                    return node
                }
            }

            // No fallback for exact phrase search - return nil if not found
            return nil
        }

        // Non-quoted search: split into terms and search for any term
        let queryTerms = trimmedQuery.lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        // First pass: find node containing any query term as exact word
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

        // Second pass: find any substring match as fallback
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

        // Dismiss overlay WITHOUT clearing search state - user selected a result
        dismissOverlayPreservingSearch()

        // Small delay to allow dismiss animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Log.debug("\(searchLog) Calling onResultSelected callback with timestamp: \(df.string(from: result.timestamp))", category: .ui)
            onResultSelected(result, query)
        }
    }

    /// Dismisses the overlay without clearing search state (used when selecting a result)
    private func dismissOverlayPreservingSearch() {
        Log.debug("\(searchLog) Dismissing overlay (preserving search state)", category: .ui)

        withAnimation(.easeOut(duration: 0.15)) {
            isVisible = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDismiss()
        }
    }

    /// Dismisses the overlay and clears search state (used for explicit dismissal like Escape key)
    private func dismissOverlay() {
        Log.debug("\(searchLog) Dismissing overlay", category: .ui)

        // Cancel any in-flight search tasks to prevent blocking
        viewModel.cancelSearch()
        clearResultKeyboardNavigation()

        // Clear search query and filters when dismissing
        viewModel.searchQuery = ""
        viewModel.clearAllFilters()

        withAnimation(.easeOut(duration: 0.15)) {
            isVisible = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDismiss()
        }
    }

    // MARK: - Keyboard Navigation

    private var keyboardNavigableResults: [SearchResult] {
        guard let results = viewModel.results else { return [] }
        return filterURLOnlyResults(results.results)
    }

    private func prepareResultKeyboardNavigationAfterSubmit() {
        shouldFocusFirstResultAfterSubmit = true
        isResultKeyboardNavigationActive = true
        keyboardSelectedResultIndex = nil
        resignSearchFieldFocus()
    }

    private func focusFirstResultIfAvailable() {
        let results = keyboardNavigableResults
        shouldFocusFirstResultAfterSubmit = false

        guard !results.isEmpty else {
            clearResultKeyboardNavigation()
            return
        }

        isResultKeyboardNavigationActive = true
        keyboardSelectedResultIndex = 0
        resignSearchFieldFocus()
    }

    private func syncKeyboardSelectionWithCurrentResults() {
        let results = keyboardNavigableResults

        if shouldFocusFirstResultAfterSubmit {
            focusFirstResultIfAvailable()
            return
        }

        guard isResultKeyboardNavigationActive else { return }
        guard !results.isEmpty else {
            clearResultKeyboardNavigation()
            return
        }

        if let index = keyboardSelectedResultIndex {
            keyboardSelectedResultIndex = min(index, results.count - 1)
        } else {
            keyboardSelectedResultIndex = 0
        }
    }

    private func clearResultKeyboardNavigation() {
        shouldFocusFirstResultAfterSubmit = false
        isResultKeyboardNavigationActive = false
        keyboardSelectedResultIndex = nil
    }

    private func resignSearchFieldFocus() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func installKeyEventMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isResultKeyboardNavigationActive,
                  !viewModel.isDropdownOpen,
                  !viewModel.isDatePopoverHandlingKeys else {
                return event
            }

            let results = keyboardNavigableResults
            guard !results.isEmpty else {
                return event
            }

            switch event.keyCode {
            case 123: // left
                moveSelection(in: results, offset: -1)
                return nil
            case 124: // right
                moveSelection(in: results, offset: 1)
                return nil
            case 125: // down
                moveSelection(in: results, offset: gridColumns.count)
                return nil
            case 126: // up
                moveSelection(in: results, offset: -gridColumns.count)
                return nil
            case 36, 76: // return / enter
                let selectedIndex = min(keyboardSelectedResultIndex ?? 0, results.count - 1)
                keyboardSelectedResultIndex = selectedIndex
                viewModel.savedScrollPosition = CGFloat(selectedIndex)
                selectResult(results[selectedIndex])
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    private func moveSelection(in results: [SearchResult], offset: Int) {
        guard !results.isEmpty else { return }
        let currentIndex = keyboardSelectedResultIndex ?? 0
        let nextIndex = max(0, min(results.count - 1, currentIndex + offset))
        keyboardSelectedResultIndex = nextIndex
    }
}

// MARK: - Gallery Result Card

private struct GalleryResultCard: View {
    let result: SearchResult
    let thumbnailKey: String
    let thumbnailSize: CGSize
    let index: Int
    let isKeyboardSelected: Bool
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
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.retraceAccent, lineWidth: 2)
                    .opacity(isKeyboardSelected ? 1 : 0)
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
    var onTab: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    var placeholder: String = "Search your screen history..."
    var refocusTrigger: UUID = UUID()  // Change this to trigger refocus

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
        textField.onClickCallback = {
            debugLog("[SpotlightSearchField] mouseDown - text field clicked")
            self.onFocus?()
        }

        // Focus the text field with retry logic for external monitors
        focusTextField(textField, attempt: 1)

        return textField
    }

    func updateNSView(_ textField: FocusableTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        // Update the click callback in case onFocus changed
        textField.onClickCallback = {
            debugLog("[SpotlightSearchField] mouseDown - text field clicked")
            self.onFocus?()
        }
        // Check if refocus was triggered
        if context.coordinator.lastRefocusTrigger != refocusTrigger {
            context.coordinator.lastRefocusTrigger = refocusTrigger
            debugLog("[SpotlightSearchField] Refocus triggered by Tab navigation")
            focusTextField(textField, attempt: 1)
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

        // Move caret to end of text instead of selecting all
        if let fieldEditor = window.fieldEditor(false, for: textField) as? NSTextView {
            let endPosition = fieldEditor.string.count
            fieldEditor.setSelectedRange(NSRange(location: endPosition, length: 0))
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
        Coordinator(text: $text, onSubmit: onSubmit, onEscape: onEscape, onTab: onTab, onFocus: onFocus)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onEscape: () -> Void
        let onTab: (() -> Void)?
        let onFocus: (() -> Void)?
        var lastRefocusTrigger: UUID = UUID()

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onEscape: @escaping () -> Void, onTab: (() -> Void)?, onFocus: (() -> Void)?) {
            self._text = text
            self.onSubmit = onSubmit
            self.onEscape = onEscape
            self.onTab = onTab
            self.onFocus = onFocus
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            debugLog("[SpotlightSearchField] controlTextDidBeginEditing - text field became first responder, calling onFocus")
            onFocus?()
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
            } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
                onTab?()
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
