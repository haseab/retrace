import SwiftUI
import Shared
import App

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
                selectedApp: $viewModel.selectedAppFilter,
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
                Text("\(results.count) results")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                Spacer()

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

            // Results list
            SearchResultsList(
                results: results,
                searchQuery: viewModel.searchQuery,
                coordinator: viewModel.coordinator
            ) { result in
                viewModel.selectResult(result)
            }
        }
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
                .foregroundColor(.retraceAccent)
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
            ProgressView()
                .scaleEffect(1.5)

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
