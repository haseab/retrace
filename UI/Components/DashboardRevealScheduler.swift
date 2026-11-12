import Foundation

/// Gives AppKit URL delivery precedence over activation/reopen dashboard fallbacks.
@MainActor
final class DashboardRevealScheduler {
    private var pendingReveal: Task<Void, Never>?
    private let delay: @MainActor () async throws -> Void
    private(set) var isPresentingDeeplink = false

    init(delay: @escaping @MainActor () async throws -> Void = {
        try await Task.sleep(for: .milliseconds(150), clock: .continuous)
    }) {
        self.delay = delay
    }

    @discardableResult
    func schedule(_ reveal: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        cancelPendingReveal()
        guard !isPresentingDeeplink else { return nil }

        let delay = delay
        let task = Task { @MainActor [weak self] in
            do {
                try await delay()
            } catch {
                return
            }
            guard !Task.isCancelled, let self, !self.isPresentingDeeplink else { return }
            self.pendingReveal = nil
            reveal()
        }
        pendingReveal = task
        return task
    }

    func cancelPendingReveal() {
        pendingReveal?.cancel()
        pendingReveal = nil
    }

    func beginDeeplinkPresentation() {
        cancelPendingReveal()
        isPresentingDeeplink = true
    }

    func finishDeeplinkPresentation() {
        isPresentingDeeplink = false
    }
}
