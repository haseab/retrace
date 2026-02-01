import SwiftUI
import Shared
import App

/// Debug logging to file
private func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
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

/// Main search view - find frames by text content
/// Activated with Cmd+F
public struct SearchView: View {

    // MARK: - Properties

    @StateObject private var viewModel: SearchViewModel

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        _viewModel = StateObject(wrappedValue: SearchViewModel(coordinator: coordinator))
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Search bar
            SearchBar(
                searchQuery: $viewModel.searchQuery,
                selectedApps: $viewModel.selectedAppFilters,
                startDate: $viewModel.startDate,
                endDate: $viewModel.endDate,
                contentType: $viewModel.contentType
            )
            .padding(.spacingM)

            Divider()

            // Content
            if viewModel.isSearching {
                searchingView
            } else if let error = viewModel.error {
                errorView(error)
            } else if viewModel.searchQuery.isEmpty {
                emptyStateView
            } else if viewModel.isEmpty {
                noResultsView
            } else if let results = viewModel.results {
                resultsView(results: results.results)
            }
        }
        .background(Color.retraceBackground)
        .sheet(isPresented: $viewModel.showingFrameViewer) {
            if let result = viewModel.selectedResult {
                frameViewerSheet(result: result)
            }
        }
    }

    // MARK: - Results View

    private func resultsView(results: [SearchResult]) -> some View {
        VStack(spacing: 0) {
            // Results header
            HStack {
                // Match count with segment info for grouped view
                if viewModel.viewMode == .grouped, let grouped = viewModel.groupedResults {
                    Text("\(grouped.totalMatchCount) matches")
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)

                    Text("in \(grouped.totalSegmentCount) segments")
                        .font(.retraceCallout)
                        .foregroundColor(.retraceSecondary)
                } else {
                    Text("\(results.count) results")
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)
                }

                Spacer()

                // View mode toggle
                HStack(spacing: 2) {
                    viewModeButton(mode: .grouped, icon: "rectangle.stack", tooltip: "Grouped by segment")
                    viewModeButton(mode: .flat, icon: "list.bullet", tooltip: "Flat list")
                }
                .padding(2)
                .background(Color.retraceCard)
                .cornerRadius(6)

                // Sort options (future enhancement)
                Menu {
                    Button("Relevance") {}
                    Button("Most Recent") {}
                    Button("Oldest First") {}
                } label: {
                    HStack(spacing: 4) {
                        Text("Sort")
                            .font(.retraceCallout)
                        Image(systemName: "chevron.down")
                            .font(.retraceTiny)
                    }
                    .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, .spacingM)
            .padding(.vertical, .spacingS)

            Divider()

            // Conditional view based on mode
            let _ = debugLog("[SearchView] Rendering - viewMode=\(viewModel.viewMode), groupedResults=\(viewModel.groupedResults != nil ? "set(\(viewModel.groupedResults!.daySections.count) sections)" : "nil")")
            if viewModel.viewMode == .grouped, let grouped = viewModel.groupedResults {
                let _ = debugLog("[SearchView] Using GroupedSearchResultsList")
                GroupedSearchResultsList(
                    groupedResults: grouped,
                    searchQuery: viewModel.searchQuery,
                    coordinator: viewModel.coordinator,
                    onSelectResult: { result in
                        viewModel.selectResult(result)
                    },
                    onToggleStack: { segmentID in
                        viewModel.toggleStackExpansion(segmentID: segmentID)
                    }
                )
            } else {
                let _ = debugLog("[SearchView] Using SearchResultsList (flat mode)")
                SearchResultsList(
                    results: results,
                    searchQuery: viewModel.searchQuery,
                    coordinator: viewModel.coordinator
                ) { result in
                    viewModel.selectResult(result)
                }
            }
        }
    }

    // MARK: - View Mode Toggle

    private func viewModeButton(mode: SearchViewMode, icon: String, tooltip: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.viewMode = mode
            }
        } label: {
            Image(systemName: icon)
                .font(.retraceCallout)
                .foregroundColor(viewModel.viewMode == mode ? .retracePrimary : .retraceSecondary)
                .frame(width: 28, height: 24)
                .background(viewModel.viewMode == mode ? Color.retraceHover : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Frame Viewer Sheet

    private func frameViewerSheet(result: SearchResult) -> some View {
        FrameViewer(
            result: result,
            searchQuery: viewModel.searchQuery,
            coordinator: viewModel.coordinator
        ) {
            viewModel.closeFrameViewer()
        }
    }

    // MARK: - Empty States

    private var emptyStateView: some View {
        VStack(spacing: .spacingL) {
            Image(systemName: "magnifyingglass")
                .font(.retraceDisplay)
                .foregroundColor(.retraceSecondary)

            VStack(spacing: .spacingS) {
                Text("Search Your Screen History")
                    .font(.retraceTitle3)
                    .foregroundColor(.retracePrimary)

                Text("Find anything you've seen on your screen")
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)
            }

            VStack(alignment: .leading, spacing: .spacingS) {
                searchTip(icon: "text.cursor", text: "Search for any text that appeared on your screen")
                searchTip(icon: "calendar", text: "Filter by date range to narrow results")
                searchTip(icon: "app.badge", text: "Filter by specific apps")
                searchTip(icon: "link", text: "Right-click results to copy shareable links")
            }
            .padding(.spacingL)
            .background(Color.retraceCard)
            .cornerRadius(.cornerRadiusL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.spacingXL)
    }

    private func searchTip(icon: String, text: String) -> some View {
        HStack(spacing: .spacingM) {
            Image(systemName: icon)
                .font(.retraceTitle3)
                .foregroundStyle(LinearGradient.retraceAccentGradient)
                .frame(width: 24)

            Text(text)
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
        }
    }

    private var noResultsView: some View {
        VStack(spacing: .spacingL) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.retraceDisplay)
                .foregroundColor(.retraceSecondary)

            VStack(spacing: .spacingS) {
                Text("No Results Found")
                    .font(.retraceTitle3)
                    .foregroundColor(.retracePrimary)

                Text("Try adjusting your search or filters")
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)
            }

            Button("Clear Filters") {
                viewModel.clearAllFilters()
            }
            .buttonStyle(RetraceSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchingView: some View {
        VStack(spacing: .spacingL) {
            SpinnerView(size: 32, lineWidth: 3)

            Text("Searching...")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: .spacingL) {
            Image(systemName: "exclamationmark.triangle")
                .font(.retraceDisplay)
                .foregroundColor(.retraceDanger)

            Text("Search Error")
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            Text(message)
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, .spacingXL)

            Button("Retry") {
                Task {
                    await viewModel.performSearch(query: viewModel.searchQuery)
                }
            }
            .buttonStyle(RetracePrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#if DEBUG
struct SearchView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()

        SearchView(coordinator: coordinator)
            .frame(width: 1000, height: 700)
            .preferredColorScheme(.dark)
    }
}
#endif
