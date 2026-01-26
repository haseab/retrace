import SwiftUI
import Shared
import App

/// Full frame viewer with bounding box highlighting
/// Shows frame image with OCR text regions highlighted
public struct FrameViewer: View {

    // MARK: - Properties

    let result: SearchResult
    let searchQuery: String
    let onClose: () -> Void

    @State private var frameImage: NSImage?
    @State private var textRegions: [TextRegion] = []
    @State private var isLoading = true
    @State private var zoomScale: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero

    private let coordinator: AppCoordinator

    // MARK: - Initialization

    public init(
        result: SearchResult,
        searchQuery: String,
        coordinator: AppCoordinator,
        onClose: @escaping () -> Void
    ) {
        self.result = result
        self.searchQuery = searchQuery
        self.coordinator = coordinator
        self.onClose = onClose
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Frame content
            if isLoading {
                loadingView
            } else if let image = frameImage {
                frameContent(image: image)
            } else {
                errorView
            }

            Divider()

            // OCR text list
            if !textRegions.isEmpty {
                ocrTextList
            }
        }
        .background(Color.retraceBackground)
        .task {
            await loadFrameData()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                HStack(spacing: .spacingS) {
                    Image(systemName: "chevron.left")
                    Text("Back to Results")
                }
            }
            .buttonStyle(.borderless)

            Spacer()

            // Frame info
            VStack(alignment: .center, spacing: 2) {
                if let appName = result.appName {
                    Text(appName)
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)
                }

                Text(formatTimestamp(result.timestamp))
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            // Zoom controls
            HStack(spacing: .spacingS) {
                Button(action: { zoomScale = max(0.5, zoomScale - 0.25) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("-", modifiers: .command)

                Text("\(Int(zoomScale * 100))%")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
                    .frame(width: 50)

                Button(action: { zoomScale = min(3.0, zoomScale + 0.25) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("+", modifiers: .command)

                Button(action: { zoomScale = 1.0; dragOffset = .zero }) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.spacingM)
    }

    // MARK: - Frame Content

    private func frameContent(image: NSImage) -> some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    // Frame image
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoomScale)
                        .offset(dragOffset)

                    // ⚠️ RELEASE 2 ONLY - Bounding box overlay removed for Release 1
                    // Search highlighting will be added in Release 2
                    /*
                    if !textRegions.isEmpty {
                        BoundingBoxOverlay(
                            regions: textRegions,
                            searchQuery: searchQuery,
                            frameSize: image.size
                        )
                        .scaleEffect(zoomScale)
                        .offset(dragOffset)
                    }
                    */
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .center
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                )
            }
        }
    }

    // MARK: - OCR Text List

    private var ocrTextList: some View {
        VStack(alignment: .leading, spacing: .spacingS) {
            Text("OCR Text Detected (\(textRegions.count) regions)")
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)
                .padding(.horizontal, .spacingM)
                .padding(.top, .spacingM)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: .spacingS) {
                    ForEach(textRegions) { region in
                        ocrTextRow(region: region)
                    }
                }
                .padding(.spacingM)
            }
        }
        .frame(maxHeight: 200)
        .background(Color.retraceSecondaryBackground)
    }

    private func ocrTextRow(region: TextRegion) -> some View {
        let matches = region.text.lowercased().contains(searchQuery.lowercased())

        return HStack(alignment: .top, spacing: .spacingS) {
            // Match indicator
            Circle()
                .fill(matches ? Color.retraceAccent : Color.retraceSecondary.opacity(0.3))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            // Text
            VStack(alignment: .leading, spacing: 4) {
                Text(region.text)
                    .font(.retraceBody)
                    .foregroundColor(matches ? .retracePrimary : .retraceSecondary)

                if let confidence = region.confidence {
                    Text("Confidence: \(Int(confidence * 100))%")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                }
            }

            Spacer()

            if matches {
                Text("MATCH")
                    .font(.retraceCaption2)
                    .fontWeight(.bold)
                    .foregroundColor(.retraceSuccess)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.retraceSuccess.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.spacingS)
        .background(matches ? Color.retraceMatchHighlight.opacity(0.1) : Color.clear)
        .cornerRadius(.cornerRadiusS)
    }

    // MARK: - Loading & Error

    private var loadingView: some View {
        VStack(spacing: .spacingL) {
            SpinnerView(size: 32, lineWidth: 3)

            Text("Loading frame...")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: .spacingL) {
            Image(systemName: "exclamationmark.triangle")
                .font(.retraceDisplay)
                .foregroundColor(.retraceDanger)

            Text("Failed to load frame")
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            Button("Retry") {
                Task { await loadFrameData() }
            }
            .buttonStyle(RetracePrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadFrameData() async {
        isLoading = true

        // TODO: Get actual segment ID and frame index from result
        // For now, mock the data
        // let imageData = try await coordinator.getFrameImage(...)
        // frameImage = NSImage(data: imageData)

        // TODO: Load OCR text regions from database
        // textRegions = ...

        // Mock data for preview
        textRegions = []
        isLoading = false
    }

    // MARK: - Helpers

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#if DEBUG
struct FrameViewer_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()

        FrameViewer(
            result: SearchResult(
                id: FrameID(value: 1),
                timestamp: Date(),
                snippet: "Error: Cannot read property 'user' of undefined",
                matchedText: "error",
                relevanceScore: 0.95,
                metadata: FrameMetadata(
                    appBundleID: "com.google.Chrome",
                    appName: "Chrome",
                    windowName: "GitHub",
                    browserURL: "https://github.com",
                    displayID: 0
                ),
                segmentID: AppSegmentID(value: 1),
                frameIndex: 42
            ),
            searchQuery: "error",
            coordinator: coordinator
        ) {
            print("Close viewer")
        }
        .frame(width: 1000, height: 700)
        .preferredColorScheme(.dark)
    }
}
#endif
