import SwiftUI
import Shared
import App

/// Main timeline view - browse through screen history
/// Activated with Cmd+Shift+T
public struct TimelineView: View {

    // MARK: - Properties

    @StateObject private var viewModel: TimelineViewModel
    @State private var showingSearch = false

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        _viewModel = StateObject(wrappedValue: TimelineViewModel(coordinator: coordinator))
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            toolbar

            Divider()

            // Main content
            if viewModel.isLoading && viewModel.frames.isEmpty {
                loadingView
            } else if let error = viewModel.error {
                errorView(error)
            } else {
                content
            }
        }
        .background(Color.retraceBackground)
        .task {
            await viewModel.loadFrames()
        }
        .onAppear {
            setupKeyboardShortcuts()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: .spacingM) {
            // Search button
            Button(action: { showingSearch.toggle() }) {
                HStack(spacing: .spacingS) {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                        .font(.retraceBody)
                }
            }
            .buttonStyle(RetraceSecondaryButtonStyle())
            .keyboardShortcut("/", modifiers: [])

            Spacer()

            // Zoom level picker
            Picker("Zoom", selection: $viewModel.zoomLevel) {
                ForEach(ZoomLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            // Play/pause button
            Button(action: { viewModel.togglePlayback() }) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(RetraceSecondaryButtonStyle())
            .keyboardShortcut(" ", modifiers: [])

            // Navigation controls
            HStack(spacing: .spacingS) {
                Button(action: { Task { await viewModel.previousFrame() } }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(RetraceSecondaryButtonStyle())
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button(action: { Task { await viewModel.nextFrame() } }) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(RetraceSecondaryButtonStyle())
                .keyboardShortcut(.rightArrow, modifiers: [])
            }

            // Settings button
            Button(action: { /* TODO: Show settings */ }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(RetraceSecondaryButtonStyle())
            .keyboardShortcut(",", modifiers: .command)

            // More menu
            Menu {
                Button("Jump 1 Minute Back") {
                    Task { await viewModel.jumpMinutes(-1) }
                }
                .keyboardShortcut(.leftArrow, modifiers: .shift)

                Button("Jump 1 Minute Forward") {
                    Task { await viewModel.jumpMinutes(1) }
                }
                .keyboardShortcut(.rightArrow, modifiers: .shift)

                Divider()

                Button("Jump 1 Hour Back") {
                    Task { await viewModel.jumpHours(-1) }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button("Jump 1 Hour Forward") {
                    Task { await viewModel.jumpHours(1) }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Divider()

                Button("Clear Session Filter") {
                    viewModel.clearSessionFilter()
                }
                .disabled(viewModel.selectedSession == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(RetraceSecondaryButtonStyle())
        }
        .padding(.spacingM)
        .frame(height: .toolbarHeight)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            // Large frame preview
            framePreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Timeline bar
            TimelineBar(viewModel: viewModel)
        }
    }

    // MARK: - Frame Preview

    private var framePreview: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = viewModel.currentFrameImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                } else {
                    placeholderFrame
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.retraceCard)
        }
    }

    private var placeholderFrame: some View {
        VStack(spacing: .spacingL) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.retraceSecondary)

            if let frame = viewModel.currentFrame {
                VStack(spacing: .spacingS) {
                    if let appName = frame.metadata.appName {
                        Text(appName)
                            .font(.retraceHeadline)
                            .foregroundColor(.retracePrimary)
                    }

                    Text(formatTimestamp(frame.timestamp))
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)
                }
            } else {
                Text("No frame selected")
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)
            }
        }
    }

    // MARK: - Loading & Error

    private var loadingView: some View {
        VStack(spacing: .spacingL) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Loading timeline...")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: .spacingL) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.retraceDanger)

            Text("Error")
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            Text(message)
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, .spacingXL)

            Button("Retry") {
                Task { await viewModel.loadFrames() }
            }
            .buttonStyle(RetracePrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func setupKeyboardShortcuts() {
        // Keyboard shortcuts are handled via .keyboardShortcut modifiers above
        // This is a placeholder for any additional setup needed
    }
}

// MARK: - Preview

#if DEBUG
struct TimelineView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()

        TimelineView(coordinator: coordinator)
            .frame(width: 1200, height: 800)
            .preferredColorScheme(.dark)
    }
}
#endif
