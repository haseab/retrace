import Foundation
import SwiftUI
import Shared

struct DebugFrameIDBadge: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var showCopiedFeedback = false
    @State private var isHovering = false

    private var renderedMediaText: String {
        if viewModel.currentFrameStillDisplayMode == .waitingFallback {
            return viewModel.currentFrameStillUsesFreshCaptureSource ? "live still (fallback)" : "decoded still (fallback)"
        }

        if viewModel.isInLiveMode {
            return viewModel.liveScreenshot != nil ? "live still" : "--"
        }

        switch viewModel.currentFrameMediaDisplayMode {
        case .still:
            return viewModel.currentFrameStillUsesFreshCaptureSource ? "live still" : "decoded still"
        case .decodedVideo:
            return "decoded video"
        case .noContent:
            return "--"
        }
    }

    private var renderedMediaColor: Color {
        if viewModel.currentFrameStillDisplayMode == .waitingFallback {
            return viewModel.currentFrameStillUsesFreshCaptureSource ? .blue.opacity(0.9) : .orange.opacity(0.85)
        }

        if viewModel.isInLiveMode {
            return viewModel.liveScreenshot != nil ? .blue.opacity(0.9) : .white.opacity(0.5)
        }

        switch viewModel.currentFrameMediaDisplayMode {
        case .still:
            return viewModel.currentFrameStillUsesFreshCaptureSource ? .blue.opacity(0.9) : .green.opacity(0.85)
        case .decodedVideo:
            return .cyan.opacity(0.9)
        case .noContent:
            return .white.opacity(0.5)
        }
    }

    private var videoReencodeText: String {
        guard let videoInfo = viewModel.currentVideoInfo else { return "n/a" }
        return videoInfo.isVideoReencoded ? "yes" : "no"
    }

    private var videoReencodeColor: Color {
        guard let videoInfo = viewModel.currentVideoInfo else { return .blue.opacity(0.8) }
        return videoInfo.isVideoReencoded ? .green.opacity(0.85) : .white.opacity(0.75)
    }

    private var bitrateText: String {
        guard let videoInfo = viewModel.currentVideoInfo,
              let bitsPerSecond = videoInfo.averageBitrateBitsPerSecond,
              bitsPerSecond.isFinite,
              bitsPerSecond > 0 else {
            return "--"
        }

        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.2f Mbps", bitsPerSecond / 1_000_000)
        }

        return String(format: "%.0f kbps", bitsPerSecond / 1_000)
    }

    private var kibPerFrameText: String {
        guard let videoInfo = viewModel.currentVideoInfo,
              let kibPerFrame = videoInfo.kibibytesPerFrame,
              kibPerFrame.isFinite,
              kibPerFrame > 0 else {
            return "--"
        }

        return String(format: "%.1f", kibPerFrame)
    }

    var body: some View {
        Button(action: {
            viewModel.copyCurrentFrameID()
            showCopiedFeedback = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopiedFeedback = false
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                    .font(.retraceTinyMedium)
                    .foregroundColor(showCopiedFeedback ? .green : .white.opacity(0.7))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Frame ID")
                        .font(.retraceTinyMedium)
                        .foregroundColor(.white.opacity(0.5))

                    if let frame = viewModel.currentFrame {
                        Text(showCopiedFeedback ? "Copied!" : String(frame.id.value))
                            .font(.retraceMonoSmall)
                            .foregroundColor(showCopiedFeedback ? .green : .white)
                    } else {
                        Text("--")
                            .font(.retraceMonoSmall)
                            .foregroundColor(.white.opacity(0.5))
                    }

                    if let videoInfo = viewModel.currentVideoInfo {
                        Text("VidIdx: \(videoInfo.frameIndex)")
                            .font(.retraceMonoSmall)
                            .foregroundColor(.orange.opacity(0.8))

                        Text("Bitrate: \(bitrateText)")
                            .font(.retraceMonoSmall)
                            .foregroundColor(.white.opacity(0.85))

                        Text("KiB/f: \(kibPerFrameText)")
                            .font(.retraceMonoSmall)
                            .foregroundColor(.white.opacity(0.78))
                    }

                    if let timelineFrame = viewModel.currentTimelineFrame {
                        let status = timelineFrame.processingStatus
                        let statusText = switch status {
                        case -1: "N/A (Rewind)"
                        case 0: "pending"
                        case 1: "processing"
                        case 2: "completed"
                        case 3: "failed"
                        case 4: "not readable"
                        case 5: "rewrite pending"
                        case 6: "rewrite processing"
                        case 7: "rewrite completed"
                        case 8: "rewrite failed"
                        default: "unknown"
                        }
                        Text("p=\(status) (\(statusText))")
                            .font(.retraceMonoSmall)
                            .foregroundColor(
                                status == -1 ? .blue.opacity(0.8)
                                : (status == 4 || status == 3 || status == 8) ? .red.opacity(0.8)
                                : (status == 2 || status == 7) ? .green.opacity(0.8)
                                : .yellow.opacity(0.8)
                            )
                    }

                    Text("Re-encoded: \(videoReencodeText)")
                        .font(.retraceMonoSmall)
                        .foregroundColor(videoReencodeColor)

                    Text("Shown: \(renderedMediaText)")
                        .font(.retraceMonoSmall)
                        .foregroundColor(renderedMediaColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.15).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovering ? Color.white.opacity(0.3) : Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("Click to copy frame ID")
    }
}

struct DebugBrowserURLWindow: View {
    let browserURL: String?
    @Binding var panelPosition: CGSize
    @Binding var isPresented: Bool

    @GestureState private var dragOffset: CGSize = .zero
    @State private var isDraggingHeader = false
    @State private var isCloseHovered = false

    private var wrappedURLText: String {
        guard let browserURL else { return "No browser URL on this frame" }
        return Self.wrapText(browserURL, maxCharactersPerLine: 100)
    }

    private var hasURL: Bool { browserURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.cyan.opacity(0.9))

                Text("Browser URL")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))

                Spacer()

                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isPresented = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isCloseHovered ? .white.opacity(0.9) : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCloseHovered = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.06))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onChanged { _ in
                        if !isDraggingHeader {
                            isDraggingHeader = true
                        }
                    }
                    .onEnded { value in
                        panelPosition.width += value.translation.width
                        panelPosition.height += value.translation.height
                        isDraggingHeader = false
                    }
            )
            .onHover { hovering in
                if hovering && !isDraggingHeader {
                    NSCursor.openHand.push()
                } else if !hovering {
                    NSCursor.pop()
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: true) {
                Text(wrappedURLText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(hasURL ? .cyan.opacity(0.95) : .white.opacity(0.6))
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 170)
        }
        .frame(width: 720, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.1).opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .offset(x: panelPosition.width + dragOffset.width, y: panelPosition.height + dragOffset.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.spacingL)
    }

    private static func wrapText(_ text: String, maxCharactersPerLine: Int) -> String {
        guard maxCharactersPerLine > 0, !text.isEmpty else { return text }

        var lines: [String] = []
        var currentStart = text.startIndex
        while currentStart < text.endIndex {
            let nextEnd = text.index(currentStart, offsetBy: maxCharactersPerLine, limitedBy: text.endIndex) ?? text.endIndex
            lines.append(String(text[currentStart..<nextEnd]))
            currentStart = nextEnd
        }
        return lines.joined(separator: "\n")
    }
}

struct OCRStatusIndicator: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel

    private var shouldShow: Bool { viewModel.ocrStatus.isInProgress }

    private var statusIcon: String {
        switch viewModel.ocrStatus.state {
        case .pending:
            return "clock"
        case .queued:
            return "tray.and.arrow.down"
        case .processing:
            return "gearshape.2"
        case .rewriting:
            return "eye.slash"
        default:
            return "doc.text"
        }
    }

    private var statusColor: Color {
        switch viewModel.ocrStatus.state {
        case .pending:
            return .gray
        case .queued:
            return .orange
        case .processing:
            return .blue
        case .rewriting:
            return .orange
        case .failed:
            return .red
        default:
            return .gray
        }
    }

    var body: some View {
        if shouldShow {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.retraceTinyMedium)
                    .foregroundColor(statusColor)

                Text(viewModel.ocrStatus.displayText)
                    .font(.retraceTinyMedium)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.15).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(statusColor.opacity(0.4), lineWidth: 0.5)
            )
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .animation(.easeInOut(duration: 0.2), value: viewModel.ocrStatus)
        }
    }
}

#if DEBUG
struct DeveloperActionsMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let onClose: () -> Void
    @State private var isHovering = false
    @State private var showReprocessFeedback = false
    @AppStorage("showFrameIDs", store: fullscreenTimelineSettingsStore) private var showFrameCard = SettingsDefaults.showFrameIDs

    private var canReprocess: Bool {
        viewModel.currentFrame?.source == .native
    }

    var body: some View {
        Menu {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.toggleFrameIDBadgeVisibilityFromDevMenu()
                }
            }) {
                Label(showFrameCard ? "Hide Frame Card" : "Show Frame Card", systemImage: "info.square")
            }

            Divider()

            Button(action: {
                Task {
                    do {
                        try await viewModel.reprocessCurrentFrameOCR()
                        showReprocessFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showReprocessFeedback = false
                        }
                    } catch {
                        Log.error("[OCR] Failed to reprocess OCR: \(error)", category: .ui)
                    }
                }
            }) {
                Label(showReprocessFeedback ? "Queued" : "Refresh OCR", systemImage: showReprocessFeedback ? "checkmark" : "arrow.clockwise")
            }
            .disabled(!canReprocess)

            Divider()

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.toggleVideoBoundariesVisibility()
                }
            }) {
                Label(
                    viewModel.showVideoBoundaries ? "Hide Video Placements" : "Show Video Placements",
                    systemImage: "film"
                )
            }

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.toggleSegmentBoundariesVisibility()
                }
            }) {
                Label(
                    viewModel.showSegmentBoundaries ? "Hide Segment Placements" : "Show Segment Placements",
                    systemImage: "square.stack.3d.down.forward"
                )
            }

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.toggleBrowserURLDebugWindowVisibility()
                }
            }) {
                Label(
                    viewModel.showBrowserURLDebugWindow ? "Hide Browser URL Window" : "Show Browser URL Window",
                    systemImage: "link"
                )
            }

            Divider()

            Button(action: {
                guard let videoInfo = viewModel.currentVideoInfo else { return }
                let originalPath = videoInfo.videoPath
                let timeInSeconds = videoInfo.timeInSeconds

                onClose()

                Task.detached(priority: .userInitiated) {
                    try? await Task.sleep(for: .milliseconds(200), clock: .continuous)

                    let tempDir = FileManager.default.temporaryDirectory
                    let filename = (originalPath as NSString).lastPathComponent
                    let tempURL = tempDir.appendingPathComponent("\(filename).mp4")

                    do {
                        if FileManager.default.fileExists(atPath: tempURL.path) {
                            try FileManager.default.removeItem(at: tempURL)
                        }
                        try FileManager.default.linkItem(atPath: originalPath, toPath: tempURL.path)
                    } catch {
                        Log.error("[Dev] Failed to create hard link for video: \(error)", category: .ui)
                        return
                    }

                    do {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        process.arguments = DeveloperActionsMenu.quickTimeOpenScriptLines(path: tempURL.path, timeInSeconds: timeInSeconds)
                            .flatMap { ["-e", $0] }
                        try process.run()
                        process.waitUntilExit()

                        if process.terminationStatus != 0 {
                            Log.error("[Dev] osascript exited with status \(process.terminationStatus) while opening video", category: .ui)
                        }
                    } catch {
                        Log.error("[Dev] Failed to run osascript for video open: \(error)", category: .ui)
                    }
                }
            }) {
                Label("Open Video File", systemImage: "play.rectangle")
            }
            .disabled(viewModel.currentVideoInfo == nil)

        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ant.fill")
                    .font(.retraceTinyMedium)
                    .foregroundColor(.orange)
                Text("Dev")
                    .font(.retraceTinyMedium)
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.15).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovering ? Color.orange.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    nonisolated private static func quickTimeOpenScriptLines(path: String, timeInSeconds: Double) -> [String] {
        let escapedPath = escapeAppleScriptString(path)
        let safeTime = max(0, timeInSeconds)
        return [
            "tell application \"QuickTime Player\"",
            "activate",
            "open POSIX file \"\(escapedPath)\"",
            "delay 0.5",
            "tell front document",
            "set current time to \(safeTime)",
            "end tell",
            "end tell"
        ]
    }

    nonisolated private static func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif
