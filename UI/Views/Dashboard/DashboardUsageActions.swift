import SwiftUI
import Shared

enum DashboardUsageAction: String, Sendable {
    case hide, delete

    var title: String { self == .hide ? "Hide" : "Delete" }
    var icon: String { self == .hide ? "eye.slash" : "trash" }
}

/// Retains the actual grouping keys, never a cleaned display title or substring filter.
struct DashboardUsageTarget: Sendable {
    enum Scope: Sendable {
        case app
        case website(String)
        case tab(title: String?, url: String?)
        case window(title: String?, withoutWebsite: Bool)
    }
    let bundleID: String
    let name: String
    let scope: Scope

    static func app(_ app: AppUsageData) -> Self {
        Self(bundleID: app.appBundleID, name: app.appName, scope: .app)
    }

    static func website(app: AppUsageData, domain: String) -> Self {
        Self(bundleID: app.appBundleID, name: domain, scope: .website(domain))
    }

    static func tab(app: AppUsageData, window: WindowUsageData) -> Self {
        Self(bundleID: app.appBundleID, name: window.displayName, scope: .tab(title: window.windowName, url: window.browserUrl))
    }

    static func window(app: AppUsageData, window: WindowUsageData) -> Self {
        Self(bundleID: app.appBundleID, name: window.displayName,
             scope: .window(title: window.windowName, withoutWebsite: app.isBrowser))
    }

    func matches(_ frame: FrameReference) -> Bool {
        guard frame.source == .native, frame.metadata.appBundleID == bundleID else { return false }
        switch scope {
        case .app: return true
        case .website(let domain):
            guard let url = frame.metadata.browserURL else { return false }
            // Mirror AppSegmentQueries' authority extraction, including ports and
            // scheme-less fallbacks. Similar domains and subdomains remain separate.
            let authority: String
            if let separator = url.range(of: "://") {
                authority = String(url[separator.upperBound...].prefix { $0 != "/" })
            } else {
                authority = url
            }
            return authority == domain
        case .tab(let title, let url):
            return frame.metadata.windowName == title && frame.metadata.browserURL == url
        case .window(let title, let withoutWebsite):
            return frame.metadata.windowName == title &&
                (!withoutWebsite || frame.metadata.browserURL?.isEmpty != false)
        }
    }
}

struct DashboardUsageActionPlan: Sendable {
    let target: DashboardUsageTarget
    let action: DashboardUsageAction
    let start: Date
    let end: Date
    let frames: [FrameReference]
    let segmentIDs: [SegmentID]
}

/// Native macOS chrome provides standard focus, dismissal, and keyboard behavior.
struct DashboardUsageMenu: View {
    let target: DashboardUsageTarget
    let onAction: ((DashboardUsageTarget, DashboardUsageAction) -> Void)?

    var body: some View {
        Text(target.name).lineLimit(1)
        Divider()
        Button { onAction?(target, .hide) } label: {
            Label("Hide segments…", systemImage: "eye.slash")
        }
        Button(role: .destructive) { onAction?(target, .delete) } label: {
            Label("Delete segments…", systemImage: "trash")
        }
    }
}

struct DashboardUsageActionRequest: Identifiable {
    let id = UUID()
    let target: DashboardUsageTarget
    let action: DashboardUsageAction
}

struct DashboardUsageConfirmationView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let request: DashboardUsageActionRequest
    let onDismiss: () -> Void
    @State private var plan: DashboardUsageActionPlan?
    @State private var errorText: String?
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var resultText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: request.action.icon)
                    .font(.system(size: 22))
                    .foregroundColor(request.action == .delete ? .retraceDanger : .retraceAccent)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(request.action.title) segments?").font(.retraceHeadline)
                    Text(request.target.name).font(.retraceBody).foregroundColor(.retraceSecondary)
                        .lineLimit(2).textSelection(.enabled)
                }
            }

            if isLoading {
                HStack { ProgressView().controlSize(.small); Text("Finding matching segments…") }
            } else if let plan {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(plan.segmentIDs.count) segments · \(plan.frames.count) frames in range")
                        .font(.retraceCalloutBold)
                    Text("\(plan.start.formatted(date: .abbreviated, time: .standard)) – \(plan.end.formatted(date: .abbreviated, time: .standard))")
                        .font(.retraceCaption).foregroundColor(.retraceSecondary)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

                Text(request.action == .hide
                    ? "Hide these entire segments from the dashboard, timeline, and search. Segments crossing this date range are hidden in full, including new frames if a segment is still active. Your recordings are preserved. Restore them using the timeline’s Hidden filter and Unhide action."
                    : "Permanently delete matching recorded frames within this date range. This cannot be undone. Recordings still being encoded will be queued for deletion. This does not stop future recording.")
                    .font(.retraceCaption).foregroundColor(.retraceSecondary)
                Text("Applies to this app only. Already hidden segments and Rewind recordings are excluded.")
                    .font(.retraceCaption).foregroundColor(.retraceSecondary)
                if plan.frames.isEmpty {
                    Text("No matching visible recordings remain in this range.").font(.retraceCaption)
                }
            }

            if let errorText {
                Text(errorText).font(.retraceCaption).foregroundColor(.retraceDanger).textSelection(.enabled)
            }
            if let resultText {
                Text(resultText).font(.retraceCaption).foregroundColor(.retraceSuccess)
            }

            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Spacer()
                Button(resultText == nil ? "Cancel" : "Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isApplying)
                if resultText == nil {
                    Button {
                        guard let plan, !isApplying else { return }
                        isApplying = true
                        errorText = nil
                        Task {
                            do {
                                resultText = try await viewModel.applyUsageAction(plan)
                            } catch {
                                errorText = "The action could not finish. Some segments may have changed. Close this dialog and try again. \(error.localizedDescription)"
                                self.plan = nil // Never retry a partially completed batch with stale IDs.
                            }
                            isApplying = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isApplying { ProgressView().controlSize(.small) }
                            Text(isApplying ? "Working…" : "\(request.action.title) segments")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(request.action == .delete ? .retraceDanger : .retraceAccent)
                    .disabled(isLoading || isApplying || plan?.frames.isEmpty != false)
                }
            }
        }
        .padding(24).frame(width: 500)
        .foregroundColor(.retracePrimary)
        .background(Color.retraceBackground)
        .interactiveDismissDisabled(isApplying)
        .task {
            do {
                plan = try await viewModel.prepareUsageAction(target: request.target, action: request.action)
            } catch {
                errorText = "Could not load matching segments. \(error.localizedDescription)"
            }
            isLoading = false
        }
    }
}
