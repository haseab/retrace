import SwiftUI

/// Search input bar with filters
public struct SearchBar: View {

    // MARK: - Properties

    @Binding var searchQuery: String
    @Binding var selectedApp: String?
    @Binding var startDate: Date?
    @Binding var endDate: Date?
    @Binding var contentType: ContentType

    @State private var showingFilters = false
    @FocusState private var isSearchFocused: Bool

    // MARK: - Body

    public var body: some View {
        VStack(spacing: .spacingM) {
            // Main search input
            HStack(spacing: .spacingM) {
                // Search icon
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.retraceSecondary)
                    .font(.retraceHeadline)

                // Text field
                TextField("Search your screen history...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)
                    .focused($isSearchFocused)

                // Clear button
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.retraceSecondary)
                    }
                    .buttonStyle(.plain)
                }

                // Filters toggle
                Button(action: { showingFilters.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        if hasActiveFilters {
                            Circle()
                                .fill(Color.retraceAccent)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(showingFilters ? .retraceAccent : .retraceSecondary)
            }
            .padding(.spacingM)
            .background(Color.retraceCard)
            .cornerRadius(.cornerRadiusM)
            .overlay(
                RoundedRectangle(cornerRadius: .cornerRadiusM)
                    .stroke(isSearchFocused ? Color.retraceAccent : Color.retraceBorder, lineWidth: 1)
            )

            // Filters panel
            if showingFilters {
                filtersPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingFilters)
    }

    // MARK: - Filters Panel

    private var filtersPanel: some View {
        VStack(alignment: .leading, spacing: .spacingM) {
            Text("Filters")
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            // App filter
            VStack(alignment: .leading, spacing: .spacingS) {
                Text("App")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)

                HStack {
                    Menu {
                        Button("All Apps") {
                            selectedApp = nil
                        }

                        Divider()

                        // TODO: Load actual apps from database
                        Button("Chrome") { selectedApp = "com.google.Chrome" }
                        Button("Xcode") { selectedApp = "com.apple.dt.Xcode" }
                        Button("Slack") { selectedApp = "com.tinyspeck.slackmacgap" }
                        Button("VS Code") { selectedApp = "com.microsoft.VSCode" }
                    } label: {
                        HStack {
                            Text(selectedApp ?? "All Apps")
                                .font(.retraceBody)
                                .foregroundColor(.retracePrimary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
                        }
                        .padding(.spacingS)
                        .background(Color.retraceCard)
                        .cornerRadius(.cornerRadiusS)
                    }
                    .buttonStyle(.plain)

                    if selectedApp != nil {
                        Button(action: { selectedApp = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.retraceSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Date range filter
            VStack(alignment: .leading, spacing: .spacingS) {
                Text("Date Range")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)

                HStack(spacing: .spacingM) {
                    DatePicker("From", selection: Binding(
                        get: { startDate ?? Date() },
                        set: { startDate = $0 }
                    ), displayedComponents: [.date])
                        .labelsHidden()
                        .disabled(startDate == nil)

                    Text("to")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)

                    DatePicker("To", selection: Binding(
                        get: { endDate ?? Date() },
                        set: { endDate = $0 }
                    ), displayedComponents: [.date])
                        .labelsHidden()
                        .disabled(endDate == nil)

                    Button(startDate != nil || endDate != nil ? "Clear" : "Enable") {
                        if startDate != nil || endDate != nil {
                            startDate = nil
                            endDate = nil
                        } else {
                            startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())
                            endDate = Date()
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.retraceCaption)
                }
            }

            // Content type filter
            VStack(alignment: .leading, spacing: .spacingS) {
                Text("Content Type")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)

                Picker("Content Type", selection: $contentType) {
                    ForEach(ContentType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Clear all filters
            if hasActiveFilters {
                Button("Clear All Filters") {
                    selectedApp = nil
                    startDate = nil
                    endDate = nil
                    contentType = .all
                }
                .buttonStyle(.borderless)
                .font(.retraceCallout)
                .foregroundColor(.retraceDanger)
            }
        }
        .padding(.spacingM)
        .background(Color.retraceCard)
        .cornerRadius(.cornerRadiusM)
    }

    // MARK: - Helpers

    private var hasActiveFilters: Bool {
        selectedApp != nil || startDate != nil || endDate != nil || contentType != .all
    }
}

// MARK: - Preview

#if DEBUG
struct SearchBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: .spacingL) {
            SearchBar(
                searchQuery: .constant("error message"),
                selectedApp: .constant(nil),
                startDate: .constant(nil),
                endDate: .constant(nil),
                contentType: .constant(.all)
            )

            SearchBar(
                searchQuery: .constant("password"),
                selectedApp: .constant("com.google.Chrome"),
                startDate: .constant(Date().addingTimeInterval(-7 * 24 * 3600)),
                endDate: .constant(Date()),
                contentType: .constant(.ocr)
            )
        }
        .padding()
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
