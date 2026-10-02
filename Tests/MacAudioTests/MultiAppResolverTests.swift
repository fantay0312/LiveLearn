import Testing
@testable import MacAudio

@Suite("Multi-app membership")
struct MultiAppResolverTests {
    @Test("Several bundle ids resolve to one membership: not running when none of them runs, union otherwise")
    func mergesMemberships() {
        // Bundle ids that no machine runs: the merged membership must say so without throwing.
        let none = ApplicationAudioIdentityResolver.resolve(bundleIdentifiers: ["com.livelearn.test.absent-a", "com.livelearn.test.absent-b"])
        #expect(!none.isRunning)
        #expect(none.memberObjectIDs.isEmpty)
        #expect(none.rootPIDs.isEmpty)
        #expect(!none.anyOutputRunning)
        #expect(none.bundleIdentifier == "com.livelearn.test.absent-a+com.livelearn.test.absent-b")
        // A single id takes the single-app path unchanged.
        let single = ApplicationAudioIdentityResolver.resolve(bundleIdentifiers: ["com.livelearn.test.absent-a"])
        #expect(single.bundleIdentifier == "com.livelearn.test.absent-a")
        #expect(!single.isRunning)
    }
}
