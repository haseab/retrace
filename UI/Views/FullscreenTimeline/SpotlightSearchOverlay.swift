import SwiftUI
import Shared
import App

private let searchLog = "[SpotlightSearch]"

/// Spotlight-style search overlay that appears center-screen
/// Triggered by Cmd+K or search icon click
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
    @FocusState private var isSearchFocused: Bool

    // Thumbnail cache - persists across overlay appearances since viewModel persists
    @State private var thumbnailCache: [String: NSImage] = [:]
    @State private var loadingThumbnails: Set<String> = []

    // App icon cache
    @State private var appIconCache: [String: NSImage] = [:]

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
            // Backdrop
            Color.black.opacity(isVisible ? 0.6 : 0)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissOverlay()
                }

            // Search panel
            VStack(spacing: 0) {
                searchBar

                if hasResults {
                    Divider()
                        .background(Color.white.opacity(0.1))

                    resultsArea
                }
            }
            .frame(width: panelWidth)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.12).opacity(0.95))
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.ultraThinMaterial)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 15)
            .scaleEffect(isVisible ? 1.0 : 0.95)
            .opacity(isVisible ? 1.0 : 0)
        }
        .onAppear {
            Log.debug("\(searchLog) Search overlay opened", category: .ui)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isVisible = true
            }
            // Focus the search field immediately
            isSearchFocused = true
        }
        .onChange(of: isVisible) { visible in
            // Ensure focus when overlay becomes visible
            if visible {
                isSearchFocused = true
            }
        }
        .onExitCommand {
            Log.debug("\(searchLog) Exit command received", category: .ui)
            dismissOverlay()
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
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            TextField("Search your screen history...", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .foregroundColor(.white)
                .focused($isSearchFocused)
                .onSubmit {
                    // If we have results and user presses Enter, select first result
                    // Otherwise, trigger search
                    if let firstResult = viewModel.results?.results.first {
                        selectResult(firstResult)
                    } else if !viewModel.searchQuery.isEmpty {
                        Log.debug("\(searchLog) Submit pressed, triggering search", category: .ui)
                        viewModel.submitSearch()
                    }
                }

            if viewModel.isSearching {
                ProgressView()
                    .scaleEffect(0.8)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            } else if !viewModel.searchQuery.isEmpty {
                Button(action: {
                    viewModel.searchQuery = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
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
                    ForEach(Array(filteredResults.enumerated()), id: \.element.frameID) { index, result in
                        GalleryResultCard(
                            result: result,
                            searchQuery: viewModel.searchQuery,
                            thumbnail: thumbnailCache[thumbnailKey(for: result)],
                            appIcon: appIconCache[result.appBundleID ?? ""],
                            thumbnailSize: thumbnailSize,
                            index: index
                        ) {
                            // Save scroll position before selecting result
                            viewModel.savedScrollPosition = CGFloat(index)
                            selectResult(result)
                        }
                        .id(index)
                        .onAppear {
                            Log.debug("\(searchLog) Result card appeared: index=\(index), frameID=\(result.frameID.stringValue), timestamp=\(result.timestamp)", category: .ui)
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
                .padding(16)

                // Loading more indicator
                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                        Text("Loading more...")
                            .font(.system(size: 12))
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
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)

            Text("Searching...")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.3))

            Text("No results found")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Text("Try a different search term")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Thumbnail Loading

    private func thumbnailKey(for result: SearchResult) -> String {
        "\(result.segmentID.stringValue)_\(result.timestamp.timeIntervalSince1970)"
    }

    private func loadThumbnail(for result: SearchResult) {
        let key = thumbnailKey(for: result)

        guard thumbnailCache[key] == nil, !loadingThumbnails.contains(key) else {
            if thumbnailCache[key] != nil {
                Log.debug("\(searchLog) Thumbnail already cached for: \(key)", category: .ui)
            }
            return
        }

        loadingThumbnails.insert(key)
        let startTime = Date()
        Log.debug("\(searchLog) Starting thumbnail load for: segmentID=\(result.segmentID.stringValue), timestamp=\(result.timestamp)", category: .ui)

        Task {
            do {
                let fetchStart = Date()
                let imageData = try await coordinator.getFrameImage(
                    segmentID: result.segmentID,
                    timestamp: result.timestamp
                )
                let fetchDuration = Date().timeIntervalSince(fetchStart) * 1000
                Log.debug("\(searchLog) Image data fetched in \(Int(fetchDuration))ms, size=\(imageData.count) bytes", category: .ui)

                if let fullImage = NSImage(data: imageData) {
                    // Create thumbnail
                    let resizeStart = Date()
                    let thumbnail = createThumbnail(from: fullImage, size: thumbnailSize)
                    let resizeDuration = Date().timeIntervalSince(resizeStart) * 1000
                    let totalDuration = Date().timeIntervalSince(startTime) * 1000
                    Log.debug("\(searchLog) Thumbnail created: \(Int(thumbnail.size.width))x\(Int(thumbnail.size.height)), resize=\(Int(resizeDuration))ms, total=\(Int(totalDuration))ms", category: .ui)

                    await MainActor.run {
                        thumbnailCache[key] = thumbnail
                        loadingThumbnails.remove(key)
                    }
                } else {
                    Log.error("\(searchLog) Failed to create NSImage from data", category: .ui)
                    await MainActor.run {
                        loadingThumbnails.remove(key)
                    }
                }
            } catch {
                let duration = Date().timeIntervalSince(startTime) * 1000
                Log.error("\(searchLog) Failed to load thumbnail after \(Int(duration))ms: \(error.localizedDescription)", category: .ui)
                await MainActor.run {
                    loadingThumbnails.remove(key)
                }
            }
        }
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
        guard appIconCache[bundleID] == nil else { return }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 20, height: 20)
            appIconCache[bundleID] = icon
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
    let searchQuery: String
    let thumbnail: NSImage?
    let appIcon: NSImage?
    let thumbnailSize: CGSize
    let index: Int
    let onSelect: () -> Void

    @State private var isHovered = false

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
                // Thumbnail with search highlight overlay
                ZStack(alignment: .topLeading) {
                    thumbnailView

                    // Yellow highlight boxes on thumbnail showing where search matches are
                    if let thumbnail = thumbnail {
                        highlightOverlay
                    }
                }

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
                            .fill(Color.sessionColor(for: result.appBundleID ?? ""))
                            .frame(width: 20, height: 20)
                    }

                    // Title and timestamp
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(formatTimestamp(result.timestamp))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
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
                ProgressView()
                    .scaleEffect(0.8)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
    }

    @ViewBuilder
    private var highlightOverlay: some View {
        // This is a placeholder for the yellow highlight boxes
        // The actual highlighting is done on the frame viewer, not the thumbnail
        // But we show a subtle indicator that this result contains the search term
        VStack {
            Spacer()
            HStack {
                Spacer()
                // Match indicator badge
                Text(searchQuery)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.yellow)
                    .cornerRadius(4)
                    .padding(8)
            }
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy HH:mm"
        return formatter.string(from: date)
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
