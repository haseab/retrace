import SwiftUI
import Shared
import App

/// Timeline tape view that scrolls horizontally with a fixed center playhead
/// Groups consecutive frames by app and displays app icons
public struct TimelineTapeView: View {

    // MARK: - Properties

    @ObservedObject var viewModel: SimpleTimelineViewModel
    let width: CGFloat

    // Tape dimensions
    private let tapeHeight: CGFloat = 40
    private let blockSpacing: CGFloat = 2
    private let pixelsPerFrame: CGFloat = 8.0

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Background
            Rectangle()
                .fill(Color.black.opacity(0.85))

            // Scrollable tape content
            tapeContent

            // Fixed center playhead (on top of everything)
            playhead
        }
        .frame(height: tapeHeight)
    }

    // MARK: - Tape Content

    private var tapeContent: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let blocks = viewModel.appBlocks

            // Calculate offset to center current frame
            let currentFrameOffset = offsetForFrame(viewModel.currentIndex, in: blocks)
            let tapeOffset = centerX - currentFrameOffset
            let _ = print("[Tape] currentIndex=\(viewModel.currentIndex), offset=\(tapeOffset), blocks=\(blocks.count)")

            HStack(spacing: blockSpacing) {
                ForEach(blocks) { block in
                    appBlockView(block: block)
                }
            }
            .offset(x: tapeOffset)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: viewModel.currentIndex)
        }
    }

    // MARK: - App Block View

    private func appBlockView(block: AppBlock) -> some View {
        let isCurrentBlock = viewModel.currentIndex >= block.startIndex && viewModel.currentIndex <= block.endIndex
        let color = blockColor(for: block)

        return ZStack {
            // Background block
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: block.width, height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isCurrentBlock ? Color.white : Color.clear, lineWidth: 1.5)
                )
                .opacity(isCurrentBlock ? 1.0 : 0.7)

            // App icon (only show if block is wide enough)
            if block.width > 40, let bundleID = block.bundleID {
                appIcon(for: bundleID)
                    .frame(width: 22, height: 22)
            }
        }
    }

    // MARK: - Helper Functions

    /// Calculate the horizontal offset for a given frame index
    private func offsetForFrame(_ frameIndex: Int, in blocks: [AppBlock]) -> CGFloat {
        var offset: CGFloat = 0
        var blockCount = 0

        for block in blocks {
            if frameIndex >= block.startIndex && frameIndex <= block.endIndex {
                // Frame is in this block - calculate exact pixel position within block
                let framePositionInBlock = frameIndex - block.startIndex
                // Add spacing for all blocks before this one
                let spacingBeforeBlock = CGFloat(blockCount) * blockSpacing
                // Add exact pixel position within this block (centered on the frame's pixel)
                offset += CGFloat(framePositionInBlock) * pixelsPerFrame + pixelsPerFrame / 2 + spacingBeforeBlock
                break
            } else {
                // Add full block width (spacing handled separately)
                offset += block.width
                blockCount += 1
            }
        }

        return offset
    }

    private func blockColor(for block: AppBlock) -> Color {
        if let bundleID = block.bundleID {
            return Color.sessionColor(for: bundleID)
        }
        return Color.gray.opacity(0.5)
    }

    private func appIcon(for bundleID: String) -> some View {
        Group {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Fallback icon
                Image(systemName: "app.fill")
                    .resizable()
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Fixed Playhead

    private var playhead: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2

            // Playhead indicator (fixed at center) - Rewind style
            VStack(spacing: 0) {
                // Date and timestamp above the line
                VStack(spacing: 2) {
                    Text(viewModel.currentDateString)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))

                    Text(viewModel.currentTimeString)
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.7))
                )
                .offset(y: -8) // Slight offset above the tape

                // Simple white vertical line (thicker and taller)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 3, height: tapeHeight * 2.5)
            }
            .position(x: centerX, y: tapeHeight / 2)
        }
    }

}

// MARK: - Preview

#if DEBUG
struct TimelineTapeView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            TimelineTapeView(
                viewModel: SimpleTimelineViewModel(coordinator: AppCoordinator()),
                width: 800
            )
        }
        .frame(width: 800, height: 100)
    }
}
#endif
