import Foundation
import XCTest
@testable import Capture

final class ConferenceCallObservationTests: XCTestCase {
    private struct ReplayObserver: ConferenceCallObserving {
        let observations: [String: ConferenceCallObservation]
        func observe(_ target: ConferenceCallObservationTarget) -> ConferenceCallObservation {
            observations[target.identity] ?? .unknown(.windowUnavailable)
        }
    }

    private let epoch = Date(timeIntervalSince1970: 1000)
    private func targets(_ identities: [String]) -> [ConferenceCallObservationTarget] {
        identities.map { .init(identity: $0, pid: nil, windowTitle: nil) }
    }
    @discardableResult
    private func replay(_ state: inout ConferenceCallConsentState,
                        _ observations: [String: ConferenceCallObservation],
                        seconds: Double) -> Set<String> {
        state.observe(targets(Array(observations.keys)), using: ReplayObserver(observations: observations),
                      at: epoch.addingTimeInterval(seconds))
    }

    func testConsentRecoversAfterOneInconclusiveObservation() throws {
        for reason in [ConferenceCallObservation.UnknownReason.accessibilityUnavailable,
                       .windowUnavailable, .traversalIncomplete, .controlNotFound] {
            var state = ConferenceCallConsentState()
            replay(&state, ["zoom": .active], seconds: 0)
            let session = try XCTUnwrap(state.sessionID(for: "zoom"))
            XCTAssertTrue(state.disableFaceBlur(callID: session))
            let active = replay(&state, ["zoom": .unknown(reason)], seconds: 2)
            XCTAssertTrue(active.isEmpty, "Unknown windows must not qualify for pixel bypass")
            XCTAssertEqual(state.sessionID(for: "zoom"), session)
            XCTAssertTrue(state.isBypassed(callID: session))
            XCTAssertFalse(state.shouldBypassFaceBlur(for: "zoom"))
            XCTAssertFalse(state.disableFaceBlur(callID: session), "Unknown calls cannot accept new consent")
            replay(&state, ["zoom": .active], seconds: 4)
            XCTAssertEqual(state.sessionID(for: "zoom"), session)
            XCTAssertTrue(state.isBypassed(callID: session))
            XCTAssertTrue(state.shouldBypassFaceBlur(for: "zoom"))
        }
    }

    func testRepeatedUnknownDoesNotExtendGracePeriod() throws {
        var state = ConferenceCallConsentState()
        replay(&state, ["meet": .active], seconds: 0)
        let session = try XCTUnwrap(state.sessionID(for: "meet"))
        XCTAssertTrue(state.disableFaceBlur(callID: session))
        for second in [2.0, 4, 6, 8] {
            replay(&state, ["meet": .unknown(.traversalIncomplete)], seconds: second)
            XCTAssertEqual(state.sessionID(for: "meet"), session)
        }
        replay(&state, ["meet": .unknown(.traversalIncomplete)], seconds: 8.001)
        XCTAssertNil(state.sessionID(for: "meet"))
        replay(&state, ["meet": .active], seconds: 10)
        let replacement = try XCTUnwrap(state.sessionID(for: "meet"))
        XCTAssertNotEqual(replacement, session)
        XCTAssertFalse(state.isBypassed(callID: replacement))
    }

    func testConfirmedEndAndWindowDisappearanceRevokeConsentImmediately() throws {
        for finalObservation: [String: ConferenceCallObservation] in [["zoom": .ended], [:]] {
            var state = ConferenceCallConsentState()
            replay(&state, ["zoom": .active], seconds: 0)
            let session = try XCTUnwrap(state.sessionID(for: "zoom"))
            XCTAssertTrue(state.disableFaceBlur(callID: session))
            replay(&state, finalObservation, seconds: 1)
            XCTAssertNil(state.sessionID(for: "zoom"))
            XCTAssertFalse(state.isBypassed(callID: session))
            replay(&state, ["zoom": .active], seconds: 2)
            XCTAssertNotEqual(state.sessionID(for: "zoom"), session)
        }
    }

    func testUnknownCannotCreateConsentedSession() {
        var state = ConferenceCallConsentState()
        replay(&state, ["meet": .unknown(.controlNotFound)], seconds: 0)
        XCTAssertNil(state.sessionID(for: "meet"))
        XCTAssertFalse(state.disableFaceBlur(callID: "unobserved"))
    }

    func testConsentCannotLeakToAnotherWindowOrChangedIdentity() throws {
        var state = ConferenceCallConsentState()
        replay(&state, ["main": .active, "popout": .active], seconds: 0)
        let main = try XCTUnwrap(state.sessionID(for: "main"))
        XCTAssertTrue(state.disableFaceBlur(callID: main))
        XCTAssertFalse(state.isBypassed(callID: try XCTUnwrap(state.sessionID(for: "popout"))))
        replay(&state, ["new-title-or-url": .active, "popout": .active], seconds: 1)
        XCTAssertFalse(state.isBypassed(callID: main))
        XCTAssertFalse(state.isBypassed(callID: try XCTUnwrap(state.sessionID(for: "new-title-or-url"))))
    }

    func testLongObservationGapAndBackwardsClockRequireFreshConsent() throws {
        for time in [9.0, -1] {
            var state = ConferenceCallConsentState()
            replay(&state, ["zoom": .active], seconds: 0)
            let session = try XCTUnwrap(state.sessionID(for: "zoom"))
            XCTAssertTrue(state.disableFaceBlur(callID: session))
            replay(&state, ["zoom": .active], seconds: time)
            XCTAssertNotEqual(state.sessionID(for: "zoom"), session)
            XCTAssertFalse(state.shouldBypassFaceBlur(for: "zoom"))
        }
    }

    func testObservationCarriesWindowRequestThroughInjectedBoundary() throws {
        struct WindowObserver: ConferenceCallObserving {
            func observe(_ target: ConferenceCallObservationTarget) -> ConferenceCallObservation {
                target.pid == 42 && target.windowTitle == "Call"
                    ? .active : .unknown(.windowUnavailable)
            }
        }
        var state = ConferenceCallConsentState()
        let target = ConferenceCallObservationTarget(identity: "window", pid: 42, windowTitle: "Call")
        state.observe([target], using: WindowObserver(), at: epoch)
        let session = try XCTUnwrap(state.sessionID(for: "window"))
        XCTAssertTrue(state.disableFaceBlur(callID: session))
        XCTAssertTrue(state.shouldBypassFaceBlur(for: "window"))
        let inaccessible = ConferenceCallObservationTarget(identity: "window", pid: nil, windowTitle: nil)
        state.observe([inaccessible], using: WindowObserver(), at: epoch.addingTimeInterval(1))
        XCTAssertFalse(state.shouldBypassFaceBlur(for: "window"))
        state.observe([target], using: WindowObserver(), at: epoch.addingTimeInterval(2))
        XCTAssertTrue(state.shouldBypassFaceBlur(for: "window"))
    }

    func testGraceCanFollowSlowerCaptureCadence() throws {
        var state = ConferenceCallConsentState()
        let target = targets(["zoom"])
        let active = ReplayObserver(observations: ["zoom": .active])
        state.observe(target, using: active, at: epoch, uncertaintyGraceInterval: 180)
        let session = try XCTUnwrap(state.sessionID(for: "zoom"))
        XCTAssertTrue(state.disableFaceBlur(callID: session))
        state.observe(target, using: active, at: epoch.addingTimeInterval(60), uncertaintyGraceInterval: 180)
        XCTAssertEqual(state.sessionID(for: "zoom"), session)
        XCTAssertTrue(state.shouldBypassFaceBlur(for: "zoom"))
    }

    func testResetRevokesRetainedConsent() throws {
        var state = ConferenceCallConsentState()
        replay(&state, ["zoom": .active], seconds: 0)
        let session = try XCTUnwrap(state.sessionID(for: "zoom"))
        XCTAssertTrue(state.disableFaceBlur(callID: session))
        replay(&state, ["zoom": .unknown(.windowUnavailable)], seconds: 1)
        state.reset()
        replay(&state, ["zoom": .active], seconds: 2)
        XCTAssertFalse(state.isBypassed(callID: session))
        XCTAssertNotEqual(state.sessionID(for: "zoom"), session)
    }
}
