import Testing
import Foundation
@testable import CaptionDomain

/// Replays the shared JSON fixtures under `fixtures/captions/`. The Windows reducer must pass the same files.
@Suite("Shared fixtures")
struct FixtureReplayTests {
    struct Fixture: Decodable {
        struct Expect: Decodable {
            var segmentCount: Int
            var sourceTexts: [String]
            var translations: [String]
            var gapCount: Int
            var activeProviderEpoch: UInt64
            var mustNotContain: String
        }
        var name: String
        var events: [CaptionEvent]
        var expect: Expect
    }

    static var fixturesDir: URL {
        // Tests/CaptionDomainTests/FixtureReplayTests.swift → repo root
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/captions")
    }

    @Test("edge-cases.json replays to the expected snapshot")
    func edgeCases() throws {
        let url = Self.fixturesDir.appendingPathComponent("edge-cases.json")
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        var reducer = CaptionReducer(sessionID: "fixture")
        for e in fixture.events { _ = reducer.apply(e) }
        let snap = reducer.snapshot
        let segs = snap.segments
        #expect(segs.count == fixture.expect.segmentCount)
        #expect(segs.map(\.sourceText) == fixture.expect.sourceTexts)
        #expect(segs.map { $0.translation?.text ?? "" } == fixture.expect.translations)
        #expect(snap.items.filter { if case .gap = $0 { return true } else { return false } }.count == fixture.expect.gapCount)
        #expect(snap.activeProviderEpochs["remote"] == fixture.expect.activeProviderEpoch)
        #expect(!segs.contains { $0.sourceText.contains(fixture.expect.mustNotContain) })
        // Segments from the old epoch are frozen, not deleted.
        #expect(segs.filter { $0.providerEpoch == 1 }.allSatisfy { $0.presentationState == .final || $0.presentationState == .frozen })
    }
}
