import Foundation
import AppKit
import CoreGraphics
import Shared

protocol MouseClickTapSessionControlling: AnyObject, Sendable {
    func start() async -> Bool
    func stop() async
}

actor MouseClickMonitor {
    struct Dependencies {
        let hasListenEventAccess: @Sendable () -> Bool
        let makeSession: @Sendable (@escaping @Sendable () -> Void) -> any MouseClickTapSessionControlling
    }

    private var activeSession: (any MouseClickTapSessionControlling)?
    private var pendingSession: (any MouseClickTapSessionControlling)?
    private var sharedStartTask: Task<Bool, Never>?
    private var isMonitoring = false
    private let dependencies: Dependencies

    nonisolated(unsafe) var onLeftMouseUp: (@Sendable () async -> Void)?

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func setOnLeftMouseUp(_ callback: (@Sendable () async -> Void)?) {
        onLeftMouseUp = callback
    }

    func startMonitoring() async -> Bool {
        if activeSession != nil {
            isMonitoring = true
            return true
        }

        if let sharedStartTask {
            return await sharedStartTask.value
        }

        guard dependencies.hasListenEventAccess() else {
            Log.warning(
                "[MouseClickMonitor] Listen-event access unavailable; mouse click capture disabled",
                category: .capture
            )
            return false
        }

        isMonitoring = true
        let session = dependencies.makeSession { [weak self] in
            Task {
                await self?.notifyLeftMouseUp()
            }
        }
        pendingSession = session

        let startTask = Task { [weak self] () -> Bool in
            let started = await session.start()
            await self?.finishStart(for: session, started: started)
            return started
        }
        sharedStartTask = startTask
        return await startTask.value
    }

    func stopMonitoring() async {
        guard isMonitoring || sharedStartTask != nil || activeSession != nil || pendingSession != nil else {
            return
        }

        isMonitoring = false
        sharedStartTask = nil

        let session = activeSession ?? pendingSession
        activeSession = nil
        pendingSession = nil

        await session?.stop()
    }

    private func finishStart(
        for session: any MouseClickTapSessionControlling,
        started: Bool
    ) async {
        let sessionID = ObjectIdentifier(session)
        let isStillPending = pendingSession.map { ObjectIdentifier($0) == sessionID } ?? false

        if isStillPending {
            pendingSession = nil
        }
        sharedStartTask = nil

        guard started, isMonitoring, isStillPending else {
            if started {
                await session.stop()
            }
            return
        }

        activeSession = session
    }

    private func notifyLeftMouseUp() async {
        guard isMonitoring else { return }
        guard let onLeftMouseUp else { return }
        await onLeftMouseUp()
    }
}

extension MouseClickMonitor.Dependencies {
    static let live = Self(
        hasListenEventAccess: { CGPreflightListenEventAccess() },
        makeSession: { onLeftMouseUp in
            MouseClickTapSession(onLeftMouseUp: onLeftMouseUp)
        }
    )
}

private final class MouseClickTapSession: MouseClickTapSessionControlling, @unchecked Sendable {
    private let onLeftMouseUp: @Sendable () -> Void
    private let stateLock = NSLock()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var startContinuation: CheckedContinuation<Bool, Never>?
    private var isStopped = false
    private var hasStarted = false

    init(onLeftMouseUp: @escaping @Sendable () -> Void) {
        self.onLeftMouseUp = onLeftMouseUp
    }

    func start() async -> Bool {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if hasStarted, let eventTap, CFMachPortIsValid(eventTap) {
                stateLock.unlock()
                continuation.resume(returning: true)
                return
            }

            startContinuation = continuation
            isStopped = false

            let thread = Thread { [weak self] in
                self?.runEventTapThread()
            }
            thread.name = "RetraceMouseClickEventTap"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            stateLock.unlock()

            thread.start()
        }
    }

    func stop() async {
        let continuation: CheckedContinuation<Bool, Never>?
        let runLoop: CFRunLoop?
        let source: CFRunLoopSource?
        let eventTap: CFMachPort?

        stateLock.lock()
        isStopped = true
        continuation = startContinuation
        startContinuation = nil
        runLoop = self.runLoop
        source = runLoopSource
        eventTap = self.eventTap
        self.runLoop = nil
        runLoopSource = nil
        self.eventTap = nil
        thread = nil
        hasStarted = false
        stateLock.unlock()

        continuation?.resume(returning: false)

        guard let runLoop else {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
                CFMachPortInvalidate(eventTap)
            }
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            if let source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
                CFMachPortInvalidate(eventTap)
            }
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func runEventTapThread() {
        let eventMask = CGEventMask(1) << CGEventType.leftMouseUp.rawValue
        let sessionPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let session = Unmanaged<MouseClickTapSession>.fromOpaque(refcon).takeUnretainedValue()
                return session.handleEventTap(type: type, event: event)
            },
            userInfo: sessionPointer
        ) else {
            resumeStartIfNeeded(started: false)
            Log.warning("[MouseClickMonitor] Failed to create mouse click event tap", category: .capture)
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            resumeStartIfNeeded(started: false)
            Log.warning("[MouseClickMonitor] Failed to create mouse click run loop source", category: .capture)
            return
        }

        guard let runLoop = CFRunLoopGetCurrent() else {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            resumeStartIfNeeded(started: false)
            Log.warning("[MouseClickMonitor] Failed to access current run loop for mouse click event tap", category: .capture)
            return
        }
        guard completeStart(
            eventTap: eventTap,
            runLoopSource: runLoopSource,
            runLoop: runLoop
        ) else {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            return
        }

        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        Log.info("[MouseClickMonitor] Mouse click event tap started", category: .capture)

        CFRunLoopRun()
        resetSessionStateAfterThreadExit(runLoop: runLoop)
    }

    private func completeStart(
        eventTap: CFMachPort,
        runLoopSource: CFRunLoopSource,
        runLoop: CFRunLoop
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isStopped {
            let continuation = startContinuation
            startContinuation = nil
            continuation?.resume(returning: false)
            return false
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        self.runLoop = runLoop
        hasStarted = true

        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(returning: true)
        return true
    }

    private func resumeStartIfNeeded(started: Bool) {
        stateLock.lock()
        let continuation = startContinuation
        startContinuation = nil
        hasStarted = started
        if !started {
            thread = nil
        }
        stateLock.unlock()

        continuation?.resume(returning: started)
    }

    private func resetSessionStateAfterThreadExit(runLoop: CFRunLoop) {
        stateLock.lock()
        if self.runLoop === runLoop {
            self.runLoop = nil
            runLoopSource = nil
            eventTap = nil
            thread = nil
            hasStarted = false
        }
        stateLock.unlock()
    }

    private nonisolated func handleEventTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableEventTapIfPossible()
            return Unmanaged.passUnretained(event)
        }

        guard type == .leftMouseUp else {
            return Unmanaged.passUnretained(event)
        }

        onLeftMouseUp()
        return Unmanaged.passUnretained(event)
    }

    private nonisolated func reenableEventTapIfPossible() {
        stateLock.lock()
        let eventTap = self.eventTap
        let shouldEnable = !isStopped
        stateLock.unlock()

        guard shouldEnable, let eventTap, CFMachPortIsValid(eventTap) else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}
