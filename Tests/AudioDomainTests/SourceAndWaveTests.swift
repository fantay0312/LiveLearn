import Testing
import Foundation
@testable import AudioDomain

@Suite("Multi-app source descriptor")
struct MultiAppSourceTests {
    @Test("A set of applications keeps its order, folds into one stable id, and reads as one phrase")
    func multiApp() {
        let s = AudioSourceDescriptor(kind: .application, bundleIdentifier: "com.b", displayName: "B、A", bundleIdentifiers: ["com.b", "com.a"])
        #expect(s.allBundleIdentifiers == ["com.b", "com.a"])
        #expect(s.bundleIdentifier == "com.b")
        #expect(s.id == "app:com.a+com.b")
        let reordered = AudioSourceDescriptor(kind: .application, bundleIdentifier: "com.a", displayName: "A、B", bundleIdentifiers: ["com.a", "com.b"])
        #expect(reordered.id == s.id, "the lane key does not depend on the order of ticking")
        #expect(AudioSourceDescriptor.applicationsLabel([]) == "选择应用")
        #expect(AudioSourceDescriptor.applicationsLabel(["Safari"]) == "Safari")
        #expect(AudioSourceDescriptor.applicationsLabel(["Safari", "Zoom"]) == "Safari、Zoom")
        #expect(AudioSourceDescriptor.applicationsLabel(["Safari", "Zoom", "Music"]) == "Safari 等 3 个应用")
    }

    @Test("A single application is the plain old shape: no list is stored, the old id is kept")
    func singleApp() throws {
        let s = AudioSourceDescriptor(kind: .application, bundleIdentifier: "com.apple.Safari", displayName: "Safari", bundleIdentifiers: ["com.apple.Safari"])
        #expect(s.bundleIdentifiers == nil)
        #expect(s.allBundleIdentifiers == ["com.apple.Safari"])
        #expect(s.id == "app:com.apple.Safari")
        let json = try JSONEncoder().encode(s)
        #expect(!String(decoding: json, as: UTF8.self).contains("bundleIdentifiers"))
    }

    @Test("Archives written before multi-app capture still decode")
    func decodesOldJSON() throws {
        let old = #"{"kind":"application","bundleIdentifier":"com.apple.Safari","displayName":"Safari"}"#
        let s = try JSONDecoder().decode(AudioSourceDescriptor.self, from: Data(old.utf8))
        #expect(s.kind == .application)
        #expect(s.allBundleIdentifiers == ["com.apple.Safari"])
        #expect(s.bundleIdentifiers == nil)
        let round = try JSONDecoder().decode(AudioSourceDescriptor.self, from: JSONEncoder().encode(AudioSourceDescriptor(kind: .application, bundleIdentifier: nil, displayName: "A、B", bundleIdentifiers: ["com.a", "com.b"])))
        #expect(round.allBundleIdentifiers == ["com.a", "com.b"])
        #expect(round.bundleIdentifier == "com.a")
    }

    @Test("Other kinds never report applications")
    func otherKinds() {
        #expect(AudioSourceDescriptor.system.allBundleIdentifiers.isEmpty)
        #expect(AudioSourceDescriptor.defaultMicrophone.allBundleIdentifiers.isEmpty)
    }
}

@Suite("Wave trace")
struct WaveTraceTests {
    @Test("Silence leaves a flat trace exactly where it was")
    func silenceIsStill() {
        var t = WaveTrace(length: 8)
        let before = t
        t.push(level: 0)
        t.push(level: 0)
        #expect(t == before, "pushing zeros into a flat trace must compare equal, so the model publishes nothing")
        #expect(t.isFlat)
        #expect(t.current == 0)
    }

    @Test("Sound scrolls in from the right and moves the ripple; the phase stays bounded")
    func soundFlows() {
        var t = WaveTrace(length: 4)
        t.push(level: 0.5)
        #expect(t.samples == [0, 0, 0, 0.5])
        #expect(t.phase > 0)
        #expect(!t.isFlat)
        let p = t.phase
        t.push(level: 1)
        #expect(t.samples == [0, 0, 0.5, 1])
        #expect(t.phase > p)
        for _ in 0..<10_000 { t.push(level: 1) }
        // Bounded by the drawn ripple's period (20π, the two harmonics' common period), not 2π:
        // a wrap on 2π would tick the 1.9× harmonic.
        #expect(t.phase >= 0 && t.phase < WaveTrace.phasePeriod)
        // Levels are clamped to 0...1.
        t.push(level: 7)
        #expect(t.current == 1)
    }
}
