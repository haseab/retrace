import SwiftUI
import Shared
import App

/// Floating, draggable search panel for the timeline overlay
/// Allows searching through screen history and jumping to results
public struct FloatingSearchPanel: View {

    // MARK: - Properties

    let coordinator: AppCoordinator
    @Binding var position: CGPoint
    @Binding var isDragging: Bool
    let onResultSelected: (SearchResult) -> Void
    let onClose: () -> Void

    @StateObject private var viewModel: SearchViewModel
    @State private var dragOffset: CGSize = .zero
    @State private var isExpanded = true
    @FocusState private var isSearchFocused: Bool

    private let panelWidth: CGFloat = 500
    private let collapsedHeight: CGFloat = 60
    private let expandedHeight: CGFloat = 400

    // MARK: - Initialization

    public init(
        coordinator: AppCoordinator,
        position: Binding<CGPoint>,
        isDragging: Binding<Bool>,
        onResultSelected: @escaping (SearchResult) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        _position = position
        _isDragging = isDragging
        self.onResultSelected = onResultSelected
        self.onClose = onClose
        _viewModel = StateObject(wrappedValue: SearchViewModel(coordinator: coordinator))
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Drag handle and close button
            header

            // Search bar
            searchBar

            // Results (when expanded)
            if isExpanded {
                resultsArea
            }
        }
        .frame(width: panelWidth)
        .retraceMenuContainer(addPadding: false)
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation
                }
                .onEnded { value in
                    isDragging = false
                    position = CGPoint(
                        x: position.x + value.translation.width,
                        y: position.y + value.translation.height
                    )
                    dragOffset = .zero

                    // Save position to UserDefaults
                    savePosition()
                }
        )
        .onAppear {
            loadSavedPosition()
            // Auto-focus search field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isSearchFocused = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // Drag handle
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.3))
                .frame(width: 40, height: 4)

            Spacer()

            // Collapse/Expand button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(.leading, .spacingS)
        }
        .padding(.horizontal, .spacingM)
        .padding(.top, .spacingS)
        .padding(.bottom, .spacingXS)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: .spacingM) {
            Image(systemName: "magnifyingglass")
                .font(.retraceHeadline)
                .foregroundColor(.white.opacity(0.5))

            TextField("Search your screen history...", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.retraceHeadline)
                .foregroundColor(.white)
                .focused($isSearchFocused)
                .onSubmit {
                    Task {
                        await viewModel.performSearch(query: viewModel.searchQuery)
                    }
                }

            if !viewModel.searchQuery.isEmpty {
                Button(action: {
                    viewModel.searchQuery = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.retraceCallout)
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            if viewModel.isSearching {
                ProgressView()
                    .scaleEffect(0.7)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        .padding(.horizontal, RetraceMenuStyle.searchFieldPaddingH)
        .padding(.vertical, RetraceMenuStyle.searchFieldPaddingV)
        .background(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.searchFieldCornerRadius)
                .fill(RetraceMenuStyle.searchFieldBackground)
        )
        .padding(.horizontal, .spacingM)
        .padding(.bottom, .spacingS)
    }

    // MARK: - Results Area

    private var resultsArea: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.1))

            if viewModel.searchQuery.isEmpty {
                emptyStateView
            } else if viewModel.isSearching {
                searchingView
            } else if let results = viewModel.results, !results.results.isEmpty {
                resultsList(results.results)
            } else if viewModel.isEmpty {
                noResultsView
            } else {
                emptyStateView
            }
        }
        .frame(height: expandedHeight - collapsedHeight)
    }

    // MARK: - Results List

    private func resultsList(_ results: [SearchResult]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results.prefix(20), id: \.frameID) { result in
                    resultRow(result)
                }
            }
            .padding(.spacingS)
        }
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button(action: {
            onResultSelected(result)
            onClose()
        }) {
            HStack(spacing: .spacingM) {
                // App color indicator
                Circle()
                    .fill(Color.segmentColor(for: result.appBundleID ?? ""))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    // App name and timestamp
                    HStack {
                        Text(result.appName ?? "Unknown App")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.white)

                        Spacer()

                        Text(formatTimestamp(result.timestamp))
                            .font(.retraceMonoSmall)
                            .foregroundColor(.white.opacity(0.5))
                    }

                    // Snippet with highlighted match
                    if !result.snippet.isEmpty {
                        Text(result.snippet)
                            .font(.retraceCaption2)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(2)
                    }
                }
            }
            .padding(.spacingM)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, .spacingXS)
        .padding(.vertical, 2)
    }

    // MARK: - Empty States

    private var emptyStateView: some View {
        VStack(spacing: .spacingM) {
            Image(systemName: "magnifyingglass")
                .font(.retraceDisplay3)
                .foregroundColor(.white.opacity(0.3))

            Text("Search your screen history")
                .font(.retraceCallout)
                .foregroundColor(.white.opacity(0.5))

            Text("Type to find any text you've seen")
                .font(.retraceCaption2)
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchingView: some View {
        VStack(spacing: .spacingM) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))

            Text("Searching...")
                .font(.retraceCallout)
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: .spacingM) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.retraceDisplay3)
                .foregroundColor(.white.opacity(0.3))

            Text("No results found")
                .font(.retraceCallout)
                .foregroundColor(.white.opacity(0.5))

            Text("Try a different search term")
                .font(.retraceCaption2)
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    // MARK: - Position Persistence

    private func savePosition() {
        UserDefaults.standard.set(position.x, forKey: "timelineSearchPositionX")
        UserDefaults.standard.set(position.y, forKey: "timelineSearchPositionY")
    }

    private func loadSavedPosition() {
        let x = UserDefaults.standard.double(forKey: "timelineSearchPositionX")
        let y = UserDefaults.standard.double(forKey: "timelineSearchPositionY")

        if x != 0 && y != 0 {
            position = CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FloatingSearchPanel_Previews: PreviewProvider {
    static var previews: some View {
        FloatingSearchPanel(
            coordinator: AppCoordinator(),
            position: .constant(CGPoint(x: 300, y: 300)),
            isDragging: .constant(false),
            onResultSelected: { _ in },
            onClose: {}
        )
        .frame(width: 600, height: 500)
        .background(Color.gray.opacity(0.3))
        .preferredColorScheme(.dark)
    }
}
#endif
