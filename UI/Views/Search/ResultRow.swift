import SwiftUI
import Shared

/// Individual search result row showing frame preview and matched text
public struct ResultRow: View {

    // MARK: - Properties

    let result: SearchResult
    let searchQuery: String
    let onTap: () -> Void

    @State private var thumbnailImage: NSImage?
    @State private var isHovered = false

    // MARK: - Body

    public var body: some View {
        HStack(spacing: .spacingM) {
            // Thumbnail
            thumbnail
                .frame(width: 120, height: 90)
                .background(Color.retraceCard)
                .cornerRadius(.cornerRadiusM)

            // Content
            VStack(alignment: .leading, spacing: .spacingS) {
                // App and timestamp header
                HStack(spacing: .spacingS) {
                    if let appName = result.appName {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.sessionColor(for: result.appBundleID ?? ""))
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

                    Spacer()

                    // Relevance score
                    if result.relevanceScore > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                            Text(String(format: "%.0f%%", result.relevanceScore * 100))
                                .font(.retraceCaption2)
                        }
                        .foregroundColor(.retraceAccent)
                    }
                }

                // Snippet with highlights
                snippetView

                // Metadata (if available)
                if let windowTitle = result.windowTitle, !windowTitle.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 10))
                            .foregroundColor(.retraceSecondary)

                        Text(windowTitle)
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 14))
                .foregroundColor(.retraceSecondary)
                .opacity(isHovered ? 1 : 0.5)
        }
        .padding(.spacingM)
        .background(isHovered ? Color.retraceHover : Color.clear)
        .cornerRadius(.cornerRadiusM)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button("Open Frame") {
                onTap()
            }

            Button("Copy Link") {
                copyShareLink()
            }

            Divider()

            if let url = result.url {
                Button("Open URL") {
                    NSWorkspace.shared.open(URL(string: url)!)
                }
            }
        }
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

                ProgressView()
                    .scaleEffect(0.5)
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
        let query = searchQuery.lowercased()
        let snippet = result.snippet.lowercased()

        var searchRange = snippet.startIndex..<snippet.endIndex

        while let range = snippet.range(of: query, options: [], range: searchRange) {
            let attributedRange = Range(range, in: attributed)!

            attributed[attributedRange].backgroundColor = Color.retraceMatchHighlight
            attributed[attributedRange].foregroundColor = Color.retracePrimary
            attributed[attributedRange].font = .retraceBodyBold

            searchRange = range.upperBound..<snippet.endIndex
        }

        // Set default color for non-highlighted text
        attributed.foregroundColor = .retraceSecondary

        return attributed
    }

    // MARK: - Helpers

    private func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Today " + formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Yesterday " + formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    }

    private func copyShareLink() {
        let url = DeeplinkHandler.generateSearchLink(
            query: searchQuery,
            timestamp: result.timestamp,
            appBundleID: result.appBundleID
        )

        if let url = url {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ResultRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: .spacingM) {
            ResultRow(
                result: SearchResult(
                    id: FrameID(value: UUID()),
                    timestamp: Date(),
                    snippet: "Error: Cannot read property 'user' of undefined at line 42",
                    matchedText: "error",
                    relevanceScore: 0.95,
                    metadata: FrameMetadata(
                        appBundleID: "com.google.Chrome",
                        appName: "Chrome",
                        windowTitle: "GitHub - retrace/main",
                        browserURL: "https://github.com",
                        displayID: 0
                    ),
                    segmentID: SegmentID(value: UUID()),
                    frameIndex: 0
                ),
                searchQuery: "error"
            ) {}

            ResultRow(
                result: SearchResult(
                    id: FrameID(value: UUID()),
                    timestamp: Date().addingTimeInterval(-86400),
                    snippet: "TODO: Fix error handling in the authentication flow",
                    matchedText: "error",
                    relevanceScore: 0.78,
                    metadata: FrameMetadata(
                        appBundleID: "com.apple.dt.Xcode",
                        appName: "Xcode",
                        windowTitle: "AppDelegate.swift",
                        browserURL: nil,
                        displayID: 0
                    ),
                    segmentID: SegmentID(value: UUID()),
                    frameIndex: 10
                ),
                searchQuery: "error"
            ) {}

            ResultRow(
                result: SearchResult(
                    id: FrameID(value: UUID()),
                    timestamp: Date().addingTimeInterval(-172800),
                    snippet: "Login successful. User authenticated with token abc123...",
                    matchedText: "login",
                    relevanceScore: 0.62,
                    metadata: FrameMetadata(
                        appBundleID: "com.apple.Terminal",
                        appName: "Terminal",
                        windowTitle: nil,
                        browserURL: nil,
                        displayID: 0
                    ),
                    segmentID: SegmentID(value: UUID()),
                    frameIndex: 5
                ),
                searchQuery: "login"
            ) {}
        }
        .padding()
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
