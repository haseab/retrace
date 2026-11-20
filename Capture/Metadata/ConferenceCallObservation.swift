import Foundation

/// An inconclusive AX lookup is not evidence that a call ended.
enum ConferenceCallObservation: Sendable, Equatable {
    enum UnknownReason: String, Sendable {
        case accessibilityUnavailable, windowUnavailable, traversalIncomplete, controlNotFound
    }
    case active
    case ended
    case unknown(UnknownReason)
}

struct ConferenceCallObservationTarget: Sendable {
    let identity: String
    let pid: pid_t?
    let windowTitle: String?
}

/// OS discovery is injected; consent transitions use the same code in capture and replays.
protocol ConferenceCallObserving: Sendable {
    func observe(_ target: ConferenceCallObservationTarget) -> ConferenceCallObservation
}

extension ConferenceCallConsentState {
    @discardableResult
    mutating func observe(
        _ targets: [ConferenceCallObservationTarget],
        using observer: any ConferenceCallObserving,
        at time: Date,
        uncertaintyGraceInterval: TimeInterval = 8
    ) -> Set<String> {
        var observations: [String: ConferenceCallObservation] = [:]
        for target in targets { observations[target.identity] = observer.observe(target) }
        update(observations: observations, at: time, uncertaintyGraceInterval: uncertaintyGraceInterval)
        return Set(observations.compactMap { $0.value == .active ? $0.key : nil })
    }
}
