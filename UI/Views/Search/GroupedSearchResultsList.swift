import SwiftUI
import Shared
import App

/// Grouped search results list with day sections and segment stacks
/// Provides a high-level overview of search results, reducing scroll fatigue
public struct GroupedSearchResultsList: View {

    // MARK: - Properties

    let groupedResults: GroupedSearchResults
    let searchQuery: String
    let coordinator: AppCoordinator
    let onSelectResult: (SearchResult) -> Void
    let onToggleStack: (AppSegmentID) -> Void

    @State private var selectedResultID: FrameID?

    // MARK: - Body

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: .spacingM, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedResults.daySections) { daySection in
                    Section {
                        ForEach(daySection.segmentStacks) { stack in
                            SegmentStackRow(
                                stack: stack,
                                searchQuery: searchQuery,
                                coordinator: coordinator,
                                onSelect: { result in
                                    selectedResultID = result.frameID
                                    onSelectResult(result)
                                },
                                onToggle: { onToggleStack(stack.segmentID) }
                            )
                            .overlay(
                                selectedResultID == stack.representativeResult.frameID ?
                                RoundedRectangle(cornerRadius: .cornerRadiusM)
                                    .stroke(Color.retraceAccent, lineWidth: 2)
                                : nil
                            )
                        }
                    } header: {
                        DaySectionHeader(
                            label: daySection.displayLabel,
                            matchCount: daySection.totalMatchCount,
                            segmentCount: daySection.segmentStacks.count
                        )
                    }
                }
            }
            .padding(.spacingM)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct GroupedSearchResultsList_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()

        let sampleResults = GroupedSearchResults(
            query: SearchQuery(text: "error"),
            daySections: [
                SearchDaySection(
                    dateKey: "2024-12-30",
                    displayLabel: "Today",
                    date: Date(),
                    segmentStacks: [
                        SegmentSearchStack(
                            segmentID: AppSegmentID(value: 1),
                            representativeResult: SearchResult(
                                id: FrameID(value: 1),
                                timestamp: Date(),
                                snippet: "Error: Cannot read property 'user' of undefined",
                                matchedText: "error",
                                relevanceScore: 0.95,
                                metadata: FrameMetadata(
                                    appBundleID: "com.google.Chrome",
                                    appName: "Chrome",
                                    windowName: "GitHub",
                                    browserURL: nil,
                                    displayID: 0
                                ),
                                segmentID: AppSegmentID(value: 1),
                                frameIndex: 0
                            ),
                            matchCount: 5
                        ),
                        SegmentSearchStack(
                            segmentID: AppSegmentID(value: 2),
                            representativeResult: SearchResult(
                                id: FrameID(value: 2),
                                timestamp: Date().addingTimeInterval(-1800),
                                snippet: "TODO: Fix error handling in auth",
                                matchedText: "error",
                                relevanceScore: 0.85,
                                metadata: FrameMetadata(
                                    appBundleID: "com.apple.dt.Xcode",
                                    appName: "Xcode",
                                    windowName: "AppDelegate.swift",
                                    browserURL: nil,
                                    displayID: 0
                                ),
                                segmentID: AppSegmentID(value: 2),
                                frameIndex: 10
                            ),
                            matchCount: 1
                        )
                    ]
                ),
                SearchDaySection(
                    dateKey: "2024-12-29",
                    displayLabel: "Yesterday",
                    date: Date().addingTimeInterval(-86400),
                    segmentStacks: [
                        SegmentSearchStack(
                            segmentID: AppSegmentID(value: 3),
                            representativeResult: SearchResult(
                                id: FrameID(value: 3),
                                timestamp: Date().addingTimeInterval(-86400),
                                snippet: "Debug: Login error occurred at line 42",
                                matchedText: "error",
                                relevanceScore: 0.75,
                                metadata: FrameMetadata(
                                    appBundleID: "com.apple.Terminal",
                                    appName: "Terminal",
                                    windowName: nil,
                                    browserURL: nil,
                                    displayID: 0
                                ),
                                segmentID: AppSegmentID(value: 3),
                                frameIndex: 5
                            ),
                            matchCount: 3
                        )
                    ]
                )
            ],
            totalMatchCount: 9,
            totalSegmentCount: 3,
            searchTimeMs: 42
        )

        GroupedSearchResultsList(
            groupedResults: sampleResults,
            searchQuery: "error",
            coordinator: coordinator,
            onSelectResult: { result in
                print("Selected: \(result.snippet)")
            },
            onToggleStack: { segmentID in
                print("Toggle stack: \(segmentID)")
            }
        )
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
