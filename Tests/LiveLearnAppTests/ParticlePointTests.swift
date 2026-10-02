import Foundation
import Testing
import ParticleMath
@testable import LiveLearnApp

/// The Metal path writes `ParticlePoint` straight into vertex buffers; its layout is the
/// shader's `PointVertex`, and the encoders must produce what the canvases would fill.
struct ParticlePointTests {
    @Test func layoutMatchesTheShaderVertex() {
        #expect(MemoryLayout<ParticlePoint>.stride == 24)
        #expect(MemoryLayout<ParticlePoint>.offset(of: \.alpha) == 16)
        #expect(MemoryLayout<ParticlePoint>.offset(of: \.kind) == 20)
        #expect(MemoryLayout<ParticlePoint>.offset(of: \.color) == 22)
    }

    @Test func dustEncoderOrdersHalosBeforeGrainsAndBinsFaintToBright() {
        let field = NebulaFieldGeometry.Field()
        NebulaFieldGeometry.fill(field, time: 2.3)
        let layout = DustLayout()
        layout.layout(field, width: 1180, height: 760, intensity: 1, displace: nil)
        let capacity = DustLayout.pointCapacity()
        let out = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: capacity)
        defer { out.deallocate() }
        let written = layout.encodePoints(into: out, capacity: capacity, scale: 2, colorBase: 2)
        #expect(written > 0 && written <= capacity)
        let halos = (0..<written).prefix { out[$0].kind == ParticlePoint.halo }.count
        #expect(halos > 0)
        #expect((halos..<written).allSatisfy { out[$0].kind != ParticlePoint.halo })
        // Grains are grouped pearl (colour 2) then ice (colour 3), each from faint to bright.
        var lastKey = -1
        for i in halos..<written {
            let p = out[i]
            #expect(p.color == 2 || p.color == 3)
            let key = Int(p.color - 2) * 8 + Int(((Double(p.alpha) - 0.025) / 0.05).rounded())
            #expect(key >= lastKey)
            lastKey = key
            // Boxes below 1.3pt, discs above, in points: extents are pixels at scale 2.
            #expect((p.halfWidth * 2 / 2 < 1.3) == (p.kind == ParticlePoint.box))
        }
        #expect(written == halos + layout.count)
    }

    @Test func coreEncoderPutsLitBoxesFirstAndKeepsEveryGrain() {
        let workspace = StardustGeometry.Workspace()
        StardustGeometry.fill(workspace, time: 1.5, activity: 1)
        let capacity = StardustGeometry.Workspace.pointCapacity()
        let out = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: capacity)
        defer { out.deallocate() }
        let (lit, grains) = workspace.encodePoints(into: out, capacity: capacity, side: 360, scale: 2)
        #expect(grains == StardustGeometry.count)
        #expect(lit > 0 && lit + grains <= capacity)
        #expect((0..<lit).allSatisfy { out[$0].kind == ParticlePoint.box && out[$0].alpha == 1 })
        var lastBin = -1
        for i in lit..<(lit + grains) {
            let p = out[i]
            #expect(p.color <= 2)
            let bin = Int(p.color) * 8 + Int((Double(p.alpha) * 8 - 0.5).rounded())
            #expect(bin >= lastBin)
            lastBin = bin
        }
    }

    @Test func starEncoderGivesGlintsOnlyToBrightQuietStars() {
        let capacity = StarFieldGeometry.pointCapacity()
        let out = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: capacity)
        defer { out.deallocate() }
        let written = StarFieldGeometry.encodePoints(into: out, capacity: capacity, count: 290, time: 2.3,
                                                     width: 1180, height: 760, immersive: true, scale: 2)
        #expect(written >= 290 && written <= capacity)
        let halos = (0..<written).filter { out[$0].kind == ParticlePoint.halo }.count
        let bright = (0..<290).filter { StarFieldGeometry.stars[$0].bright }.count
        #expect(halos <= bright)
        // Every halo is followed by its two glint bars and then the disc.
        for i in 0..<written where out[i].kind == ParticlePoint.halo {
            #expect(out[i + 1].kind == ParticlePoint.box && out[i + 2].kind == ParticlePoint.box && out[i + 3].kind == ParticlePoint.disc)
        }
    }
}
