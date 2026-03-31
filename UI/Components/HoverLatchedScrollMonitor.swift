import AppKit
import SwiftUI

@MainActor
final class HoverLatchedScrollMonitor<Target: Hashable>: ObservableObject {
    @Published private(set) var latchedTarget: Target?

    private var hoveredTargets: Set<Target> = []
    private var localMonitor: Any?
    private var eventFilter: ((NSEvent) -> Bool)?
    private var lastScrollTimestamp: CFAbsoluteTime = 0
    private var releaseWorkItem: DispatchWorkItem?

    private let hoverPriority: [Target]
    private let defaultTarget: Target?
    private let scrollSequenceGap: CFAbsoluteTime
    private let releaseDelay: TimeInterval

    init(
        hoverPriority: [Target],
        defaultTarget: Target? = nil,
        scrollSequenceGap: CFAbsoluteTime = 0.12,
        releaseDelay: TimeInterval = 0.16
    ) {
        self.hoverPriority = hoverPriority
        self.defaultTarget = defaultTarget
        self.scrollSequenceGap = scrollSequenceGap
        self.releaseDelay = releaseDelay
    }

    func updateHoveredTarget(_ target: Target, isHovering: Bool) {
        if isHovering {
            hoveredTargets.insert(target)
        } else {
            hoveredTargets.remove(target)
        }
    }

    func installMonitorIfNeeded(filter: ((NSEvent) -> Bool)? = nil) {
        eventFilter = filter
        guard localMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollEvent(event)
            return event
        }
    }

    func removeMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        reset()
    }

    func reset() {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        latchedTarget = nil
        hoveredTargets.removeAll()
    }

    private func handleScrollEvent(_ event: NSEvent) {
        guard eventFilter?(event) ?? true else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let phase = event.phase
        let momentumPhase = event.momentumPhase
        let startedByPhase = phase.contains(.began) || phase.contains(.mayBegin)
        let startedByGap = latchedTarget == nil || (now - lastScrollTimestamp) > scrollSequenceGap

        if startedByPhase || startedByGap {
            latchedTarget = currentHoveredTarget ?? defaultTarget
        }
        lastScrollTimestamp = now

        releaseWorkItem?.cancel()
        let hasEnded = phase.contains(.ended) || phase.contains(.cancelled) ||
            momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled)
        if hasEnded {
            latchedTarget = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.latchedTarget = nil
        }
        releaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay, execute: workItem)
    }

    private var currentHoveredTarget: Target? {
        for target in hoverPriority where hoveredTargets.contains(target) {
            return target
        }
        return nil
    }

    deinit {
        releaseWorkItem?.cancel()
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }
}
