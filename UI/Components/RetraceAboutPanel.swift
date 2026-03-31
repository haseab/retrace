import AppKit
import SwiftUI

@MainActor
enum RetraceAboutPanel {
    static func makeWindow(appName: String) -> NSWindow {
        let hostingController = NSHostingController(rootView: RetraceAboutView(appName: appName))
        let window = NSWindow(contentViewController: hostingController)

        window.title = "About \(appName)"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 420, height: 320))
        window.minSize = NSSize(width: 420, height: 320)
        window.maxSize = NSSize(width: 420, height: 320)
        window.center()
        window.backgroundColor = NSColor(named: "retraceBackground") ?? NSColor.windowBackgroundColor
        window.appearance = NSAppearance(named: .darkAqua)

        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        return window
    }
}

private struct RetraceAboutView: View {
    let appName: String

    private var commitLabel: String? {
        let commit = BuildInfo.gitCommit.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit == "unknown" || commit.isEmpty ? nil : commit
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

            VStack(spacing: 6) {
                Text(appName)
                    .font(.system(size: 26, weight: .semibold))

                Text(BuildInfo.fullVersion)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if BuildInfo.buildDate != "unknown" {
                    Text("Built \(BuildInfo.buildDate)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            VStack(spacing: 8) {
                if let commitLabel, let commitURL = BuildInfo.commitURL {
                    Link(destination: commitURL) {
                        Label("Commit \(commitLabel)", systemImage: "arrow.up.right.square")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }

                if let branch = BuildInfo.displayBranch {
                    Text(branch)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
