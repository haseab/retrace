import AppKit
import SwiftUI
import App
import Shared

@MainActor
final class StandaloneCommentComposerWindowController: NSObject {
    static let shared = StandaloneCommentComposerWindowController()

    private static let settingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard
    nonisolated static let windowTitle = "Quick Comment"
    nonisolated private static let legacyCaptureExcludedWindowTitles: Set<String> = ["Add Quick Comment"]
    private static let expandedContentSize = NSSize(width: 482, height: 365)
    private static let collapsedContentSize = NSSize(width: 482, height: 278)
    static let windowCornerRadius: CGFloat = 16
    static let rootHorizontalPadding: CGFloat = 16
    static let rootVerticalPadding: CGFloat = 15
    static let rootContentWidth: CGFloat = expandedContentSize.width - (rootHorizontalPadding * 2)
    private static let windowStyleMask: NSWindow.StyleMask = [.borderless]
    private static let windowPositionCacheExpiry: TimeInterval = 60
    private static let isWindowPositionCachingEnabled = true
    private static let liveRefreshInterval: Duration = .seconds(2)
    private static let contextPreviewCollapsedDefaultsKey = "quickCommentContextPreviewCollapsed"

    private struct CachedWindowOrigin {
        let origin: CGPoint
        let savedAt: Date
    }

    private var coordinator: AppCoordinator?
    private var window: NSWindow?
    private var hostingController: NSHostingController<StandaloneQuickCommentView>?
    private var viewModel: QuickCommentComposerViewModel?
    private var presentationTask: Task<Void, Never>?
    private var liveRefreshTask: Task<Void, Never>?
    private var cachedWindowOrigin: CachedWindowOrigin?
    private var activeQuickCommentSource = "global_hotkey_comment"
    private var isRefreshingLiveTarget = false
    private var lastStableWindowOrigin: CGPoint?
    private var hasRecordedQuickCommentOpenMetric = false

    private(set) var isVisible = false
    private(set) var isPresentationPending = false

    private static func contentSize(isContextPreviewCollapsed: Bool) -> NSSize {
        isContextPreviewCollapsed ? collapsedContentSize : expandedContentSize
    }

    private static var persistedContentSize: NSSize {
        contentSize(
            isContextPreviewCollapsed: settingsStore.bool(forKey: contextPreviewCollapsedDefaultsKey)
        )
    }

    nonisolated static func isSelfCaptureCandidate(
        appBundleID: String?,
        windowName: String?
    ) -> Bool {
        guard let normalizedWindowName = normalizedCaptureExcludedWindowName(windowName) else {
            return false
        }
        let retraceBundleIdentifier = Bundle.main.bundleIdentifier ?? "io.retrace.app"
        let isRetraceWindow = appBundleID == retraceBundleIdentifier || appBundleID == "io.retrace.app"
        guard isRetraceWindow else { return false }

        let excludedWindowNames = Set(
            ([windowTitle] + Array(legacyCaptureExcludedWindowTitles))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        return excludedWindowNames.contains(normalizedWindowName)
    }

    nonisolated private static func normalizedCaptureExcludedWindowName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    func configure(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func openCommentComposerAtCurrentMoment(source: String = "global_hotkey_comment") {
        guard let coordinator else {
            Log.warning("[QuickComment] Missing coordinator while opening comment composer", category: .ui)
            return
        }

        if isVisible {
            close()
            return
        }

        if isPresentationPending {
            cancelPendingPresentation()
            return
        }

        isPresentationPending = true
        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.presentStandaloneCommentComposer(coordinator: coordinator, source: source)
        }
    }

    func close() {
        presentationTask?.cancel()
        presentationTask = nil
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        isPresentationPending = false

        guard let window else {
            cleanupPresentationState()
            return
        }

        if hasRecordedQuickCommentOpenMetric, let coordinator {
            DashboardViewModel.recordQuickCommentClosed(
                coordinator: coordinator,
                source: activeQuickCommentSource
            )
        }

        cacheWindowOrigin(from: lastStableWindowOrigin ?? window.frame.origin)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                window.orderOut(nil)
                self.window?.contentViewController = nil
                self.hostingController = nil
                self.window = nil
                self.viewModel = nil
                self.cleanupPresentationState()
                Log.info("[GhostAppCheck] quick comment composer hidden appHidden=\(NSApp.isHidden) appActive=\(NSApp.isActive)", category: .ui)
            }
        })
    }

    private func presentStandaloneCommentComposer(
        coordinator: AppCoordinator,
        source: String
    ) async {
        defer {
            presentationTask = nil
            if !isVisible {
                isPresentationPending = false
            }
        }

        guard let targetScreen = targetScreenForCurrentCursor() else {
            Log.warning("[QuickComment] Failed to resolve target screen", category: .ui)
            return
        }

        let viewModel = QuickCommentComposerViewModel(coordinator: coordinator, source: source)
        self.viewModel = viewModel
        activeQuickCommentSource = source
        showWindow(on: targetScreen, viewModel: viewModel)

        let didPrepare = await viewModel.prepareInitialTarget()
        guard !Task.isCancelled else { return }
        guard didPrepare else {
            close()
            return
        }

        DashboardViewModel.recordQuickCommentOpened(
            coordinator: coordinator,
            source: source
        )
        hasRecordedQuickCommentOpenMetric = true
        startLiveRefreshLoop(viewModel: viewModel)

        let frameID = viewModel.target?.frameID.value ?? -1
        let segmentID = viewModel.target?.segmentID.value ?? -1
        Log.info(
            "[QuickComment] Opened source=\(source) frameID=\(frameID) segmentID=\(segmentID)",
            category: .ui
        )
    }

    private func showWindow(on screen: NSScreen, viewModel: QuickCommentComposerViewModel) {
        let window = createWindow(for: screen)
        let contentView = StandaloneQuickCommentView(
            viewModel: viewModel,
            onContextPreviewCollapsedChange: { [weak self] isCollapsed in
                self?.updateWindowSize(isContextPreviewCollapsed: isCollapsed, animated: true)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        let hostingController = NSHostingController(rootView: contentView)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = []
        }
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 10.15, *) {
            hostingController.view.layer?.cornerCurve = .continuous
        }
        hostingController.view.layer?.cornerRadius = Self.windowCornerRadius
        hostingController.view.layer?.masksToBounds = true
        let pinnedOrigin = window.frame.origin
        window.contentViewController = hostingController
        applyRoundedWindowMask(to: window)
        let preferredContentSize = Self.persistedContentSize
        window.setContentSize(preferredContentSize)
        window.minSize = preferredContentSize
        window.maxSize = preferredContentSize
        window.setFrameOrigin(pinnedOrigin)

        self.window = window
        self.hostingController = hostingController
        self.isVisible = true
        self.isPresentationPending = false

        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        lastStableWindowOrigin = window.frame.origin

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func createWindow(for screen: NSScreen) -> NSWindow {
        let window = KeyableWindow(
            contentRect: initialWindowRect(on: screen),
            styleMask: Self.windowStyleMask,
            backing: .buffered,
            defer: false
        )

        window.title = Self.windowTitle
        window.level = .floating
        window.animationBehavior = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.sharingType = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .participatesInCycle]
        window.tabbingMode = .disallowed
        let preferredContentSize = Self.persistedContentSize
        window.minSize = preferredContentSize
        window.maxSize = preferredContentSize
        window.onEscape = { [weak self] in
            self?.close()
        }
        window.delegate = self

        return window
    }

    private func applyRoundedWindowMask(to window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 10.15, *) {
            contentView.layer?.cornerCurve = .continuous
        }
        contentView.layer?.cornerRadius = Self.windowCornerRadius
        contentView.layer?.masksToBounds = true
    }

    private func initialWindowRect(on screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let frameSize = Self.persistedContentSize
        let cachedOrigin = cachedOrigin(frameSize: frameSize)
        let origin = cachedOrigin ?? CGPoint(
            x: visibleFrame.midX - (frameSize.width / 2),
            y: visibleFrame.midY - (frameSize.height / 2)
        )
        return NSRect(origin: origin, size: frameSize)
    }

    private func updateWindowSize(isContextPreviewCollapsed: Bool, animated: Bool) {
        guard let window else { return }

        let targetSize = Self.contentSize(isContextPreviewCollapsed: isContextPreviewCollapsed)
        let currentSize = window.frame.size
        guard abs(currentSize.height - targetSize.height) > 0.5 || abs(currentSize.width - targetSize.width) > 0.5 else {
            return
        }

        let currentFrame = window.frame
        let heightDelta = currentFrame.height - targetSize.height
        let targetOrigin = CGPoint(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + heightDelta
        )
        let targetFrame = NSRect(origin: targetOrigin, size: targetSize)

        window.minSize = targetSize
        window.maxSize = targetSize

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        } else {
            window.setFrame(targetFrame, display: true)
        }

        lastStableWindowOrigin = targetOrigin
    }

    private func startLiveRefreshLoop(viewModel: QuickCommentComposerViewModel) {
        liveRefreshTask?.cancel()
        liveRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: Self.liveRefreshInterval, clock: .continuous)
                guard !Task.isCancelled else { return }
                guard self.isVisible, self.window != nil, self.viewModel === viewModel else { return }
                _ = await self.performStandaloneRefreshIfNeeded(viewModel: viewModel)
            }
        }
    }

    private func performStandaloneRefreshIfNeeded(
        viewModel: QuickCommentComposerViewModel
    ) async -> Bool {
        guard !isRefreshingLiveTarget else { return false }
        guard !viewModel.shouldFreezeLiveRefresh else { return false }

        isRefreshingLiveTarget = true
        defer { isRefreshingLiveTarget = false }

        return await viewModel.refreshTarget()
    }

    private func cachedOrigin(frameSize: CGSize) -> CGPoint? {
        guard Self.isWindowPositionCachingEnabled else { return nil }
        guard let cachedWindowOrigin else { return nil }
        guard Date().timeIntervalSince(cachedWindowOrigin.savedAt) <= Self.windowPositionCacheExpiry else {
            self.cachedWindowOrigin = nil
            return nil
        }

        let cachedFrame = CGRect(origin: cachedWindowOrigin.origin, size: frameSize)
        let isVisibleOnAnyScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(cachedFrame)
        }
        guard isVisibleOnAnyScreen else {
            self.cachedWindowOrigin = nil
            return nil
        }

        return cachedWindowOrigin.origin
    }

    private func cacheWindowOrigin(from origin: CGPoint) {
        guard Self.isWindowPositionCachingEnabled else { return }
        cachedWindowOrigin = CachedWindowOrigin(origin: origin, savedAt: Date())
    }

    private func cancelPendingPresentation() {
        presentationTask?.cancel()
        presentationTask = nil
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        isPresentationPending = false
        viewModel = nil
    }

    private func cleanupPresentationState() {
        isVisible = false
        isPresentationPending = false
        isRefreshingLiveTarget = false
        lastStableWindowOrigin = nil
        hasRecordedQuickCommentOpenMetric = false
    }

    private func targetScreenForCurrentCursor() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
    }
}

extension StandaloneCommentComposerWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedWindow = notification.object as? NSWindow, movedWindow === window else { return }
        lastStableWindowOrigin = movedWindow.frame.origin
    }
}
