import Testing
import SessionDomain
@testable import LiveLearnApp

struct SessionActionAppearanceTests {
    @Test func transitionalStatesNeverOfferInvalidTransportActions() {
        for state in [SessionState.idle, .preparing, .connecting, .draining, .stopping, .completed, .failed] {
            #expect(!SessionActionAppearance.canPauseOrResume(state))
        }
        for state in [SessionState.preparing, .connecting, .running, .paused, .degraded, .reconnecting] {
            #expect(SessionActionAppearance.canStop(state))
        }
        for state in [SessionState.idle, .draining, .stopping, .completed, .failed] {
            #expect(!SessionActionAppearance.canStop(state))
        }
    }
    @Test func theSameLivingFormContinuesAcrossPrimarySessionActions() {
        for state in [SessionState.idle, .preparing, .connecting, .running, .paused, .reconnecting, .degraded, .draining, .stopping] {
            #expect(SessionActionAppearance.primary(for: state).hasLivingForm)
        }
        #expect(!SessionActionAppearance.stop.hasLivingForm)
    }

    @Test func loadingIsReservedForActualTransitionalStates() {
        for state in [SessionState.preparing, .connecting, .draining, .stopping] {
            #expect(SessionActionAppearance.primary(for: state).isBusy)
        }
        for state in [SessionState.idle, .running, .paused, .degraded, .reconnecting, .completed, .failed] {
            #expect(!SessionActionAppearance.primary(for: state).isBusy)
        }
    }

    @Test func pauseResumeAndRecoveryRemainActionable() {
        #expect(SessionActionAppearance.primary(for: .paused) == .resume)
        for state in [SessionState.running, .reconnecting, .degraded] {
            #expect(SessionActionAppearance.primary(for: state) == .pause)
        }
        for state in [SessionState.failed, .completed, .idle] {
            #expect(SessionActionAppearance.primary(for: state) == .start)
        }
        #expect(!SessionActionAppearance.stop.isBusy)
    }
}
