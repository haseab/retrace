import SwiftUI
import Shared

/// Scrollable list of search results
public struct SearchResultsList: View {

    // MARK: - Properties

    let results: [SearchResult]
    let searchQuery: String
    let onSelectResult: (SearchResult) -> Void

    @State private var selectedResultID: FrameID?

    // MARK: - Body

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: .spacingS) {
                ForEach(results, id: \.frameID) { result in
                    ResultRow(
                        result: result,
                        searchQuery: searchQuery
                    ) {
                        selectedResultID = result.frameID
                        onSelectResult(result)
                    }
                    .overlay(
                        selectedResultID == result.frameID ?
                        RoundedRectangle(cornerRadius: .cornerRadiusM)
                            .stroke(Color.retraceAccent, lineWidth: 2)
                        : nil
                    )
                }
            }
            .padding(.spacingM)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SearchResultsList_Previews: PreviewProvider {
    static var previews: some View {
        let sampleResults = [
            SearchResult(
                id: FrameID(value: UUID()),
                timestamp: Date(),
                snippet: "Error: Cannot read property 'user' of undefined",
                matchedText: "Error",
                relevanceScore: 0.95,
                metadata: FrameMetadata(
                    appBundleID: "com.google.Chrome",
                    appName: "Chrome",
                    windowTitle: "GitHub",
                    browserURL: "https://github.com",
                    displayID: 0
                ),
                segmentID: SegmentID(value: UUID()),
                frameIndex: 0
            ),
            SearchResult(
                id: FrameID(value: UUID()),
                timestamp: Date().addingTimeInterval(-300),
                snippet: "TODO: Fix error handling",
                matchedText: "error",
                relevanceScore: 0.82,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.dt.Xcode",
                    appName: "Xcode",
                    windowTitle: "AppDelegate.swift",
                    browserURL: nil,
                    displayID: 0
                ),
                segmentID: SegmentID(value: UUID()),
                frameIndex: 0
            ),
            SearchResult(
                id: FrameID(value: UUID()),
                timestamp: Date().addingTimeInterval(-600),
                snippet: "Debug: Login error occurred",
                matchedText: "Login",
                relevanceScore: 0.75,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Terminal",
                    appName: "Terminal",
                    windowTitle: nil,
                    browserURL: nil,
                    displayID: 0
                ),
                segmentID: SegmentID(value: UUID()),
                frameIndex: 0
            )
        ]

        SearchResultsList(
            results: sampleResults,
            searchQuery: "error"
        ) { result in
            print("Selected: \(result.snippet)")
        }
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
