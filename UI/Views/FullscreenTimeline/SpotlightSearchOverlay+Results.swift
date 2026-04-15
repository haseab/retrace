import SwiftUI
import Shared
import App
import AppKit

extension SpotlightSearchOverlay {
    // MARK: - Results Area

    var hasResults: Bool {
        !viewModel.searchQuery.isEmpty && (viewModel.isSearching || viewModel.results != nil || resultsHeight > 0)
    }

    var reservedResultsHeight: CGFloat {
        max(minResultsHeight, resultsHeight)
    }

    func reserveExpandedResultsHeight() {
        guard resultsHeight < maxResultsHeight - 1 else { return }
        resultsHeight = maxResultsHeight
    }

    /// Records first-frame overlay open latency once per presentation.
    /// Uses next runloop turn so timing includes view construction/layout cost.
    func scheduleOpenLatencyMeasurement() {
        DispatchQueue.main.async {
            guard !didRecordOpenLatency, let startTime = overlayOpenStartTime else { return }
            didRecordOpenLatency = true
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            Log.recordLatency(
                "search.overlay.open.first_frame_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 5,
                warningThresholdMs: 120,
                criticalThresholdMs: 300
            )
        }
    }

    @ViewBuilder
    var resultsArea: some View {
        if viewModel.isSearching && viewModel.results == nil {
            searchingView
                .frame(height: reservedResultsHeight)
        } else if viewModel.results != nil {
            if viewModel.visibleResults.isEmpty {
                noResultsView
                    .frame(height: reservedResultsHeight)
            } else {
                resultsList(viewModel.visibleResults)
            }
        }
    }

    // MARK: - Results List

    private func resultsList(_ visibleResults: [SearchResult]) -> some View {
        ScrollViewReader { proxy in
            resultsScrollView(visibleResults, proxy: proxy)
                .onAppear {
                    // Restore scroll position when overlay appears
                    if viewModel.savedScrollPosition > 0 {
                        let targetIndex = Int(viewModel.savedScrollPosition)
                        guard visibleResults.indices.contains(targetIndex) else { return }
                        let targetResultID = visibleResults[targetIndex].id
                        // Scroll to the saved position with a slight delay to ensure layout is complete
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(targetResultID, anchor: .center)
                            }
                        }
                    }
                }
                .onChange(of: keyboardSelectedResultIndex) { selectedIndex in
                    guard let selectedIndex else { return }
                    guard visibleResults.indices.contains(selectedIndex) else { return }
                    let selectedResultID = visibleResults[selectedIndex].id
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(selectedResultID, anchor: .center)
                    }
                }
        }
    }

    private func resultsScrollView(_ visibleResults: [SearchResult], proxy: ScrollViewProxy) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            resultsGrid(visibleResults)
            if viewModel.isLoadingMore {
                loadingMoreIndicator
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxHeight: maxResultsHeight)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ResultsAreaHeightPreferenceKey.self,
                    value: geo.size.height
                )
            }
        )
    }

    private func resultsGrid(_ visibleResults: [SearchResult]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, result in
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
                .onAppear {
                    loadThumbnail(for: result)

                    // Infinite scroll: load more when near the end
                    if index >= visibleResults.count - 3 && viewModel.canLoadMore {
                        viewModel.loadMore()
                    }
                }
            }
        }
        .onAppear {
            Log.info(
                "\(searchLog) Results grid appear: generation=\(viewModel.searchGeneration), filteredCount=\(visibleResults.count), totalCount=\(viewModel.results?.results.count ?? 0), query='\(viewModel.searchQuery)', committed='\(viewModel.committedSearchQuery)'",
                category: .ui
            )
        }
        .onDisappear {
            Log.info(
                "\(searchLog) Results grid disappear: generation=\(viewModel.searchGeneration), query='\(viewModel.searchQuery)', committed='\(viewModel.committedSearchQuery)'",
                category: .ui
            )
        }
        .padding(16)
    }

    private var loadingMoreIndicator: some View {
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

            Text(viewModel.hasActiveFilters ? "No results match this query with current filters" : "No results found")
                .font(.retraceBodyMedium)
                .foregroundColor(.white.opacity(0.6))

            Text(viewModel.hasActiveFilters ? "Try broadening filters or changing your query" : "Try a different search term")
                .font(.retraceCallout)
                .foregroundColor(.white.opacity(0.45))
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
        let currentGeneration = viewModel.searchGeneration

        if viewModel.thumbnailCache[key] != nil {
            viewModel.markThumbnailAccessed(key)
            return
        }

        guard viewModel.beginThumbnailLoadIfNeeded(key) else {
            return
        }

        let startTime = Date()

        Task {
            if await viewModel.loadThumbnailFromDiskIfAvailable(for: key, generation: currentGeneration) {
                viewModel.loadingThumbnails.remove(key)
                return
            }

            do {
                // 1. Fetch frame image (prefer direct path to avoid per-thumbnail DB lookups and JPEG round-trips)
                let fullImage: NSImage
                if let videoPath = result.videoPath {
                    let cgImage = try await coordinator.getFrameCGImage(
                        videoPath: videoPath,
                        frameIndex: result.frameIndex,
                        frameRate: result.videoFrameRate,
                        source: result.source
                    )
                    fullImage = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                } else {
                    // Fallback for legacy cached results lacking video path/frame rate.
                    let imageData = try await coordinator.getFrameImageByIndex(
                        videoID: result.videoID,
                        frameIndex: result.frameIndex,
                        source: result.source
                    )
                    guard let decodedImage = NSImage(data: imageData) else {
                        Log.error("\(searchLog) Failed to create NSImage from fallback data", category: .ui)
                        viewModel.failThumbnailLoad(with: nil, for: key, generation: currentGeneration)
                        return
                    }
                    fullImage = decodedImage
                }
                // Check if search generation changed (user started a new search)
                guard viewModel.searchGeneration == currentGeneration else {
                    viewModel.failThumbnailLoad(with: nil, for: key, generation: currentGeneration)
                    return
                }

                let thumbnail: NSImage
                if let matchNode = result.highlightNode {
                    thumbnail = createHighlightedThumbnail(
                        from: fullImage,
                        matchX: matchNode.x,
                        matchY: matchNode.y,
                        matchWidth: matchNode.width,
                        matchHeight: matchNode.height,
                        size: thumbnailSize
                    )
                } else {
                    thumbnail = createThumbnail(from: fullImage, size: thumbnailSize)
                }

                viewModel.finishThumbnailLoad(
                    thumbnail,
                    for: key,
                    generation: currentGeneration
                )
            } catch {
                let duration = Date().timeIntervalSince(startTime) * 1000
                Log.error("\(searchLog) ❌ THUMBNAIL FAILED after \(Int(duration))ms: \(error)", category: .ui)
                Log.error("\(searchLog) ❌ Details: videoID=\(result.videoID), frameIndex=\(result.frameIndex), source=\(result.source)", category: .ui)

                // Create a placeholder thumbnail so the UI doesn't show infinite loading
                let placeholder = createPlaceholderThumbnail(size: thumbnailSize)
                viewModel.failThumbnailLoad(
                    with: placeholder,
                    for: key,
                    generation: currentGeneration
                )
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

    private func createHighlightedThumbnail(
        from image: NSImage,
        matchX: Double,
        matchY: Double,
        matchWidth: Double,
        matchHeight: Double,
        size: CGSize
    ) -> NSImage {
        let imageSize = image.size

        // OCR coordinates use top-left origin (y=0 at top), but NSImage uses bottom-left origin (y=0 at bottom)
        // We need to flip the Y coordinate: flippedY = 1.0 - y - height
        let flippedNodeY = 1.0 - matchY - matchHeight

        // Calculate the crop region centered on the match with padding
        // OCR coordinates are normalized (0.0-1.0), convert to pixel coordinates
        let matchCenterX = (matchX + matchWidth / 2) * imageSize.width
        let matchCenterY = (flippedNodeY + matchHeight / 2) * imageSize.height

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
        let highlightX = (matchCenterX - matchWidth / 2 * imageSize.width - cropX) * (size.width / cropWidth)
        let highlightY = (matchCenterY - matchHeight / 2 * imageSize.height - cropY) * (size.height / cropHeight)
        let highlightWidth = matchWidth * imageSize.width * (size.width / cropWidth)
        let highlightHeight = matchHeight * imageSize.height * (size.height / cropHeight)

        let highlightRect = NSRect(x: highlightX, y: highlightY, width: highlightWidth, height: highlightHeight)

        // Draw highlight rectangle
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

        // Calculate the source rect to preserve aspect ratio
        let imageSize = image.size
        let imageAspect = imageSize.width / imageSize.height
        let targetAspect = size.width / size.height

        let sourceRect: NSRect
        if imageAspect > targetAspect {
            // Image is wider than target; crop width
            let newWidth = imageSize.height * targetAspect
            let xOffset = (imageSize.width - newWidth) / 2
            sourceRect = NSRect(x: xOffset, y: 0, width: newWidth, height: imageSize.height)
        } else {
            // Image is taller than target; crop height
            let newHeight = imageSize.width / targetAspect
            let yOffset = (imageSize.height - newHeight) / 2
            sourceRect = NSRect(x: 0, y: yOffset, width: imageSize.width, height: newHeight)
        }

        // Draw into thumbnail
        let destRect = NSRect(origin: .zero, size: size)
        image.draw(in: destRect, from: sourceRect, operation: .copy, fraction: 1.0)

        thumbnail.unlockFocus()
        return thumbnail
    }

    // MARK: - Actions

    func selectResult(_ result: SearchResult) {
        viewModel.selectResult(result)
        let query = viewModel.committedSearchQuery.isEmpty ? viewModel.searchQuery : viewModel.committedSearchQuery
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.timeZone = .current
        Log.info("\(searchLog) Result selected: query='\(query)', frameID=\(result.frameID.stringValue), timestamp=\(df.string(from: result.timestamp)) (epoch: \(result.timestamp.timeIntervalSince1970)), segmentID=\(result.segmentID.stringValue), app=\(result.appName ?? "unknown")", category: .ui)

        // Dismiss overlay WITHOUT clearing search state - user selected a result
        dismissOverlayPreservingSearch()

        // Small delay to allow dismiss animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onResultSelected(result, query)
        }
    }

    /// Dismisses the overlay without clearing search state (used when selecting a result)
    func dismissOverlayPreservingSearch() {
        dismissOverlay(clearSearchState: false)
    }

    /// Dismisses the overlay and clears search state (used for explicit dismissal like Escape key)
    func dismissOverlay() {
        dismissOverlay(clearSearchState: true)
    }

    func collapseToCompactSearchBar(clearFilters: Bool) {
        guard isExpanded else { return }

        clearResultKeyboardNavigation()
        isRecentEntriesPopoverVisible = false
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil

        if clearFilters {
            viewModel.clearAllFilters()
            viewModel.resetSearchOrderToDefault()
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded = false
        }

        requestSearchFieldRefocus()
        refreshRecentEntriesPopoverVisibility()
    }

    func handleSearchEscape() {
        if isRecentEntriesPopoverVisible {
            withAnimation(.easeOut(duration: 0.15)) {
                isRecentEntriesPopoverVisible = false
            }
            highlightedRecentEntryIndex = 0
            hoveredRecentEntryKey = nil
            return
        }

        // If a dropdown is open, close it instead of collapsing/dismissing.
        if viewModel.isDropdownOpen {
            viewModel.closeDropdownsSignal += 1
            return
        }

        // When results own keyboard focus, Escape should return to the query first.
        if viewModel.shouldRefocusSearchFieldOnEscape {
            focusSearchField(selectAll: true)
            return
        }

        // Expanded overlay with no submitted search should collapse back to compact mode.
        if isExpanded && !viewModel.shouldDismissExpandedOverlayOnEscape {
            collapseToCompactSearchBar(clearFilters: true)
            return
        }

        dismissOverlay()
    }

    func handleSearchCommandK() {
        if viewModel.isDropdownOpen {
            viewModel.closeDropdownsSignal += 1
            return
        }

        if viewModel.shouldRefocusSearchFieldOnEscape {
            focusSearchField(selectAll: true)
            return
        }

        // Cmd+K closes the visible overlay but preserves the current search state.
        dismissOverlayPreservingSearch()
    }

    func requestSearchFieldRefocus(selectAll: Bool = false) {
        refocusSearchField = SearchFieldRefocusRequest(
            id: UUID(),
            selectionBehavior: selectAll ? .selectAll : .caretAtEnd
        )
    }

    func focusSearchField(selectAll: Bool) {
        clearResultKeyboardNavigation()
        isSearchFieldFocused = true
        viewModel.isSearchFieldFocused = true
        requestSearchFieldRefocus(selectAll: selectAll)
    }

    func dismissOverlay(clearSearchState: Bool) {
        guard !isDismissing else { return }
        isDismissing = true

        // Cancel any in-flight search tasks to prevent blocking while the overlay fades out.
        viewModel.cancelSearch()
        clearResultKeyboardNavigation()
        isRecentEntriesPopoverVisible = false
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil
        rankedRecentEntries = []

        withAnimation(.easeOut(duration: dismissAnimationDuration)) {
            isVisible = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            // Clear only after fade-out completes so dismiss is visually smooth.
            if clearSearchState {
                viewModel.searchQuery = ""
                viewModel.clearAllFilters()
                viewModel.resetSearchOrderToDefault()
            }
            onDismiss()
            isDismissing = false
        }
    }

    // MARK: - Keyboard Navigation

    private var keyboardNavigableResults: [SearchResult] {
        viewModel.visibleResults
    }

    func prepareResultKeyboardNavigationAfterSubmit() {
        shouldFocusFirstResultAfterSubmit = true
        isResultKeyboardNavigationActive = true
        keyboardSelectedResultIndex = nil
        isRecentEntriesPopoverVisible = false
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

    func updateSubmittedSearchResultFocus() {
        guard shouldFocusFirstResultAfterSubmit else { return }

        let totalResultCount = viewModel.results?.results.count
        let visibleResultCount = keyboardNavigableResults.count
        let hasSearchError = viewModel.error != nil

        if visibleResultCount > 0 {
            focusFirstResultIfAvailable()
            return
        }

        if viewModel.isSearching {
            return
        }

        if let totalResultCount {
            if totalResultCount == 0 {
                clearResultKeyboardNavigation()
            }
            return
        }

        if hasSearchError {
            clearResultKeyboardNavigation()
        }
    }

    func syncKeyboardSelectionWithCurrentResults() {
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

    func clearResultKeyboardNavigation() {
        shouldFocusFirstResultAfterSubmit = false
        isResultKeyboardNavigationActive = false
        keyboardSelectedResultIndex = nil
        refreshRecentEntriesPopoverVisibility()
    }

    private func resignSearchFieldFocus() {
        isSearchFieldFocused = false
        viewModel.isSearchFieldFocused = false
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    func installKeyEventMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Handle overlay-level dismissal/focus shortcuts here so AppKit text bindings
            // in the search field do not swallow them before the timeline controller sees them.
            if event.keyCode == 53 && modifiers.isEmpty { // Escape
                handleSearchEscape()
                return nil
            }

            if event.keyCode == 40 && modifiers == [.command] { // Cmd+K
                handleSearchCommandK()
                return nil
            }

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

    func removeKeyEventMonitor() {
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
