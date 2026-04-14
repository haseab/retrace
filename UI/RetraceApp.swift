import SwiftUI
import App
import CrashRecoverySupport
import Shared
import Database
import SQLCipher
import Darwin
import IOKit.ps
import ObjectiveC.runtime
import UniformTypeIdentifiers

enum SingleInstanceLock {
    enum AcquireResult {
        case alreadyHeld(descriptor: CInt)
        case acquired(descriptor: CInt)
        case heldByAnotherProcess
        case error(code: Int32)
    }

    static func acquire(
        atPath path: String,
        existingDescriptor: CInt = -1,
        processID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> AcquireResult {
        if existingDescriptor >= 0 {
            return .alreadyHeld(descriptor: existingDescriptor)
        }

        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if fd == -1 {
            return .error(code: errno)
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            close(fd)

            if lockError == EWOULDBLOCK {
                return .heldByAnotherProcess
            }

            return .error(code: lockError)
        }

        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        let pidString = "\(processID)\n"
        pidString.withCString { pidCString in
            _ = write(fd, pidCString, strlen(pidCString))
        }

        return .acquired(descriptor: fd)
    }

    static func release(descriptor: inout CInt) {
        guard descriptor >= 0 else { return }

        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
enum SingleInstanceLockRetryResult: Equatable {
    case acquired(descriptor: CInt, attempts: Int)
    case failedHeldByAnotherProcess(attempts: Int)
    case failedError(code: Int32, attempts: Int)
}

enum SingleInstanceLockRetrier {
    static func acquire(
        maxAttempts: Int,
        retryDelay: Duration,
        existingDescriptor: CInt = -1,
        acquire: (CInt) -> SingleInstanceLock.AcquireResult,
        sleep: (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration, clock: .continuous)
        }
    ) async -> SingleInstanceLockRetryResult {
        let attempts = max(maxAttempts, 1)

        for attempt in 1...attempts {
            switch acquire(existingDescriptor) {
            case .alreadyHeld(let descriptor), .acquired(let descriptor):
                return .acquired(descriptor: descriptor, attempts: attempt)

            case .heldByAnotherProcess:
                if attempt == attempts {
                    return .failedHeldByAnotherProcess(attempts: attempt)
                }

            case .error(let code):
                if attempt == attempts {
                    return .failedError(code: code, attempts: attempt)
                }
            }

            await sleep(retryDelay)
        }

        return .failedHeldByAnotherProcess(attempts: attempts)
    }
}

enum TextInputContextMenuAutofillFilter {
    private static var isInstalled = false
    private static let allowedActions: Set<Selector> = [
        #selector(NSText.cut(_:)),
        #selector(NSText.copy(_:)),
        #selector(NSText.paste(_:))
    ]

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        swizzleMenuMethod(on: NSTextField.self, with: #selector(NSTextField.retrace_filteredContextMenu(for:)))
        swizzleMenuMethod(on: NSTextView.self, with: #selector(NSTextView.retrace_filteredContextMenu(for:)))
    }

    static func filteredMenu(from menu: NSMenu?) -> NSMenu? {
        guard let menu else { return nil }
        filterAllowedItems(from: menu)
        return menu
    }

    private static func swizzleMenuMethod(on cls: AnyClass, with swizzledSelector: Selector) {
        let originalSelector = #selector(NSView.menu(for:))
        guard let originalMethod = class_getInstanceMethod(cls, originalSelector),
              let swizzledMethod = class_getInstanceMethod(cls, swizzledSelector) else {
            return
        }

        let didAddMethod = class_addMethod(
            cls,
            originalSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod {
            class_replaceMethod(
                cls,
                swizzledSelector,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    static func filterAllowedItems(from menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                filterAllowedItems(from: submenu)
            }
        }

        for index in menu.items.indices.reversed() where shouldRemove(menu.items[index]) {
            menu.removeItem(at: index)
        }

        collapseRedundantSeparators(in: menu)
    }

    private static func shouldRemove(_ item: NSMenuItem) -> Bool {
        guard !item.isSeparatorItem else {
            return false
        }

        guard let action = item.action else {
            return true
        }

        return !allowedActions.contains(action)
    }

    private static func collapseRedundantSeparators(in menu: NSMenu) {
        var previousWasSeparator = true
        var indexesToRemove: [Int] = []

        for (index, item) in menu.items.enumerated() {
            if item.isSeparatorItem {
                if previousWasSeparator {
                    indexesToRemove.append(index)
                }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
        }

        if let lastIndex = menu.items.indices.last,
           menu.items[lastIndex].isSeparatorItem {
            indexesToRemove.append(lastIndex)
        }

        for index in Set(indexesToRemove).sorted(by: >) {
            menu.removeItem(at: index)
        }
    }
}

private extension NSTextField {
    @objc func retrace_filteredContextMenu(for event: NSEvent) -> NSMenu? {
        TextInputContextMenuAutofillFilter.filteredMenu(from: retrace_filteredContextMenu(for: event))
    }
}

private extension NSTextView {
    @objc func retrace_filteredContextMenu(for event: NSEvent) -> NSMenu? {
        TextInputContextMenuAutofillFilter.filteredMenu(from: retrace_filteredContextMenu(for: event))
    }
}

/// Main app entry point
@main
struct RetraceApp: App {

    // MARK: - Properties

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Body

    var body: some Scene {
        // Windows are managed manually via window controllers.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // Remove "New Window" because window creation is managed by dedicated controllers.
            }
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    @MainActor static private(set) var isApplicationTerminating = false

    enum LaunchMode: Equatable {
        case fresh
        case relaunch
    }

    enum LaunchGateAction: Equatable {
        case continueLaunch
        case activateExistingInstanceAndExitDuplicate
        case exitDueToLockFailure
    }

    var menuBarManager: MenuBarManager?
    private var coordinatorWrapper: AppCoordinatorWrapper?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var powerSettingsApplyTask: Task<Void, Never>?
    private var powerSettingsObserver: NSObjectProtocol?
    private var lowPowerModeObserver: NSObjectProtocol?
    private var pendingPowerSettingsSnapshot: OCRPowerSettingsSnapshot?
    private var wasRecordingBeforeSleep = false
    private var lastKnownPowerSource: PowerStateMonitor.PowerSource?
    private var lastKnownLowPowerMode: Bool?
    private var isHandlingSystemSleep = false
    private var isHandlingSystemWake = false
    private var pendingDeeplinkURLs: [URL] = []
    private var shouldShowDashboardAfterInitialization = false
    private var isActivationRevealInFlight = false
    private var isInitialized = false
    private var isTerminationFlushInProgress = false
    private var isTerminationDecisionInProgress = false
    private var bypassQuitConfirmationPromptOnce = false
    private var singleInstanceLockFileDescriptor: CInt = -1
    private var aboutWindowController: NSWindowController?
    private let settingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard
    private static let devDeeplinkEnvKey = "RETRACE_DEV_DEEPLINK_URL"
    private static let externalDashboardRevealNotification = Notification.Name("io.retrace.app.externalDashboardReveal")
    private static let quitConfirmationPreferenceKey = "quitConfirmationPreference"
    private static let showDockIconPreferenceKey = "showDockIcon"
    private static let dashboardShortcutDefaultsKey = "dashboardShortcutConfig"
    private static let recordingShortcutDefaultsKey = "recordingShortcutConfig"
    private static let systemMonitorShortcutDefaultsKey = "systemMonitorShortcutConfig"
    private static let canonicalBundleIdentifier = "io.retrace.app"
    private static let singleInstanceLockPath = "/tmp/io.retrace.app.instance.lock"
    private static let relaunchLockRetryAttempts = 30
    private static let singleInstanceLockRetryDelay: Duration = .milliseconds(100)
    nonisolated private static let watchdogSleepSuspensionSeconds: TimeInterval = 12 * 60 * 60
    nonisolated private static let watchdogWakeGracePeriodSeconds: TimeInterval = 60
    private enum QuitTerminationPreference: String {
        case ask
        case quit
        case runInBackground
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check if another instance is already running. Relaunches still need to
        // reacquire the lock during handoff, but fresh launches should decide immediately.
        let isRelaunch = UserDefaults.standard.bool(forKey: "isRelaunching")
        let restartDebuggingSession = CrashRecoverySupport.beginRestartDebuggingSession()
        let launchTargetDescription: String
        switch CrashRecoverySupport.currentLaunchTarget() {
        case .appBundle(let url):
            launchTargetDescription = "appBundle(\(url.path))"
        case .executable(let url):
            launchTargetDescription = "executable(\(url.path))"
        case nil:
            launchTargetDescription = "nil"
        }
        Log.info(
            CrashRecoverySupport.restartDebuggingTagged("[AppDelegate] applicationDidFinishLaunching mode=\(isRelaunch ? "relaunch" : "fresh") launchedFromCrashRecovery=\(CrashRecoveryManager.shared.launchedFromCrashRecovery) crashRecoverySource=\(CrashRecoveryManager.shared.recoveryLaunchSource?.rawValue ?? "nil") launchTarget=\(launchTargetDescription) uptimeS=\(Int(ProcessInfo.processInfo.systemUptime.rounded())) reusedPendingSession=\(restartDebuggingSession.reusedPendingSession)"),
            category: .app
        )
        if isRelaunch {
            Log.info(
                CrashRecoverySupport.restartDebuggingTagged("[AppDelegate] App relaunched successfully"),
                category: .app
            )
            UserDefaults.standard.removeObject(forKey: "isRelaunching")
            Task { @MainActor in
                let singleInstanceLockResult = await self.acquireSingleInstanceLock(
                    maxAttempts: Self.relaunchLockRetryAttempts,
                    reason: "relaunch handoff"
                )

                guard self.handleSingleInstanceLaunchDecision(
                    mode: .relaunch,
                    lockResult: singleInstanceLockResult
                ) else {
                    return
                }

                self.beginPostSingleInstanceLaunchSetup()
            }
            return
        }

        let singleInstanceLockResult = acquireSingleInstanceLockForFreshLaunch()
        guard handleSingleInstanceLaunchDecision(
            mode: .fresh,
            lockResult: singleInstanceLockResult
        ) else {
            return
        }

        beginPostSingleInstanceLaunchSetup()
    }

    private func beginPostSingleInstanceLaunchSetup() {
        TextInputContextMenuAutofillFilter.install()
        setupExternalDashboardRevealObserver()
        setupGhostAppLoggingObservers()
        installMainMenuIfNeeded(force: true)
        applyDockIconVisibilityPreference()
        finishApplicationLaunch()
    }

    private func finishApplicationLaunch() {
        CrashRecoveryManager.shared.armAtLaunch()
        // Configure app appearance
        configureAppearance()

        // Initialize the Sparkle updater for automatic updates
        UpdaterManager.shared.initialize()
        UpdaterManager.shared.checkForUpdatesOnStartup()

        // Start main thread hang detection (writes emergency diagnostics if main thread freezes)
        MainThreadHangDetector.shared.start()

        // Initialize the app coordinator and UI
        Task { @MainActor in
            await initializeApp()

            // Record app launch metric
            if let coordinator = coordinatorWrapper?.coordinator {
                DashboardViewModel.recordAppLaunch(coordinator: coordinator)
                if let source = CrashRecoveryManager.shared.recoveryLaunchSource {
                    DashboardViewModel.recordCrashAutoRestart(
                        coordinator: coordinator,
                        source: source
                    )
                }
            }
        }

        // Note: Permissions are now handled in the onboarding flow
    }

    private func applyDockIconVisibilityPreference() {
        let showDockIcon = settingsStore.object(forKey: Self.showDockIconPreferenceKey) as? Bool ?? true
        let targetPolicy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        let changed = NSApp.setActivationPolicy(targetPolicy)
        let policyName = showDockIcon ? "regular" : "accessory"
        let missingBundleIdentifier = Bundle.main.bundleIdentifier == nil

        Log.info(
            "[LaunchSurface] Applied startup activation policy showDockIcon=\(showDockIcon) policy=\(policyName) changed=\(changed) missingBundleID=\(missingBundleIdentifier)",
            category: .app
        )

        if showDockIcon {
            installMainMenuIfNeeded(force: true)
        }
    }

    func installMainMenuIfNeeded(force: Bool = false) {
        let appName = Self.applicationMenuTitle()
        let menu = Self.makeMainMenu(appName: appName, target: self)

        if force || Self.mainMenuNeedsInstallation(existingMenu: NSApp.mainMenu, expectedTopLevelTitles: Self.topLevelMenuTitles(in: menu)) {
            NSApp.mainMenu = menu
            NSApp.windowsMenu = menu.item(withTitle: "Window")?.submenu
            NSApp.helpMenu = menu.item(withTitle: "Help")?.submenu
        }
    }

    static func applicationMenuTitle(bundle: Bundle = .main) -> String {
        if let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !appName.isEmpty {
            return appName
        }

        if let appName = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String, !appName.isEmpty {
            return appName
        }

        return "Retrace"
    }

    static func topLevelMenuTitles(in menu: NSMenu) -> [String] {
        menu.items.map(\.title)
    }

    static func mainMenuNeedsInstallation(existingMenu: NSMenu?, expectedTopLevelTitles: [String]) -> Bool {
        guard let existingMenu else { return true }
        return topLevelMenuTitles(in: existingMenu) != expectedTopLevelTitles
    }

    static func makeMainMenu(appName: String, target: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu(title: appName)

        func makeTopLevelMenu(_ title: String, submenu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }

        func makeMenuItem(
            _ title: String,
            action: Selector,
            keyEquivalent: String = "",
            modifiers: NSEvent.ModifierFlags = [],
            systemImageName: String? = nil,
            target overrideTarget: AnyObject? = target
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.target = overrideTarget
            item.keyEquivalentModifierMask = modifiers
            if let systemImageName,
               let symbol = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil) {
                symbol.isTemplate = true
                item.image = symbol
            }
            return item
        }

        let appMenu = NSMenu(title: appName)
        appMenu.delegate = target
        target.populateMainAppMenu(appMenu, appName: appName)
        mainMenu.addItem(makeTopLevelMenu(appName, submenu: appMenu))

        let recordingMenu = NSMenu(title: "Recording")
        recordingMenu.delegate = target
        target.populateMainMenuRecording(recordingMenu)
        mainMenu.addItem(makeTopLevelMenu("Recording", submenu: recordingMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            makeMenuItem(
                "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m",
                modifiers: [.command],
                target: nil
            )
        )
        windowMenu.addItem(
            makeMenuItem(
                "Zoom",
                action: #selector(NSWindow.performZoom(_:)),
                target: nil
            )
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            makeMenuItem(
                "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:)),
                target: nil
            )
        )
        mainMenu.addItem(makeTopLevelMenu("Window", submenu: windowMenu))

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(
            makeMenuItem(
                "Get Help...",
                action: #selector(AppDelegate.handleMainMenuOpenFeedback),
                keyEquivalent: "h",
                modifiers: [.command, .shift],
                systemImageName: "exclamationmark.bubble"
            )
        )
        helpMenu.addItem(
            makeMenuItem(
                "Changelog",
                action: #selector(AppDelegate.handleMainMenuOpenChangelog),
                systemImageName: "text.book.closed"
            )
        )
        mainMenu.addItem(makeTopLevelMenu("Help", submenu: helpMenu))

        return mainMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case Self.applicationMenuTitle():
            populateMainAppMenu(menu, appName: Self.applicationMenuTitle())
        case "Recording":
            populateMainMenuRecording(menu)
        default:
            break
        }
    }

    private func populateMainAppMenu(_ menu: NSMenu, appName: String) {
        menu.removeAllItems()
        let dashboardShortcut = OnboardingManager.loadShortcutConfig(
            forKey: Self.dashboardShortcutDefaultsKey,
            fallback: .defaultDashboard
        )
        let systemMonitorShortcut = OnboardingManager.loadShortcutConfig(
            forKey: Self.systemMonitorShortcutDefaultsKey,
            fallback: .defaultSystemMonitor
        )

        menu.addItem(
            makeMainMenuItem(
                "About \(appName)",
                action: #selector(handleMainMenuOpenAbout),
                systemImageName: "info.circle"
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            makeMainMenuItem(
                "Settings...",
                action: #selector(handleMainMenuOpenSettings),
                keyEquivalent: ",",
                modifiers: [.command],
                systemImageName: "gearshape"
            )
        )
        let checkForUpdatesItem = makeMainMenuItem(
            UpdaterManager.shared.isCheckingForUpdates ? "Checking for Updates..." : "Check for Updates...",
            action: #selector(handleMainMenuCheckForUpdates),
            systemImageName: "arrow.down.circle"
        )
        checkForUpdatesItem.isEnabled = !UpdaterManager.shared.isCheckingForUpdates && UpdaterManager.shared.canCheckForUpdates
        menu.addItem(checkForUpdatesItem)
        menu.addItem(.separator())
        menu.addItem(
            makeMainMenuItem(
                TimelineWindowController.shared.isVisible ? "Hide Timeline" : "Show Timeline",
                action: #selector(handleMainMenuToggleTimeline),
                systemImageName: "clock.arrow.circlepath"
            )
        )
        menu.addItem(
            makeMainMenuItem(
                "Search Screen History",
                action: #selector(handleMainMenuOpenSearch),
                systemImageName: "magnifyingglass"
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            makeMainMenuItem(
                LaunchMenuRouting.dashboardIsFrontAndCenter() ? "Hide Dashboard" : "Show Dashboard",
                action: #selector(handleMainMenuToggleDashboard),
                shortcut: dashboardShortcut,
                systemImageName: "rectangle.3.group"
            )
        )
        menu.addItem(
            makeMainMenuItem(
                LaunchMenuRouting.systemMonitorIsFrontAndCenter() ? "Hide System Monitor" : "Show System Monitor",
                action: #selector(handleMainMenuToggleSystemMonitor),
                shortcut: systemMonitorShortcut,
                systemImageName: "waveform.path.ecg"
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            makeMainMenuItem(
                "Quit \(appName)",
                action: #selector(handleMainMenuQuit),
                keyEquivalent: "q",
                modifiers: [.command],
                systemImageName: "xmark.square"
            )
        )
    }

    private func populateMainMenuRecording(_ menu: NSMenu) {
        menu.removeAllItems()
        let recordingShortcut = OnboardingManager.loadShortcutConfig(
            forKey: Self.recordingShortcutDefaultsKey,
            fallback: .defaultRecording
        )

        if recordingIsRunning {
            menu.addItem(
                makeMainMenuItem(
                    "Pause for 5 Minutes",
                    action: #selector(handleMainMenuPauseRecordingFor5Minutes),
                    systemImageName: "timer"
                )
            )
            menu.addItem(
                makeMainMenuItem(
                    "Pause for 30 Minutes",
                    action: #selector(handleMainMenuPauseRecordingFor30Minutes),
                    systemImageName: "timer"
                )
            )
            menu.addItem(
                makeMainMenuItem(
                    "Pause for 60 Minutes",
                    action: #selector(handleMainMenuPauseRecordingFor60Minutes),
                    systemImageName: "timer"
                )
            )
            menu.addItem(.separator())
            menu.addItem(
                makeMainMenuItem(
                    "Stop Recording",
                    action: #selector(handleMainMenuStopRecording),
                    shortcut: recordingShortcut,
                    systemImageName: "stop.circle"
                )
            )
            return
        }

        if timedPauseIsActive, let subtitle = timedPauseSubtitle() {
            let subtitleItem = NSMenuItem(title: subtitle, action: nil, keyEquivalent: "")
            subtitleItem.isEnabled = false
            subtitleItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
            menu.addItem(subtitleItem)
            menu.addItem(
                makeMainMenuItem(
                    "Resume Recording Now",
                    action: #selector(handleMainMenuResumeRecordingNow),
                    shortcut: recordingShortcut,
                    systemImageName: "play.circle"
                )
            )
            menu.addItem(
                makeMainMenuItem(
                    "Turn Off Recording",
                    action: #selector(handleMainMenuStopRecording),
                    systemImageName: "stop.circle"
                )
            )
            return
        }

        menu.addItem(
            makeMainMenuItem(
                "Start Recording",
                action: #selector(handleMainMenuResumeRecordingNow),
                shortcut: recordingShortcut,
                systemImageName: "record.circle"
            )
        )
    }

    private func makeMainMenuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        shortcut: ShortcutConfig? = nil,
        systemImageName: String? = nil
    ) -> NSMenuItem {
        let resolvedKeyEquivalent = shortcut?.menuKeyEquivalent ?? keyEquivalent
        let resolvedModifiers = shortcut?.modifiers.nsModifiers ?? modifiers
        let item = NSMenuItem(title: title, action: action, keyEquivalent: resolvedKeyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = resolvedModifiers
        if let systemImageName,
           let symbol = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil) {
            symbol.isTemplate = true
            item.image = symbol
        }
        return item
    }

    @MainActor
    private func initializeApp() async {
        // Pre-flight check: Ensure custom storage path is accessible (if set)
        let storagePathAvailable = await checkStoragePathAvailable()
        if !storagePathAvailable {
            return // User chose to quit or we're waiting for them to reconnect
        }

        do {
            let wrapper = AppCoordinatorWrapper()
            self.coordinatorWrapper = wrapper
            try await wrapper.initialize(autoStartRecording: false)
            Log.info("[AppDelegate] Coordinator initialized successfully", category: .app)

            configureWatchdogAutoQuit()

            // Start the main thread watchdog to detect UI freezes
            MainThreadWatchdog.shared.start()

            // Setup menu bar icon
            let menuBar = MenuBarManager(
                coordinator: wrapper.coordinator,
                onboardingManager: wrapper.coordinator.onboardingManager
            )
            menuBar.setup()
            self.menuBarManager = menuBar

            // Configure the timeline window controller
            TimelineWindowController.shared.configure(coordinator: wrapper.coordinator)

            // Configure the dashboard window controller
            DashboardWindowController.shared.configure(coordinator: wrapper.coordinator)

            // Configure the pause reminder window controller
            PauseReminderWindowController.shared.configure(coordinator: wrapper.coordinator)

            // Setup sleep/wake observers to properly handle segment tracking
            setupSleepWakeObservers()

            // Setup power settings change observer
            setupPowerSettingsObserver()
            ProcessCPUMonitor.shared.start()

            Log.info("[AppDelegate] Menu bar and window controllers initialized", category: .app)

            let launchRequestedAutoStart = AppCoordinator.shouldAutoStartRecording()
            let shouldAllowLaunchAutoStart = await handleMissingMasterKeyRedactionIfNeeded(
                coordinator: wrapper.coordinator,
                autoStartRequested: launchRequestedAutoStart
            )
            if launchRequestedAutoStart && shouldAllowLaunchAutoStart {
                await wrapper.autoStartRecordingIfNeeded()
            } else if launchRequestedAutoStart {
                Log.warning(
                    "[AppDelegate] Skipping launch auto-start because the missing master key flow was deferred",
                    category: .app
                )
            }

            // Mark as initialized before processing pending deeplinks
            isInitialized = true

            // Process any deeplinks that arrived before initialization completed
            var didHandleInitialDeeplink = false
            let pendingDeeplinkCount = pendingDeeplinkURLs.count
            if pendingDeeplinkCount > 0 {
                Log.info("[AppDelegate] Processing \(pendingDeeplinkCount) pending deeplink(s)", category: .app)
                for url in pendingDeeplinkURLs {
                    handleDeeplink(url)
                }
                pendingDeeplinkURLs.removeAll()
                didHandleInitialDeeplink = true
            }

            // Dev-only startup deeplink simulation from terminal:
            // RETRACE_DEV_DEEPLINK_URL='retrace://search?...' swift run Retrace
            let didHandleDevDeeplink = processDevDeeplinkFromEnvironment()
            if didHandleDevDeeplink {
                didHandleInitialDeeplink = true
            }

            if shouldShowDashboardAfterInitialization {
                requestDashboardReveal(source: "pendingExternalDashboardReveal")
                shouldShowDashboardAfterInitialization = false
            } else if !didHandleInitialDeeplink {
                // Show dashboard on first launch (only if no deeplinks)
                DashboardWindowController.shared.show()
            }

        } catch {
            Log.error("[AppDelegate] Failed to initialize: \(error)", category: .app)
        }
    }

    private func configureWatchdogAutoQuit() {
        MainThreadWatchdog.shared.setAutoQuitHandler { blockedSeconds in
            Task.detached(priority: .userInitiated) {
                let blockedFor = String(format: "%.1f", blockedSeconds)

                let displayCount = Self.activeDisplayCount()
                if displayCount <= 0 {
                    let displayStateDescription = displayCount == 0 ? "0 active displays" : "display probe failed"
                    Log.warning(
                        "[Watchdog] Auto-quit suppressed: \(displayStateDescription) (darkwake/sleep transition). blocked=\(blockedFor)s",
                        category: .ui
                    )
                    MainThreadWatchdog.shared.suspendAutoQuit(
                        for: Self.watchdogWakeGracePeriodSeconds,
                        reason: "\(displayStateDescription) (darkwake/sleep transition)"
                    )
                    EmergencyDiagnostics.capture(trigger: "watchdog_auto_quit_suppressed_no_display")
                    return
                }

                Log.critical(
                    "[Watchdog] Auto-quit threshold reached (\(blockedFor)s). Capturing diagnostics and attempting automatic relaunch.",
                    category: .ui
                )

                let hangSamplePath = await CrashRecoveryManager.captureWatchdogHangSample(
                    trigger: "watchdog_auto_quit"
                )
                if hangSamplePath != nil {
                    Log.info("[Watchdog] Helper captured watchdog hang sample for watchdog report merge", category: .ui)
                } else {
                    Log.warning("[Watchdog] Helper hang sample was unavailable before auto-quit", category: .ui)
                }

                EmergencyDiagnostics.capture(
                    trigger: "watchdog_auto_quit",
                    supplementalReportPaths: hangSamplePath.map { [$0] } ?? [],
                    cleanupSupplementalReports: true
                )

                let relaunchDecision = CrashRecoverySupport.evaluateAndRecordCrashAutoRestart()
                guard relaunchDecision.shouldRelaunch else {
                    Log.critical(
                        "[Watchdog] Auto-relaunch suppressed to prevent restart loop (\(relaunchDecision.recentCount) relaunches in last 5 minutes). Exiting without relaunch.",
                        category: .ui
                    )
                    Darwin.exit(0)
                }

                // Ensure we still terminate if relaunch scheduling fails unexpectedly.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3.0) {
                    Log.critical("[Watchdog] Relaunch did not complete after auto-quit trigger. Force exiting.", category: .ui)
                    Darwin.exit(0)
                }

                AppRelaunch.relaunchForCrashRecovery()
            }
        }
    }

    nonisolated private static func activeDisplayCount() -> Int {
        var displayCount: UInt32 = 0
        let result = CGGetActiveDisplayList(0, nil, &displayCount)
        guard result == .success else {
            return -1
        }
        return Int(displayCount)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running in menu bar even when window is closed
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "Retrace")
        let isDashboardFrontAndCenter = LaunchMenuRouting.dashboardIsFrontAndCenter()
        let isSettingsFrontAndCenter = LaunchMenuRouting.settingsIsFrontAndCenter()

        menu.addItem(
            makeDockMenuItem(
                isDashboardFrontAndCenter ? "Hide Dashboard" : "Open Dashboard",
                systemImageName: "rectangle.3.group",
                action: #selector(handleDockToggleDashboard)
            )
        )
        menu.addItem(
            makeDockMenuItem(
                "Open Timeline",
                systemImageName: "clock",
                action: #selector(handleDockOpenTimeline)
            )
        )
        menu.addItem(
            makeDockMenuItem(
                isSettingsFrontAndCenter ? "Hide Settings" : "Open Settings",
                systemImageName: "gearshape",
                action: #selector(handleDockOpenSettings)
            )
        )
        menu.addItem(
            makeDockMenuItem(
                "Get Help...",
                systemImageName: "exclamationmark.bubble",
                action: #selector(handleDockOpenFeedback)
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            makeDockMenuItem(
                dockRecordingMenuTitle(),
                systemImageName: dockRecordingMenuSymbolName(),
                action: #selector(handleDockToggleRecording)
            )
        )

        return menu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            Log.info("[LaunchSurface] applicationShouldHandleReopen hasVisibleWindows=\(flag) state=\(launchSurfaceStateSnapshot())", category: .app)
            logGhostAppCheck("applicationShouldHandleReopen hasVisibleWindows=\(flag)")
            requestDashboardReveal(source: "applicationShouldHandleReopen")
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            self.installMainMenuIfNeeded()
            CrashRecoveryManager.shared.refreshUserFacingStatus()
            let shouldReveal = shouldRevealDashboardForActivation()
            Log.info("[LaunchSurface] applicationDidBecomeActive shouldReveal=\(shouldReveal) state=\(launchSurfaceStateSnapshot())", category: .app)
            logGhostAppCheck("applicationDidBecomeActive shouldReveal=\(shouldReveal)")

            guard shouldReveal, !isActivationRevealInFlight else { return }

            isActivationRevealInFlight = true
            requestDashboardReveal(source: "applicationDidBecomeActive")
            isActivationRevealInFlight = false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminationFlushInProgress {
            return .terminateNow
        }

        if isTerminationDecisionInProgress {
            return .terminateLater
        }

        switch terminationPreferenceForCurrentRequest() {
        case .quit:
            beginTerminationFlush()
            return .terminateLater
        case .runInBackground:
            runInBackgroundInsteadOfQuitting()
            return .terminateCancel
        case .ask:
            break
        }

        isTerminationDecisionInProgress = true
        presentQuitConfirmationAlert()

        return .terminateLater
    }

    private func requestImmediateTermination(skipQuitConfirmation: Bool) {
        if skipQuitConfirmation {
            bypassQuitConfirmationPromptOnce = true
        }
        NSApp.terminate(nil)
    }

    private func exitDuplicatePrelaunchProcess() -> Never {
        // Duplicate-prelaunch exits should not wait on normal AppKit termination flushes.
        Darwin.exit(EXIT_SUCCESS)
    }

    private func terminationPreferenceForCurrentRequest() -> QuitTerminationPreference {
        if bypassQuitConfirmationPromptOnce {
            bypassQuitConfirmationPromptOnce = false
            return .quit
        }

        guard let rawValue = settingsStore.string(forKey: Self.quitConfirmationPreferenceKey),
              let storedPreference = QuitTerminationPreference(rawValue: rawValue) else {
            return .ask
        }

        return storedPreference
    }

    private func beginTerminationFlush() {
        guard !isTerminationFlushInProgress else { return }

        isTerminationFlushInProgress = true
        Self.isApplicationTerminating = true
        let pendingRestartDebuggingSession = CrashRecoverySupport.markRestartDebuggingPendingForNextLaunch()
        Log.info(
            CrashRecoverySupport.restartDebuggingTagged("[AppDelegate] Beginning termination flush launchedFromCrashRecovery=\(CrashRecoveryManager.shared.launchedFromCrashRecovery) crashRecoverySource=\(CrashRecoveryManager.shared.recoveryLaunchSource?.rawValue ?? "nil") pendingSession=\(pendingRestartDebuggingSession)"),
            category: .app
        )

        // Save timeline state (filters, search) for cross-session persistence.
        TimelineWindowController.shared.saveStateForTermination()

        // Flush active timeline metrics asynchronously with a bounded timeout.
        // Use terminateLater to avoid blocking the main thread during shutdown.
        Task { @MainActor [weak self] in
            await CrashRecoveryManager.shared.prepareForExpectedExit()
            _ = await TimelineWindowController.shared.forceRecordSessionMetrics(timeoutMs: 350)
            self?.isTerminationFlushInProgress = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    private func presentQuitConfirmationAlert() {
        Log.info("[AppDelegate] Presenting standard quit confirmation alert", category: .app)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Are you sure you want to quit Retrace?"
        alert.informativeText = "Quitting Retrace will stop any active capture and end ongoing recording. You can keep Retrace running in the background without interruption."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.addButton(withTitle: "Quit Retrace")
        alert.addButton(withTitle: "Run Retrace in Background")
        alert.addButton(withTitle: "Cancel")
        styleQuitAlertPrimaryButton(alert, context: "initial")
        scheduleQuitButtonStyleEnforcement(for: alert, context: "quit-confirmation")

        if let anchorWindow = currentTerminationAnchorWindow() {
            alert.beginSheetModal(for: anchorWindow) { [weak self] response in
                Task { @MainActor in
                    guard let self else { return }
                    self.handleQuitAlertResponse(response, dontAskAgain: alert.suppressionButton?.state == .on)
                }
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        handleQuitAlertResponse(response, dontAskAgain: alert.suppressionButton?.state == .on)
    }

    private func handleQuitAlertResponse(_ response: NSApplication.ModalResponse, dontAskAgain: Bool) {
        let result: QuitConfirmationResult
        switch response {
        case .alertFirstButtonReturn:
            result = QuitConfirmationResult(action: .quit, dontAskAgain: dontAskAgain)
        case .alertSecondButtonReturn:
            result = QuitConfirmationResult(action: .runInBackground, dontAskAgain: dontAskAgain)
        default:
            result = QuitConfirmationResult(action: .cancel, dontAskAgain: dontAskAgain)
        }
        handleQuitConfirmationResult(result)
    }

    private func currentTerminationAnchorWindow() -> NSWindow? {
        Self.preferredQuitConfirmationAnchorWindow(
            keyWindow: NSApp.keyWindow,
            mainWindow: NSApp.mainWindow
        )
    }

    static func preferredQuitConfirmationAnchorWindow(
        keyWindow: NSWindow?,
        mainWindow: NSWindow?
    ) -> NSWindow? {
        if let keyWindow, canPresentQuitConfirmationSheet(on: keyWindow) {
            return keyWindow
        }
        if let mainWindow, canPresentQuitConfirmationSheet(on: mainWindow) {
            return mainWindow
        }
        return nil
    }

    static func canPresentQuitConfirmationSheet(on window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized
    }

    private func scheduleQuitButtonStyleEnforcement(for alert: NSAlert, context: String) {
        // AppKit may restyle alert buttons after presentation; re-apply a few times.
        let delays: [TimeInterval] = [0.0, 0.04, 0.10, 0.20]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.styleQuitAlertPrimaryButton(alert, context: "\(context)-t+\(String(format: "%.2f", delay))")
            }
        }
    }

    private func styleQuitAlertPrimaryButton(_ alert: NSAlert, context: String) {
        guard let quitButton = alert.buttons.first else { return }

        let retraceQuitBlue = NSColor(
            calibratedRed: 11.0 / 255.0,
            green: 51.0 / 255.0,
            blue: 108.0 / 255.0,
            alpha: 1.0
        )

        quitButton.appearance = NSAppearance(named: .darkAqua)
        quitButton.bezelColor = retraceQuitBlue
        quitButton.contentTintColor = .white
        quitButton.attributedTitle = NSAttributedString(
            string: quitButton.title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: quitButton.font?.pointSize ?? 15, weight: .semibold)
            ]
        )
        quitButton.needsDisplay = true

        if let appliedColor = quitButton.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            Log.debug("[QUIT_ALERT] Applied style context=\(context) fg=\(appliedColor) bezel=\(retraceQuitBlue)", category: .ui)
        } else {
            Log.warning("[QUIT_ALERT] Failed to read attributed foreground color context=\(context)", category: .ui)
        }
    }

    private func handleQuitConfirmationResult(_ result: QuitConfirmationResult) {
        isTerminationDecisionInProgress = false

        if result.dontAskAgain {
            switch result.action {
            case .quit:
                settingsStore.set(QuitTerminationPreference.quit.rawValue, forKey: Self.quitConfirmationPreferenceKey)
            case .runInBackground:
                settingsStore.set(QuitTerminationPreference.runInBackground.rawValue, forKey: Self.quitConfirmationPreferenceKey)
            case .cancel:
                break
            }
        }

        switch result.action {
        case .quit:
            Log.info("[AppDelegate] User confirmed quit", category: .app)
            beginTerminationFlush()
        case .runInBackground:
            Log.info("[AppDelegate] User chose to keep Retrace running in background", category: .app)
            runInBackgroundInsteadOfQuitting()
            NSApp.reply(toApplicationShouldTerminate: false)
        case .cancel:
            Log.info("[AppDelegate] User cancelled quit", category: .app)
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    private func runInBackgroundInsteadOfQuitting() {
        TimelineWindowController.shared.hide()
        DashboardWindowController.shared.hide()
        NSApp.hide(nil)
    }

    private func handleMissingMasterKeyRedactionIfNeeded(
        coordinator: AppCoordinator,
        autoStartRequested: Bool
    ) async -> Bool {
        let state = await coordinator.missingMasterKeyRedactionState()
        guard state.requiresRecoveryPrompt else { return true }

        let outcome = await MasterKeyRedactionFlowCoordinator.resolveMissingKey(
            coordinator: coordinator,
            state: state,
            defaults: settingsStore,
            configuration: .startup,
            recordMetric: { action, metadata in
                Task {
                    await self.recordMasterKeyLaunchMetric(
                        coordinator: coordinator,
                        action: action,
                        metadata: metadata
                    )
                }
            }
        )

        switch outcome {
        case .recoveredExistingKey, .keyAlreadyAvailable:
            MasterKeyPromptUI.showRecoveredAlert(hasPendingRewrites: state.hasPendingRedactionRewrites)
            return true
        case .createdFreshKey(let recoveryPhrase, let abandonedRewriteCount):
            await presentRecoveryPhraseSavePrompt(
                coordinator: coordinator,
                recoveryPhrase: recoveryPhrase,
                abandonedRewriteCount: abandonedRewriteCount
            )
            return true
        case .deferred:
            if autoStartRequested {
                await recordMasterKeyLaunchMetric(
                    coordinator: coordinator,
                    action: "startup_missing_key_autostart_blocked"
                )
                return false
            }
            return true
        }
    }

    private func presentRecoveryPhraseSavePrompt(
        coordinator: AppCoordinator,
        recoveryPhrase: String,
        abandonedRewriteCount: Int
    ) async {
        let abandonmentMessage: String
        if abandonedRewriteCount > 0 {
            abandonmentMessage = "\n\n\(abandonedRewriteCount) pending redaction rewrite job(s) tied to the missing key were marked failed."
        } else {
            abandonmentMessage = ""
        }

        while true {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.icon = NSApp.applicationIconImage
            alert.messageText = "Save Your Recovery Phrase"
            alert.informativeText = """
                Store this offline and keep it private.

                Anyone with this phrase can recover your protected data. If you lose both this phrase and the Keychain copy on this Mac, that data is gone.\(abandonmentMessage)

                Recovery Phrase:
                \(recoveryPhrase)
                """
            alert.addButton(withTitle: "I Saved It")
            alert.addButton(withTitle: "Copy Phrase")
            alert.addButton(withTitle: "Save TXT")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                MasterKeyManager.noteRecoveryPhraseShown(defaults: settingsStore)
                await recordMasterKeyLaunchMetric(
                    coordinator: coordinator,
                    action: "startup_missing_key_recovery_acknowledged"
                )
                return
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(recoveryPhrase, forType: .string)
                await recordMasterKeyLaunchMetric(
                    coordinator: coordinator,
                    action: "startup_missing_key_recovery_copied"
                )
            default:
                switch MasterKeyPromptUI.saveRecoveryPhraseDocument(recoveryPhrase) {
                case .saved:
                    await recordMasterKeyLaunchMetric(
                        coordinator: coordinator,
                        action: "startup_missing_key_recovery_downloaded"
                    )
                case .cancelled:
                    await recordMasterKeyLaunchMetric(
                        coordinator: coordinator,
                        action: "startup_missing_key_recovery_download_cancelled"
                    )
                case .failed:
                    await recordMasterKeyLaunchMetric(
                        coordinator: coordinator,
                        action: "startup_missing_key_recovery_download_failed"
                    )
                }
            }
        }
    }

    private func recordMasterKeyLaunchMetric(
        coordinator: AppCoordinator,
        action: String,
        metadata: [String: Any] = [:]
    ) async {
        var payload = metadata
        payload["action"] = action
        payload["source"] = "startup_missing_key_redaction"

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        try? await coordinator.recordMetricEvent(
            metricType: .masterKeyFlow,
            metadata: json
        )
    }

    // MARK: - Storage Path Validation

    /// Pre-flight check to ensure custom storage path is accessible
    /// Returns true if app should continue, false if user chose to quit
    @MainActor
    private func checkStoragePathAvailable() async -> Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

        // Only check if user has set a custom path (not new users)
        guard let customPath = defaults.string(forKey: "customRetraceDBLocation") else {
            return true // Using default path, always available
        }

        let fm = FileManager.default
        let expandedPath = NSString(string: customPath).expandingTildeInPath

        // Check if the custom path itself exists
        // User explicitly set this path, so we should verify it's there
        if fm.fileExists(atPath: expandedPath) {
            return true // Custom path exists
        }

        // Custom path doesn't exist - determine the appropriate message
        let parentDir = (expandedPath as NSString).deletingLastPathComponent
        let isDriveDisconnected = !fm.fileExists(atPath: parentDir)

        Log.warning("[AppDelegate] Custom storage path not found: \(expandedPath) (drive disconnected: \(isDriveDisconnected))", category: .app)

        let alert = NSAlert()
        if isDriveDisconnected {
            alert.messageText = "Storage Drive Not Found"
            alert.informativeText = """
                Retrace is configured to store data at:
                \(customPath)

                This location is not accessible. The drive may be disconnected.

                What would you like to do?
                """
        } else {
            alert.messageText = "Database Folder Not Found"
            alert.informativeText = """
                Retrace is configured to store data at:
                \(customPath)

                This folder no longer exists. It may have been moved or deleted.

                What would you like to do?
                """
        }
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Browse for Folder")
        alert.addButton(withTitle: "Reset to Default Location")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Browse for folder - open at parent of the missing path
            if let newPath = await browseForDatabaseFolder(startingAt: parentDir) {
                defaults.set(newPath, forKey: "customRetraceDBLocation")
                defaults.synchronize()
                Log.info("[AppDelegate] User selected new storage location: \(newPath)", category: .app)
                return true
            } else {
                // User cancelled - show dialog again
                return await checkStoragePathAvailable()
            }

        case .alertSecondButtonReturn:
            // Reset to default location
            defaults.removeObject(forKey: "customRetraceDBLocation")
            defaults.synchronize()
            Log.info("[AppDelegate] Reset to default storage location", category: .app)
            return true

        default:
            // Quit
            Log.info("[AppDelegate] User chose to quit", category: .app)
            requestImmediateTermination(skipQuitConfirmation: true)
            return false
        }
    }

    /// Shows folder picker for selecting database location
    /// Returns the selected path if valid, nil if cancelled or invalid
    @MainActor
    private func browseForDatabaseFolder(startingAt directory: String?) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for the Retrace database"
        panel.prompt = "Select"

        // Open at the specified directory if it exists
        if let dir = directory, FileManager.default.fileExists(atPath: dir) {
            panel.directoryURL = URL(fileURLWithPath: dir)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        let selectedPath = url.path
        let validationResult = await validateRetraceFolderSelection(at: selectedPath)

        switch validationResult {
        case .valid:
            return selectedPath

        case .missingChunks:
            let alert = NSAlert()
            alert.messageText = "Missing Chunks Folder"
            alert.informativeText = "The selected folder has retrace.db but is missing the 'chunks' folder with video files.\n\nRetrace may not be able to load existing video frames.\n\nDo you want to continue anyway?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue Anyway")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() != .alertFirstButtonReturn {
                // User cancelled - let them pick again
                return await browseForDatabaseFolder(startingAt: directory)
            }
            return selectedPath

        case .invalidFolder:
            let alert = NSAlert()
            alert.messageText = "Invalid Folder Selection"
            alert.informativeText = "The selected folder contains other files but is not a valid Retrace database folder.\n\nPlease select either:\n• An existing Retrace folder (with retrace.db)\n• An empty folder for a new database"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()

            // Let them pick again
            return await browseForDatabaseFolder(startingAt: directory)

        case .unwritableFolder(let error):
            let alert = NSAlert()
            alert.messageText = "Folder Not Writable"
            alert.informativeText = error
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()

            // Let them pick again
            return await browseForDatabaseFolder(startingAt: directory)

        case .invalidDatabase(let error):
            let alert = NSAlert()
            alert.messageText = "Invalid Retrace Database"
            alert.informativeText = error
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()

            // Let them pick again
            return await browseForDatabaseFolder(startingAt: directory)
        }
    }

    private enum RetraceFolderValidationResult: Sendable {
        case valid
        case missingChunks
        case invalidFolder
        case unwritableFolder(error: String)
        case invalidDatabase(error: String)
    }

    private func validateRetraceFolderSelection(at selectedPath: String) async -> RetraceFolderValidationResult {
        await Task.detached(priority: .userInitiated) {
            Self.validateRetraceFolderSelectionSync(at: selectedPath)
        }.value
    }

    nonisolated private static func validateRetraceFolderSelectionSync(at selectedPath: String) -> RetraceFolderValidationResult {
        let fm = FileManager.default
        let dbPath = "\(selectedPath)/retrace.db"
        let chunksPath = "\(selectedPath)/chunks"
        let hasDatabase = fm.fileExists(atPath: dbPath)
        let hasChunks = fm.fileExists(atPath: chunksPath)

        if hasDatabase {
            let verification = verifyRetraceDatabase(at: dbPath)
            guard verification.isValid else {
                return .invalidDatabase(error: verification.error ?? "The selected folder contains a retrace.db file that is not a valid Retrace database.")
            }

            if let writeProbeFailure = probeRetraceFolderWriteAccess(at: selectedPath) {
                return .unwritableFolder(error: writeProbeFailure)
            }
            return hasChunks ? .valid : .missingChunks
        }

        let contents = (try? fm.contentsOfDirectory(atPath: selectedPath)) ?? []
        let visibleContents = contents.filter { !$0.hasPrefix(".") }
        guard visibleContents.isEmpty else {
            return .invalidFolder
        }

        if let writeProbeFailure = probeRetraceFolderWriteAccess(at: selectedPath) {
            return .unwritableFolder(error: writeProbeFailure)
        }

        return .valid
    }

    nonisolated private static func probeRetraceFolderWriteAccess(at selectedPath: String) -> String? {
        let probeURL = URL(fileURLWithPath: selectedPath, isDirectory: true)
            .appendingPathComponent(".retrace-write-probe-\(UUID().uuidString)")
        let probeData = Data("retrace-write-probe".utf8)

        do {
            try probeData.write(to: probeURL, options: .atomic)
            try FileManager.default.removeItem(at: probeURL)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: probeURL)
            return "The selected folder is not writable by Retrace.\n\nChoose a folder where Retrace can create and remove files.\n\nUnderlying error: \(error.localizedDescription)"
        }
    }

    /// Verifies that a file is a valid Retrace database (unencrypted SQLite with expected tables)
    nonisolated private static func verifyRetraceDatabase(at path: String) -> (isValid: Bool, error: String?) {
        var db: OpaquePointer?

        // Try to open the database
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            return (false, "Failed to open database: \(errorMsg)")
        }

        // Verify we can read from sqlite_master (confirms it's a valid SQLite database)
        var testStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &testStmt, nil) == SQLITE_OK,
              sqlite3_step(testStmt) == SQLITE_ROW else {
            sqlite3_finalize(testStmt)
            sqlite3_close(db)
            return (false, "File is not a valid SQLite database.")
        }
        sqlite3_finalize(testStmt)

        // Check for Retrace-specific tables (frame, segment, video)
        let requiredTables = ["frame", "segment", "video"]
        for table in requiredTables {
            var stmt: OpaquePointer?
            let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='\(table)'"
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else {
                sqlite3_finalize(stmt)
                sqlite3_close(db)
                return (false, "Database is missing required '\(table)' table. This may not be a Retrace database.")
            }
            sqlite3_finalize(stmt)
        }

        sqlite3_close(db)
        return (true, nil)
    }

    // MARK: - Sleep/Wake Handling

    private func setupSleepWakeObservers() {
        guard sleepWakeObservers.isEmpty else {
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter

        let sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSystemSleep()
            }
        }
        sleepWakeObservers.append(sleepObserver)

        let screensSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleScreensSleep()
            }
        }
        sleepWakeObservers.append(screensSleepObserver)

        let wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSystemWake()
            }
        }
        sleepWakeObservers.append(wakeObserver)

        let screensWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleScreensWake()
            }
        }
        sleepWakeObservers.append(screensWakeObserver)

        // Power source change detection - coalesced with sleep/wake observers
        // NSWorkspace doesn't have a direct power change notification, but we can:
        // 1. Check power state on wake (covers most plug/unplug during sleep)
        // 2. Use IOKit's power source notification for real-time detection
        setupPowerSourceMonitoring()
        setupLowPowerModeObserver()

        Log.info("[AppDelegate] Sleep/wake observers registered", category: .app)
    }

    /// Setup IOKit-based power source monitoring for AC/battery changes
    private func setupPowerSourceMonitoring() {
        guard powerSourceRunLoopSource == nil else {
            return
        }

        // Create a run loop source for power source notifications
        let context = Unmanaged.passUnretained(self).toOpaque()

        if let runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                await delegate.handlePowerSourceChange()
            }
        }, context)?.takeRetainedValue() {
            powerSourceRunLoopSource = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            let initialSource = PowerStateMonitor.shared.getCurrentPowerSource()
            lastKnownPowerSource = initialSource
            Log.info("[AppDelegate] Power source monitoring registered (initial: \(initialSource))", category: .app)
        }
    }

    private func setupLowPowerModeObserver() {
        guard lowPowerModeObserver == nil else {
            return
        }

        lastKnownLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        lowPowerModeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleLowPowerModeChange()
            }
        }
    }

    @MainActor
    private func handlePowerSourceChange() async {
        guard coordinatorWrapper != nil else { return }

        let newSource = PowerStateMonitor.shared.getCurrentPowerSource()
        if let lastKnownPowerSource, lastKnownPowerSource == newSource {
            return
        }
        lastKnownPowerSource = newSource

        Log.info("[AppDelegate] Power source changed to: \(newSource)", category: .app)
        schedulePowerSettingsApply()

        // Notify UI to update power status display
        NotificationCenter.default.post(name: NSNotification.Name("PowerSourceDidChange"), object: newSource)
    }

    @MainActor
    private func handleLowPowerModeChange() async {
        guard coordinatorWrapper != nil else { return }

        let isLowPowerEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let lastKnownLowPowerMode, lastKnownLowPowerMode == isLowPowerEnabled {
            return
        }
        lastKnownLowPowerMode = isLowPowerEnabled

        Log.info("[AppDelegate] Low Power Mode changed: \(isLowPowerEnabled)", category: .app)
        schedulePowerSettingsApply()
    }

    @MainActor
    private func schedulePowerSettingsApply(snapshot: OCRPowerSettingsSnapshot? = nil) {
        if let snapshot {
            pendingPowerSettingsSnapshot = snapshot
        }

        powerSettingsApplyTask?.cancel()
        powerSettingsApplyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .nanoseconds(Int64(250_000_000)), clock: .continuous)
            } catch {
                return
            }

            guard let self, let wrapper = self.coordinatorWrapper else { return }
            if let snapshot = self.pendingPowerSettingsSnapshot {
                await wrapper.coordinator.applyPowerSettings(snapshot: snapshot)
                self.pendingPowerSettingsSnapshot = nil
            } else {
                await wrapper.coordinator.applyPowerSettings()
            }
            self.powerSettingsApplyTask = nil
        }
    }

    /// Setup observer for power settings changes from Settings UI
    private func setupPowerSettingsObserver() {
        guard powerSettingsObserver == nil else {
            return
        }

        powerSettingsObserver = NotificationCenter.default.addObserver(
            forName: OCRPowerSettingsNotification.didChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard self.coordinatorWrapper != nil else { return }
                Log.info("[AppDelegate] Power settings changed, applying...", category: .app)

                if let snapshot = notification.object as? OCRPowerSettingsSnapshot {
                    self.schedulePowerSettingsApply(snapshot: snapshot)
                } else {
                    self.schedulePowerSettingsApply()
                }
            }
        }
    }

    @MainActor
    private func handleSystemSleep() async {
        MainThreadWatchdog.shared.suspendAutoQuit(
            for: Self.watchdogSleepSuspensionSeconds,
            reason: "system will sleep"
        )

        guard let wrapper = coordinatorWrapper else { return }
        guard !isHandlingSystemSleep else { return }
        isHandlingSystemSleep = true
        defer { isHandlingSystemSleep = false }

        wasRecordingBeforeSleep = await wrapper.coordinator.isCapturing()

        if wasRecordingBeforeSleep {
            Log.info("[AppDelegate] System going to sleep - stopping pipeline to finalize current segment", category: .app)
            do {
                try await wrapper.coordinator.stopPipeline(persistState: false)
            } catch {
                Log.error("[AppDelegate] Failed to stop pipeline on sleep: \(error)", category: .app)
            }
        }
    }

    @MainActor
    private func handleSystemWake() async {
        MainThreadWatchdog.shared.resumeAutoQuit(
            after: Self.watchdogWakeGracePeriodSeconds,
            reason: "system did wake"
        )

        guard let wrapper = coordinatorWrapper else { return }
        guard !isHandlingSystemWake else { return }
        guard wasRecordingBeforeSleep else { return }
        isHandlingSystemWake = true
        wasRecordingBeforeSleep = false
        defer { isHandlingSystemWake = false }
        schedulePowerSettingsApply()

        if await wrapper.coordinator.isCapturing() {
            await wrapper.refreshStatus()
            return
        }

        Log.info("[AppDelegate] System woke from sleep - resuming pipeline", category: .app)
        do {
            try await wrapper.coordinator.startPipeline()
            await wrapper.refreshStatus()
        } catch {
            Log.error("[AppDelegate] Failed to resume pipeline on wake: \(error)", category: .app)
        }
    }

    @MainActor
    private func handleScreensSleep() async {
        MainThreadWatchdog.shared.suspendAutoQuit(
            for: Self.watchdogSleepSuspensionSeconds,
            reason: "screens did sleep"
        )
    }

    @MainActor
    private func handleScreensWake() async {
        MainThreadWatchdog.shared.resumeAutoQuit(
            after: Self.watchdogWakeGracePeriodSeconds,
            reason: "screens did wake"
        )
    }

    // MARK: - Recording Control

    func toggleRecording() async throws {
        guard let wrapper = coordinatorWrapper else { return }
        let isCapturing = await wrapper.coordinator.isCapturing()
        if isCapturing {
            try await wrapper.stopPipeline()
        } else {
            try await wrapper.startPipeline()
        }
    }

    @objc private func handleDockToggleDashboard() {
        if LaunchMenuRouting.dashboardIsFrontAndCenter() {
            DashboardWindowController.shared.hide()
            return
        }

        LaunchMenuRouting.showDashboard()
    }

    @objc private func handleDockOpenTimeline() {
        LaunchMenuRouting.showTimeline()
    }

    @objc private func handleDockOpenSettings() {
        if LaunchMenuRouting.settingsIsFrontAndCenter() {
            DashboardWindowController.shared.hide()
            return
        }

        LaunchMenuRouting.showSettings()
    }

    @objc private func handleDockToggleRecording() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.toggleRecording()
            } catch {
                Log.error("[DockMenu] Failed to toggle recording: \(error)", category: .ui)
            }
        }
    }

    @objc private func handleDockOpenFeedback() {
        openHelpFromMenu(source: "dock_menu")
    }

    @objc private func handleMainMenuOpenAbout() {
        presentAboutWindow()
    }

    @objc private func handleMainMenuOpenChangelog() {
        LaunchMenuRouting.showChangelog()
    }

    @objc private func handleMainMenuOpenSettings() {
        LaunchMenuRouting.showSettings()
    }

    @objc private func handleMainMenuCheckForUpdates() {
        UpdaterManager.shared.checkForUpdates()
        installMainMenuIfNeeded(force: true)
    }

    @objc private func handleMainMenuToggleTimeline() {
        if TimelineWindowController.shared.isVisible {
            LaunchMenuRouting.hideTimeline()
        } else {
            LaunchMenuRouting.showTimeline()
        }
    }

    @objc private func handleMainMenuOpenSearch() {
        LaunchMenuRouting.showSearch(source: "main_menu")
    }

    @objc private func handleMainMenuToggleDashboard() {
        if LaunchMenuRouting.dashboardIsFrontAndCenter() {
            DashboardWindowController.shared.hide()
        } else {
            LaunchMenuRouting.showDashboard()
        }
    }

    @objc private func handleMainMenuToggleSystemMonitor() {
        if LaunchMenuRouting.systemMonitorIsFrontAndCenter() {
            LaunchMenuRouting.toggleSystemMonitor()
        } else {
            LaunchMenuRouting.showSystemMonitor()
        }
    }

    @objc private func handleMainMenuPauseRecordingFor5Minutes() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pauseRecordingFromMainMenu(duration: 5 * 60)
        }
    }

    @objc private func handleMainMenuPauseRecordingFor30Minutes() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pauseRecordingFromMainMenu(duration: 30 * 60)
        }
    }

    @objc private func handleMainMenuPauseRecordingFor60Minutes() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pauseRecordingFromMainMenu(duration: 60 * 60)
        }
    }

    @objc private func handleMainMenuResumeRecordingNow() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startRecordingFromMainMenu()
        }
    }

    @objc private func handleMainMenuStopRecording() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pauseRecordingFromMainMenu(duration: nil)
        }
    }

    @objc private func handleMainMenuOpenFeedback() {
        openHelpFromMenu(source: "main_menu")
    }

    @objc private func handleMainMenuQuit() {
        NSApplication.shared.terminate(nil)
    }

    private func openHelpFromMenu(source: String) {
        if let coordinator = coordinatorWrapper?.coordinator {
            Task { @MainActor in
                DashboardViewModel.recordHelpOpened(coordinator: coordinator, source: source)
            }
        }
        NotificationCenter.default.post(name: .openFeedback, object: nil)
    }

    private func startRecordingFromMainMenu() async {
        if let menuBarManager {
            await menuBarManager.startRecordingNow(source: "main_menu")
            installMainMenuIfNeeded(force: true)
            return
        }

        guard let wrapper = coordinatorWrapper else { return }

        do {
            try await wrapper.coordinator.startPipeline()
            DashboardViewModel.recordRecordingStartedFromMenu(
                coordinator: wrapper.coordinator,
                source: "main_menu"
            )
        } catch {
            Log.error("[MainMenu] Failed to start recording: \(error)", category: .ui)
        }

        installMainMenuIfNeeded(force: true)
    }

    private func pauseRecordingFromMainMenu(duration: TimeInterval?) async {
        if let menuBarManager {
            await menuBarManager.pauseRecording(for: duration, source: "main_menu")
            installMainMenuIfNeeded(force: true)
            return
        }

        guard let wrapper = coordinatorWrapper else { return }
        let wasRecording = await wrapper.coordinator.isCapturing()
        let isTimedPause = (duration ?? 0) > 0

        guard wasRecording else {
            installMainMenuIfNeeded(force: true)
            return
        }

        do {
            try await wrapper.coordinator.stopPipeline(persistState: !isTimedPause)
            if isTimedPause, let duration {
                DashboardViewModel.recordRecordingPauseSelected(
                    coordinator: wrapper.coordinator,
                    source: "main_menu",
                    durationSeconds: Int(duration)
                )
            } else {
                DashboardViewModel.recordRecordingTurnedOff(
                    coordinator: wrapper.coordinator,
                    source: "main_menu"
                )
            }
        } catch {
            Log.error("[MainMenu] Failed to stop recording: \(error)", category: .ui)
        }

        installMainMenuIfNeeded(force: true)
    }

    private func makeDockMenuItem(
        _ title: String,
        systemImageName: String? = nil,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let systemImageName,
           let symbol = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil) {
            symbol.isTemplate = true
            item.image = symbol
        }
        return item
    }

    private func dockRecordingMenuTitle() -> String {
        if menuBarManager?.isRecording == true {
            return "Stop Recording"
        }
        return "Start Recording"
    }

    private var recordingIsRunning: Bool {
        if let menuBarManager {
            return menuBarManager.isRecording
        }
        return coordinatorWrapper?.coordinator.statusHolder.status.isRunning ?? false
    }

    private var timedPauseIsActive: Bool {
        guard let menuBarManager else { return false }
        return menuBarManager.isPausedState
    }

    private func timedPauseSubtitle() -> String? {
        guard let remainingSeconds = menuBarManager?.timedPauseRemainingSeconds else { return nil }
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60

        if hours > 0 {
            return String(format: "Resumes in %d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "Resumes in %02d:%02d", minutes, seconds)
    }

    private func dockRecordingMenuSymbolName() -> String {
        if menuBarManager?.isRecording == true {
            return "stop.circle"
        }
        return "record.circle"
    }

    private func presentAboutWindow() {
        let appName = Self.applicationMenuTitle()
        let controller: NSWindowController

        if let aboutWindowController {
            controller = aboutWindowController
        } else {
            let window = RetraceAboutPanel.makeWindow(appName: appName)
            let newController = NSWindowController(window: window)
            aboutWindowController = newController
            controller = newController
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Single Instance Check

    private func singleInstanceBundleIdentifier() -> String {
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            return bundleID
        }

        if let infoBundleID = Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String,
           !infoBundleID.isEmpty {
            return infoBundleID
        }

        Log.warning(
            "[AppDelegate] Missing runtime bundle identifier; using canonical identifier \(Self.canonicalBundleIdentifier) for single-instance coordination",
            category: .app
        )
        return Self.canonicalBundleIdentifier
    }

    private func acquireSingleInstanceLock(
        maxAttempts: Int,
        reason: String
    ) async -> SingleInstanceLockRetryResult {
        let result = await SingleInstanceLockRetrier.acquire(
            maxAttempts: maxAttempts,
            retryDelay: Self.singleInstanceLockRetryDelay,
            existingDescriptor: singleInstanceLockFileDescriptor
        ) { descriptor in
            SingleInstanceLock.acquire(
                atPath: Self.singleInstanceLockPath,
                existingDescriptor: descriptor
            )
        }

        return finalizeSingleInstanceLockAcquisition(result, reason: reason)
    }

    private func acquireSingleInstanceLockForFreshLaunch() -> SingleInstanceLockRetryResult {
        let result: SingleInstanceLockRetryResult
        switch SingleInstanceLock.acquire(
            atPath: Self.singleInstanceLockPath,
            existingDescriptor: singleInstanceLockFileDescriptor
        ) {
        case .alreadyHeld(let descriptor), .acquired(let descriptor):
            result = .acquired(descriptor: descriptor, attempts: 1)
        case .heldByAnotherProcess:
            result = .failedHeldByAnotherProcess(attempts: 1)
        case .error(let code):
            result = .failedError(code: code, attempts: 1)
        }

        return finalizeSingleInstanceLockAcquisition(result, reason: "launch")
    }

    private func finalizeSingleInstanceLockAcquisition(
        _ result: SingleInstanceLockRetryResult,
        reason: String
    ) -> SingleInstanceLockRetryResult {
        switch result {
        case .acquired(let descriptor, let attempts):
            singleInstanceLockFileDescriptor = descriptor

            if attempts > 1 {
                Log.info(
                    "[AppDelegate] Acquired single-instance lock for \(reason) after \(attempts) attempts",
                    category: .app
                )
            }

            return .acquired(descriptor: descriptor, attempts: attempts)

        case .failedHeldByAnotherProcess(let attempts):
            let holder = lockFileInstancePID().map { String($0) } ?? "unknown"
            Log.warning(
                "[AppDelegate] Could not acquire single-instance lock for \(reason) after \(attempts) attempts because another process still holds it; holder pid=\(holder)",
                category: .app
            )
            return .failedHeldByAnotherProcess(attempts: attempts)

        case .failedError(let lockError, let attempts):
            Log.error(
                "[AppDelegate] Failed to acquire single-instance lock for \(reason) at \(Self.singleInstanceLockPath) after \(attempts) attempts: \(String(cString: strerror(lockError)))",
                category: .app
            )
            return .failedError(code: lockError, attempts: attempts)
        }
    }

    private func releaseSingleInstanceLock() {
        SingleInstanceLock.release(descriptor: &singleInstanceLockFileDescriptor)
    }

    static func launchGateAction(
        mode: LaunchMode,
        lockResult: SingleInstanceLockRetryResult,
        matchingRunningAppDetected: Bool
    ) -> LaunchGateAction {
        switch lockResult {
        case .acquired:
            if mode == .fresh, matchingRunningAppDetected {
                return .activateExistingInstanceAndExitDuplicate
            }
            return .continueLaunch

        case .failedHeldByAnotherProcess:
            return .activateExistingInstanceAndExitDuplicate

        case .failedError:
            if mode == .relaunch {
                return .continueLaunch
            }
            return matchingRunningAppDetected ? .activateExistingInstanceAndExitDuplicate : .exitDueToLockFailure
        }
    }

    private func handleSingleInstanceLaunchDecision(
        mode: LaunchMode,
        lockResult: SingleInstanceLockRetryResult
    ) -> Bool {
        let matchingRunningAppDetected: Bool
        switch lockResult {
        case .acquired, .failedError:
            matchingRunningAppDetected = mode == .fresh ? isAnotherInstanceRunning() : false
        case .failedHeldByAnotherProcess:
            matchingRunningAppDetected = false
        }

        let action = Self.launchGateAction(
            mode: mode,
            lockResult: lockResult,
            matchingRunningAppDetected: matchingRunningAppDetected
        )

        switch action {
        case .continueLaunch:
            if mode == .relaunch, case .failedError = lockResult {
                Log.warning(
                    "[AppDelegate] Continuing relaunch after single-instance lock error because relaunch handoff is authoritative.",
                    category: .app
                )
            } else if mode == .fresh, case .failedError = lockResult {
                Log.warning(
                    "[AppDelegate] Continuing launch after single-instance lock error because no matching running instance was detected.",
                    category: .app
                )
            }
            return true

        case .activateExistingInstanceAndExitDuplicate:
            switch (mode, lockResult) {
            case (.fresh, .acquired):
                Log.warning(
                    "[AppDelegate] Matching running application detected during fresh launch even though the single-instance lock was acquired; activating existing instance and exiting duplicate prelaunch.",
                    category: .app
                )

            case (.relaunch, .failedHeldByAnotherProcess):
                Log.warning(
                    "[AppDelegate] Relaunch could not reacquire the single-instance lock after handoff window; activating existing instance and exiting duplicate prelaunch.",
                    category: .app
                )

            case (.fresh, .failedHeldByAnotherProcess):
                Log.info(
                    "[AppDelegate] Could not acquire the single-instance lock for launch; activating existing instance if available and exiting duplicate prelaunch.",
                    category: .app
                )

            case (.fresh, .failedError):
                Log.warning(
                    "[AppDelegate] Single-instance lock failed during launch and a matching running instance was detected; activating existing instance and exiting duplicate prelaunch.",
                    category: .app
                )

            default:
                break
            }

            activateExistingInstance()
            exitDuplicatePrelaunchProcess()

        case .exitDueToLockFailure:
            Log.error(
                "[AppDelegate] Single-instance lock failed during fresh launch and no matching running instance was detected; exiting duplicate prelaunch to keep launch enforcement fail-closed.",
                category: .app
            )
            exitDuplicatePrelaunchProcess()
        }
    }

    private func lockFileInstancePID() -> pid_t? {
        guard let data = FileManager.default.contents(atPath: Self.singleInstanceLockPath),
              let lockContents = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let lockPID = Int32(lockContents) else {
            return nil
        }
        return pid_t(lockPID)
    }

    private func postExternalDashboardRevealNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.externalDashboardRevealNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        Log.info("[LaunchSurface] Posted external dashboard reveal notification", category: .app)
    }

    private func isAnotherInstanceRunning() -> Bool {
        let retraceBundleID = singleInstanceBundleIdentifier()
        let runningApps = NSWorkspace.shared.runningApplications
        let myPID = ProcessInfo.processInfo.processIdentifier

        return runningApps.contains { app in
            app.processIdentifier != myPID && app.bundleIdentifier == retraceBundleID
        }
    }

    private func activateExistingInstance() {
        let retraceBundleID = singleInstanceBundleIdentifier()
        let myPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications

        if let existingApp = runningApps.first(where: { app in
            app.bundleIdentifier == retraceBundleID &&
                app.processIdentifier != myPID
        }) {
            Log.info("[LaunchSurface] Forwarding duplicate launch to existing instance pid=\(existingApp.processIdentifier) hidden=\(existingApp.isHidden) active=\(existingApp.isActive)", category: .app)
            existingApp.activate(options: .activateIgnoringOtherApps)
            postExternalDashboardRevealNotification()
            return
        }

        if let lockPID = lockFileInstancePID(),
           lockPID != myPID,
           let lockedApp = NSRunningApplication(processIdentifier: lockPID) {
            Log.info("[LaunchSurface] Forwarding duplicate launch to locked instance pid=\(lockPID) hidden=\(lockedApp.isHidden) active=\(lockedApp.isActive)", category: .app)
            lockedApp.activate(options: .activateIgnoringOtherApps)
            postExternalDashboardRevealNotification()
        } else {
            Log.warning("[LaunchSurface] Duplicate launch detected but no existing instance was found", category: .app)
        }
    }

    @MainActor
    private func requestDashboardReveal(source: String) {
        logGhostAppCheck("requestDashboardReveal start source=\(source)")
        if isInitialized {
            Log.info("[LaunchSurface] requestDashboardReveal source=\(source) before state=\(launchSurfaceStateSnapshot())", category: .app)

            let wasHidden = NSApp.isHidden
            if wasHidden {
                Log.info("[LaunchSurface] Unhiding app before reveal source=\(source)", category: .app)
                NSApp.unhide(nil)
            }

            let dashboard = DashboardWindowController.shared
            let dashboardWasVisible = dashboard.isVisible
            if dashboard.isVisible {
                dashboard.bringToFront()
                Log.info("[LaunchSurface] Brought dashboard to front source=\(source) appWasHidden=\(wasHidden) after state=\(launchSurfaceStateSnapshot())", category: .app)
                logGhostAppCheck("requestDashboardReveal bringToFront source=\(source)")
                recordLaunchSurfaceRevealMetric(
                    source: source,
                    action: "bring_to_front",
                    appWasHidden: wasHidden,
                    dashboardWasVisible: dashboardWasVisible
                )
            } else {
                dashboard.show()
                Log.info("[LaunchSurface] Called dashboard.show source=\(source) appWasHidden=\(wasHidden) after state=\(launchSurfaceStateSnapshot())", category: .app)
                logGhostAppCheck("requestDashboardReveal show source=\(source)")
                recordLaunchSurfaceRevealMetric(
                    source: source,
                    action: "show_dashboard",
                    appWasHidden: wasHidden,
                    dashboardWasVisible: dashboardWasVisible
                )
            }
        } else {
            shouldShowDashboardAfterInitialization = true
            Log.info("[LaunchSurface] Queued dashboard reveal until initialization source=\(source) state=\(launchSurfaceStateSnapshot())", category: .app)
            logGhostAppCheck("requestDashboardReveal queued source=\(source)")
            recordLaunchSurfaceRevealMetric(
                source: source,
                action: "queued_until_initialized",
                appWasHidden: NSApp.isHidden,
                dashboardWasVisible: DashboardWindowController.shared.isVisible
            )
        }
    }

    @MainActor
    private func recordLaunchSurfaceRevealMetric(
        source: String,
        action: String,
        appWasHidden: Bool,
        dashboardWasVisible: Bool
    ) {
        guard let coordinator = coordinatorWrapper?.coordinator else { return }

        let metadata = Self.launchSurfaceRevealMetadata(
            source: source,
            action: action,
            appWasHidden: appWasHidden,
            dashboardWasVisible: dashboardWasVisible,
            isInitialized: isInitialized
        )

        Task {
            try? await coordinator.recordMetricEvent(
                metricType: .launchSurfaceReveal,
                metadata: metadata
            )
        }
    }

    private static func launchSurfaceRevealMetadata(
        source: String,
        action: String,
        appWasHidden: Bool,
        dashboardWasVisible: Bool,
        isInitialized: Bool
    ) -> String? {
        let payload: [String: Any] = [
            "source": source,
            "action": action,
            "appWasHidden": appWasHidden,
            "dashboardWasVisible": dashboardWasVisible,
            "isInitialized": isInitialized
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        return json
    }

    private func setupExternalDashboardRevealObserver() {
        Log.info("[LaunchSurface] Registering external dashboard reveal observer", category: .app)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalDashboardRevealNotification(_:)),
            name: Self.externalDashboardRevealNotification,
            object: nil
        )
    }

    private func setupGhostAppLoggingObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGhostAppDashboardDidClose(_:)),
            name: .dashboardDidClose,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGhostAppTimelineDidClose(_:)),
            name: .timelineDidClose,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGhostAppApplicationDidHide(_:)),
            name: NSApplication.didHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGhostAppApplicationDidUnhide(_:)),
            name: NSApplication.didUnhideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGhostAppWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGhostAppWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func handleExternalDashboardRevealNotification(_ notification: Notification) {
        Task { @MainActor in
            Log.info("[LaunchSurface] Received external dashboard reveal notification state=\(launchSurfaceStateSnapshot())", category: .app)
            logGhostAppCheck("external dashboard reveal notification")
            requestDashboardReveal(source: "externalDashboardRevealNotification")
        }
    }

    @objc private func handleGhostAppDashboardDidClose(_ notification: Notification) {
        Task { @MainActor in
            logGhostAppCheck("notification dashboardDidClose")
        }
    }

    @objc private func handleGhostAppTimelineDidClose(_ notification: Notification) {
        Task { @MainActor in
            logGhostAppCheck("notification timelineDidClose")
        }
    }

    @objc private func handleGhostAppApplicationDidHide(_ notification: Notification) {
        Task { @MainActor in
            logGhostAppCheck("notification applicationDidHide")
        }
    }

    @objc private func handleGhostAppApplicationDidUnhide(_ notification: Notification) {
        Task { @MainActor in
            logGhostAppCheck("notification applicationDidUnhide")
        }
    }

    @objc private func handleGhostAppWindowDidBecomeKey(_ notification: Notification) {
        Task { @MainActor in
            logGhostAppCheck(
                "notification windowDidBecomeKey window=\(ghostAppWindowDescription(notification.object as? NSWindow))"
            )
        }
    }

    @objc private func handleGhostAppWindowWillClose(_ notification: Notification) {
        Task { @MainActor in
            logGhostAppCheck(
                "notification windowWillClose window=\(ghostAppWindowDescription(notification.object as? NSWindow))"
            )
        }
    }

    @MainActor
    private func launchSurfaceStateSnapshot() -> String {
        let dashboard = DashboardWindowController.shared
        let window = dashboard.window
        let windowVisible = window?.isVisible ?? false
        let windowKey = window?.isKeyWindow ?? false
        let windowMini = window?.isMiniaturized ?? false
        let windowMain = window?.isMainWindow ?? false

        return "initialized=\(isInitialized) appHidden=\(NSApp.isHidden) appActive=\(NSApp.isActive) dashboardVisible=\(dashboard.isVisible) windowVisible=\(windowVisible) windowKey=\(windowKey) windowMain=\(windowMain) windowMini=\(windowMini)"
    }

    @MainActor
    private func ghostAppStateSnapshot() -> String {
        let menuBarSummary = menuBarManager?.ghostAppDebugSummary ?? MenuBarManager.shared?.ghostAppDebugSummary ?? "menuBarManager=nil"
        let visibleWindows = NSApp.windows.filter(\.isVisible).map { ghostAppWindowDescription($0) }
        return "initialized=\(isInitialized) appHidden=\(NSApp.isHidden) appActive=\(NSApp.isActive) terminationDecision=\(isTerminationDecisionInProgress) terminationFlush=\(isTerminationFlushInProgress) dashboardVisible=\(DashboardWindowController.shared.isVisible) timelineVisible=\(TimelineWindowController.shared.isVisible) pauseReminderVisible=\(PauseReminderWindowController.shared.isVisible) quickCommentVisible=\(StandaloneCommentComposerWindowController.shared.isVisible) quickCommentPending=\(StandaloneCommentComposerWindowController.shared.isPresentationPending) systemMonitorVisible=\(SystemMonitorWindowController.shared.isVisible) keyWindow=\(ghostAppWindowDescription(NSApp.keyWindow)) mainWindow=\(ghostAppWindowDescription(NSApp.mainWindow)) visibleWindows=\(visibleWindows) \(menuBarSummary)"
    }

    @MainActor
    private func ghostAppWindowDescription(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let title = window.title.isEmpty ? "<untitled>" : window.title
        return "\(type(of: window))(title=\(title),visible=\(window.isVisible),mini=\(window.isMiniaturized),key=\(window.isKeyWindow),main=\(window.isMainWindow),level=\(window.level.rawValue),alpha=\(String(format: "%.2f", window.alphaValue)))"
    }

    @MainActor
    private func logGhostAppCheck(_ event: String) {
        Log.info("[GhostAppCheck] \(event) state=\(ghostAppStateSnapshot())", category: .app)
    }

    @MainActor
    private func shouldRevealDashboardForActivation() -> Bool {
        guard isInitialized else { return false }
        guard !isTerminationDecisionInProgress else { return false }
        guard !isTerminationFlushInProgress else { return false }
        guard !TimelineWindowController.shared.isVisible else { return false }
        guard !StandaloneCommentComposerWindowController.shared.isVisible else { return false }
        guard !StandaloneCommentComposerWindowController.shared.isPresentationPending else { return false }
        guard !DashboardWindowController.shared.isVisible else { return false }
        guard !PauseReminderWindowController.shared.isVisible else { return false }

        let hasVisibleForegroundWindow = NSApp.windows.contains { window in
            window.level.rawValue == 0 && window.isVisible
        }
        return !hasVisibleForegroundWindow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.isApplicationTerminating = true
        // Keep the single-instance lock until the process actually exits.
        // Releasing it here lets a fresh launch race against a half-dead instance
        // that still appears in NSWorkspace.runningApplications.

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers {
            workspaceCenter.removeObserver(observer)
        }
        sleepWakeObservers.removeAll()
        powerSettingsApplyTask?.cancel()
        powerSettingsApplyTask = nil
        pendingPowerSettingsSnapshot = nil
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
            self.powerSourceRunLoopSource = nil
        }
        if let powerSettingsObserver {
            NotificationCenter.default.removeObserver(powerSettingsObserver)
            self.powerSettingsObserver = nil
        }
        if let lowPowerModeObserver {
            NotificationCenter.default.removeObserver(lowPowerModeObserver)
            self.lowPowerModeObserver = nil
        }
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        ProcessCPUMonitor.shared.stop()
        HotkeyManager.shared.shutdown()

        Log.info("[AppDelegate] Application terminating", category: .app)
    }
    // MARK: - URL Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        Log.info("[AppDelegate] Received URLs: \(urls), isInitialized: \(isInitialized)", category: .app)
        for url in urls {
            if isInitialized {
                Task { @MainActor in
                    self.handleDeeplink(url)
                }
            } else {
                // Queue the URL to be processed after initialization
                Log.info("[AppDelegate] Queuing deeplink for later: \(url)", category: .app)
                pendingDeeplinkURLs.append(url)
            }
        }
    }

    @MainActor
    private func handleDeeplink(_ url: URL) {
        guard let route = DeeplinkHandler.route(for: url) else {
            return
        }

        switch route {
        case let .timeline(timestamp):
            Log.info("[AppDelegate] Opening timeline deeplink at timestamp: \(String(describing: timestamp))", category: .app)
            if let timestamp {
                TimelineWindowController.shared.showAndNavigate(to: timestamp)
            } else {
                TimelineWindowController.shared.show()
            }

        case let .search(query, timestamp, appBundleID):
            Log.info("[AppDelegate] Opening search deeplink: query=\(query ?? "nil"), timestamp=\(String(describing: timestamp)), app=\(appBundleID ?? "nil")", category: .app)
            TimelineWindowController.shared.showSearch(
                query: query,
                timestamp: timestamp,
                appBundleID: appBundleID,
                source: "AppDelegate.openURLs"
            )
        }
    }

    /// Process a dev deeplink URL from environment for local interactive testing.
    /// Example:
    /// RETRACE_DEV_DEEPLINK_URL='retrace://search?q=test&app=com.google.Chrome&t=1704067200000' swift run Retrace
    @MainActor
    private func processDevDeeplinkFromEnvironment() -> Bool {
        guard let rawValue = ProcessInfo.processInfo.environment[Self.devDeeplinkEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return false
        }

        guard let url = URL(string: rawValue) else {
            Log.warning("[AppDelegate] Ignoring invalid \(Self.devDeeplinkEnvKey): \(rawValue)", category: .app)
            return false
        }

        Log.info("[AppDelegate] Processing dev deeplink from env: \(url)", category: .app)
        handleDeeplink(url)
        return true
    }

    // MARK: - Permissions

    private func requestPermissions() {
        // Request screen recording permission
        // This will show a system dialog on first run
        CGRequestScreenCaptureAccess()

        // Request accessibility permission
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Appearance

    private func configureAppearance() {
        // Force dark mode - the app UI is designed for dark theme
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

private enum QuitConfirmationAction {
    case quit
    case runInBackground
    case cancel
}

private struct QuitConfirmationResult {
    let action: QuitConfirmationAction
    let dontAskAgain: Bool
}

// MARK: - URL Handling

extension RetraceApp {
    /// Handle URL scheme: retrace://
    func onOpenURL(_ url: URL) {
        Log.info("[RetraceApp] Handling URL: \(url)", category: .app)
        // URL handling is done in ContentView via .onOpenURL
    }
}
