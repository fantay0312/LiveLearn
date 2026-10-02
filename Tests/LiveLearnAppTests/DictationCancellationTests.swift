import Foundation
import Testing
@testable import LiveLearnApp

@MainActor
struct DictationCancellationTests {
    @Test func suspendingHotkeysReleasesAnActiveHoldExactlyOnce() {
        let center = HotKeyCenter.shared
        let oldPress = center.handler, oldRelease = center.releaseHandler
        var presses = 0, releases = 0
        defer { center.resume(); center.handler = oldPress; center.releaseHandler = oldRelease }
        center.handler = { if $0 == .holdDictation { presses += 1 } }
        center.releaseHandler = { if $0 == .holdDictation { releases += 1 } }
        center.dispatchForVerification(.holdDictation)
        center.dispatchForVerification(.holdDictation)
        #expect(presses == 1)
        center.suspend()
        #expect(releases == 1)
        center.dispatchForVerification(.holdDictation, released: true)
        center.resume()
        center.dispatchForVerification(.holdDictation, released: true)
        #expect(releases == 1)
    }
}
