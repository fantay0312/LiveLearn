import Foundation
import Testing
import ParticleMath
@testable import LiveLearnApp

/// The sprite scenes of the small Home surfaces must write what their canvases fill: the same
/// count, in the canvas's order (inline halos first, then alpha bins faint to bright, or point
/// by point), with the sprite kinds the canvas primitives call for.
struct SpriteSceneTests {
    private let white = SIMD4<Float>(1, 1, 1, 1)

    @Test func navigationRateFollowsMotionRatherThanASeparateWallClock() {
        let motion = NavigationStarMotion()
        let workspace = NavigationStarScene.makeWorkspace()
        var scene = NavigationStarScene(motion: motion, selection: 0, tint: white)
        scene.advance(to: 0, workspace: workspace)
        #expect(scene.rate == NavigationStarMotion.idleRate)
        scene.selection = 2
        #expect(scene.rate == NavigationStarMotion.flightRate)
        scene.advance(to: 0, workspace: workspace)
        for frame in 1...12 { scene.advance(to: Double(frame) / 60, workspace: workspace) }
        #expect(scene.rate == NavigationStarMotion.flightRate)
        for _ in 0..<20 { scene.advance(to: 0.2, workspace: workspace) }
        #expect(scene.rate == NavigationStarMotion.flightRate)
        for frame in 13...30 { scene.advance(to: Double(frame) / 60, workspace: workspace) }
        #expect(scene.rate == NavigationStarMotion.idleRate)
        scene.selection = 1
        #expect(scene.rate == NavigationStarMotion.flightRate)
    }

    private func encode<S: SpriteScene>(_ scene: S, time: Double, width: Double, height: Double) -> [ParticlePoint] {
        let out = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: scene.capacity)
        defer { out.deallocate() }
        let n = scene.encode(into: out, capacity: scene.capacity, time: time, width: width, height: height, scale: 2)
        #expect(n > 0 && n <= scene.capacity)
        return (0..<n).map { out[$0] }
    }

    @Test func wordmarkPutsHalosFirstThenFiveBinsFaintToBright() {
        let scene = WordmarkScene(tint: white)
        let points = encode(scene, time: 2.3, width: 98, height: 36)
        let grains = ParticleWordmark.grains.count
        let halos = (grains + 156) / 157
        #expect(grains > 500)
        #expect(points.count == grains + halos && scene.capacity == points.count)
        #expect(points.prefix(halos).allSatisfy { $0.kind == ParticlePoint.halo && $0.halfWidth == 3.2 && $0.color == 0 })
        var last: Float = -1
        for p in points.dropFirst(halos) {
            #expect(p.kind == ParticlePoint.box && p.color == 0 && p.halfWidth == p.halfHeight)
            #expect(p.alpha >= last)
            last = p.alpha
            let bin = Int((p.alpha * 5 - 0.5).rounded())
            #expect((0..<5).contains(bin))
        }
        #expect(scene.rate == 15)
        // Too small a capacity writes nothing rather than overrunning.
        let out = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: 8)
        defer { out.deallocate() }
        #expect(scene.encode(into: out, capacity: 8, time: 0, width: 98, height: 36, scale: 2) == 0)
    }

    @Test func navigationDustUsesSmallGrainsAndSoftHalosWithoutCrossRays() {
        let motion = NavigationStarMotion()
        for frame in 0..<60 { _ = motion.sample(time: Double(frame) / 30, selection: 1) }
        let scene = NavigationStarScene(motion: motion, selection: 1, tint: white)
        let points = encode(scene, time: 2, width: OrbitRow.size.width, height: OrbitRow.size.height)
        #expect(points.count == NavigationStarMotion.count * 2)
        #expect(scene.capacity >= points.count)
        for index in 0..<NavigationStarMotion.count {
            let i = index * 2
            #expect(points[i].kind == ParticlePoint.halo && points[i].halfWidth < 6)
            #expect(points[i + 1].kind == ParticlePoint.disc && points[i + 1].halfWidth < 1)
            #expect(points[i].x == points[i + 1].x && points[i].y == points[i + 1].y)
            #expect(points[i].alpha < points[i + 1].alpha)
            #expect(points[i].color == 0 && points[i + 1].color == 0)
        }
        // The scene is the field's own motion instance: another instance is another scene.
        #expect(scene == NavigationStarScene(motion: motion, selection: 1, tint: white))
        #expect(scene != NavigationStarScene(motion: NavigationStarMotion(), selection: 1, tint: white))
        #expect(scene != NavigationStarScene(motion: motion, selection: 2, tint: white))
        #expect(scene != NavigationStarScene(motion: motion, selection: 1, tint: white, strength: NavigationStarField.modeStrength))
    }

    @Test func nebulaHaloOrdersHalosThenSixBinsAndUsesDiscsThroughout() {
        let scene = NebulaHaloScene(strength: 0.9, tint: white)
        let points = encode(scene, time: 2.3, width: 113, height: 38)
        let halos = (0..<72).filter { Double(($0 * 37 + 11) % 73) / 73 > 0.94 }.count
        #expect(halos > 0 && NebulaHaloScene.haloCount == halos)
        #expect(points.count == 72 + halos && scene.capacity == points.count)
        #expect(points.prefix(halos).allSatisfy { $0.kind == ParticlePoint.halo && $0.halfWidth == 8 })
        var last: Float = -1
        for p in points.dropFirst(halos) {
            #expect(p.kind == ParticlePoint.disc && p.color == 0)
            #expect(p.alpha >= last)
            last = p.alpha
            #expect((0..<6).contains(Int((p.alpha * 6 - 0.5).rounded())))
            // Radii 0.28–0.76 pt, in pixels at 2×.
            #expect(p.halfWidth >= 0.56 && p.halfWidth <= 1.52)
        }
    }

    @Test func controlLightLeadsWithOneClippedGlowAndTheStopButtonHasNone() {
        let start = ControlLightScene(glows: true, inset: 4, breathes: true, emphasized: false, dimmed: false,
                                      haloStrength: 0.85, haloSpeed: 1, glowTint: white, haloTint: white)
        let points = encode(start, time: 2.3, width: 192, height: 48)
        #expect(points.count == 1 + NebulaHaloScene.capacity && start.capacity == points.count)
        let glow = points[0]
        #expect(glow.kind == ParticlePoint.glow && glow.color == 0)
        // At 2.3 s the breath is 1: radius 0.58 of the 184 pt capsule, centre at 0.47 × 0.54,
        // flattened to 0.28, at the button's peak alpha.
        #expect(abs(Double(glow.halfWidth) - 184 * 0.58 * 2) < 1e-3)
        #expect(abs(Double(glow.halfHeight) - 184 * 0.58 * 0.28 * 2) < 1e-3)
        #expect(abs(Double(glow.x) - (4 + 184 * 0.47) * 2) < 1e-3)
        #expect(abs(Double(glow.y) - 48 * 0.54 * 2) < 1e-3)
        #expect(abs(Double(glow.alpha) - (0.028 + 0.115)) < 1e-5)
        #expect(points.dropFirst().allSatisfy { $0.color == 1 && $0.kind != ParticlePoint.glow })
        #expect(start.clip(width: 192, height: 48, scale: 2) == ParticleFrame.Clip(center: SIMD2(192, 48), halfExtent: SIMD2(184, 48)))

        let stop = ControlLightScene(glows: false, inset: 0, breathes: false, emphasized: false, dimmed: false,
                                     haloStrength: 0.18, haloSpeed: 1, glowTint: white, haloTint: white)
        let stopPoints = encode(stop, time: 2.3, width: 80, height: 48)
        #expect(stopPoints.count == NebulaHaloScene.capacity)
        #expect(stopPoints.allSatisfy { $0.kind != ParticlePoint.glow && $0.color == 1 })
        #expect(stop.clip(width: 80, height: 48, scale: 2) == nil)

        // Disabled or busy: the breath holds at 0.25 and the glow is at 30 %.
        let dimmed = ControlLightScene(glows: true, inset: 4, breathes: false, emphasized: true, dimmed: true,
                                       haloStrength: 0.2, haloSpeed: 1.9, glowTint: white, haloTint: white)
        #expect(dimmed.phase(at: 2.3) == 0.25)
        let dimmedGlow = encode(dimmed, time: 2.3, width: 192, height: 48)[0]
        #expect(abs(Double(dimmedGlow.alpha) - (0.075 + 0.25 * 0.115) * 0.30) < 1e-5)
        #expect(abs(Double(dimmedGlow.halfWidth) - 184 * (0.46 + 0.25 * 0.12) * 2) < 1e-3)
    }

    // MARK: The Canvas formulas, re-derived

    /// Every wordmark sprite — position, size, alpha bin and halo — recomputed from
    /// `ParticleWordmark`'s Canvas arithmetic, including the bin ordering. The Canvas evaluates
    /// `sin(ωt + φ)` by angle addition (`sin ωt cos φ + cos ωt sin φ`) and so does the encoder;
    /// this test recovers φ and takes the plain sine, so it does not repeat the optimisation it
    /// is checking.
    @Test func wordmarkSpritesReproduceTheCanvasPositionsAndBins() {
        let t = 2.3, scale: Double = 2
        let grains = ParticleWordmark.grains
        let halos = (grains.count + 156) / 157
        var x = [Double](), y = [Double](), light = [Double](), bin = [Int]()
        for grain in grains {
            let phi = atan2(grain.sinPhase, grain.cosPhase)
            x.append(grain.point.x + sin(0.65 * t + phi) * 0.12)
            y.append(grain.point.y + cos(0.53 * t + phi) * 0.10)
            let l = 0.68 + sin(0.75 * t + phi) * 0.22
            light.append(l)
            bin.append(min(4, max(0, Int(l * 5))))
        }
        // The Canvas fills five paths faint to bright, each in grain order, after the inline halos.
        var start = [Int](repeating: halos, count: 5)
        for b in 1..<5 { start[b] = start[b - 1] + bin.filter { $0 == b - 1 }.count }
        let points = encode(WordmarkScene(tint: white), time: t, width: 98, height: 36)
        var halo = 0
        for index in grains.indices {
            let px = Float(x[index] * scale), py = Float(y[index] * scale)
            if index % 157 == 0 {
                let h = points[halo]; halo += 1
                #expect(abs(h.x - px) < 1e-3 && abs(h.y - py) < 1e-3)
                #expect(abs(Double(h.alpha) - light[index] * 0.22) < 1e-6)
                #expect(h.halfWidth == 3.2 && h.kind == ParticlePoint.halo)
            }
            let g = points[start[bin[index]]]; start[bin[index]] += 1
            #expect(abs(g.x - px) < 1e-3 && abs(g.y - py) < 1e-3)
            #expect(abs(Double(g.halfWidth) - grains[index].radius * scale) < 1e-4)
            #expect(g.halfWidth == g.halfHeight)
            #expect(abs(Double(g.alpha) - (Double(bin[index]) + 0.5) / 5) < 1e-6)
        }
        #expect(halo == halos)
    }

    /// The nebula orbit: `seed`, `depth`, the angle, the radial wobble, `flow`, the alpha bins and
    /// the `seed > 0.94` halos, straight out of `NebulaHalo`'s Canvas.
    @Test func nebulaSpritesReproduceTheCanvasOrbit() {
        let t = 2.3, w = 113.0, h = 38.0, scale: Double = 2, strength = 0.9
        var x = [Double](), y = [Double](), alpha = [Double](), radius = [Double](), bin = [Int]()
        for index in 0..<72 {
            let seed = Double((index * 37 + 11) % 73) / 73
            let depth = Double((index * 19 + 7) % 71) / 71
            let a = Double(index) * 2.39996 + t * (0.33 + depth * 0.17)
            let radial = 0.80 + depth * 0.20 + sin(t * 0.55 + seed * 12) * 0.045
            x.append(w * (0.5 + cos(a) * 0.46 * radial))
            y.append(h * (0.5 + sin(a) * 0.40 * radial))
            let wave = 0.5 + 0.5 * sin(a * 2 - t * 0.21)
            let flow = 0.30 + 0.70 * wave * wave
            let al = (0.22 + depth * 0.60) * flow * strength
            alpha.append(al)
            radius.append(0.28 + seed * 0.48)
            bin.append(min(5, max(0, Int(al * 6))))
        }
        let halos = (0..<72).filter { Double(($0 * 37 + 11) % 73) / 73 > 0.94 }.count
        var start = [Int](repeating: halos, count: 6)
        for b in 1..<6 { start[b] = start[b - 1] + bin.filter { $0 == b - 1 }.count }
        let points = encode(NebulaHaloScene(strength: strength, tint: white), time: t, width: w, height: h)
        var halo = 0
        for index in 0..<72 {
            let px = Float(x[index]) * Float(scale), py = Float(y[index]) * Float(scale)
            if Double((index * 37 + 11) % 73) / 73 > 0.94 {
                let g = points[halo]; halo += 1
                #expect(abs(g.x - px) < 1e-3 && abs(g.y - py) < 1e-3)
                #expect(abs(Double(g.alpha) - alpha[index] * 0.26) < 1e-6)
                #expect(g.halfWidth == 8 && g.kind == ParticlePoint.halo)
            }
            let g = points[start[bin[index]]]; start[bin[index]] += 1
            #expect(abs(g.x - px) < 1e-3 && abs(g.y - py) < 1e-3)
            #expect(abs(Double(g.halfWidth) - radius[index] * scale) < 1e-4)
            #expect(abs(Double(g.alpha) - (Double(bin[index]) + 0.5) / 6) < 1e-6)
        }
        #expect(halo == halos)
    }

    /// The paper rule: in the light theme no surface draws a soft halo — the wordmark, the
    /// orbit (dock and modes), the capsule's orbit — and the capsule has no breathing glow. What
    /// is left is exactly the dark frame's grains, in the same order; the engraved wordmark
    /// keeps each grain's bin at its ink alpha (0.82…0.98).
    @Test func paperScenesDrawTheirGrainsWithoutHalos() {
        let wordmark = encode(WordmarkScene(tint: white, engraved: true), time: 2.3, width: 98, height: 36)
        let litWordmark = encode(WordmarkScene(tint: white), time: 2.3, width: 98, height: 36)
        #expect(wordmark.count == ParticleWordmark.grains.count)
        #expect(wordmark.allSatisfy { $0.kind == ParticlePoint.box && $0.alpha >= 0.82 - 1e-6 })
        #expect(zip(wordmark, litWordmark.dropFirst(WordmarkScene.haloCount)).allSatisfy {
            $0.x == $1.x && abs(Double($0.alpha) - (0.80 + 0.20 * Double($1.alpha))) < 1e-6
        })

        let nebula = encode(NebulaHaloScene(strength: 0.85, tint: white, halos: false), time: 2.3, width: 192, height: 48)
        let litNebula = encode(NebulaHaloScene(strength: 0.85, tint: white), time: 2.3, width: 192, height: 48)
        #expect(nebula.count == NebulaHaloScene.count && nebula.allSatisfy { $0.kind == ParticlePoint.disc })
        #expect(zip(nebula, litNebula.dropFirst(NebulaHaloScene.haloCount)).allSatisfy { $0.x == $1.x && $0.alpha == $1.alpha })

        let motion = NavigationStarMotion()
        for frame in 0..<30 { _ = motion.sample(time: Double(frame) / 30, selection: 0) }
        let nav = encode(NavigationStarScene(motion: motion, selection: 0, tint: white, halos: false), time: 1,
                         width: OrbitRow.size.width, height: OrbitRow.size.height)
        #expect(nav.count == NavigationStarMotion.count && nav.allSatisfy { $0.kind == ParticlePoint.disc })

        let paperCapsule = ControlLightScene(glows: false, inset: 4, breathes: true, emphasized: false, dimmed: false,
                                             haloStrength: 0.85, haloSpeed: 1, glowTint: white, haloTint: white, halos: false)
        let capsule = encode(paperCapsule, time: 2.3, width: 192, height: 48)
        #expect(capsule.count == NebulaHaloScene.count)
        #expect(capsule.allSatisfy { $0.kind == ParticlePoint.disc && $0.color == 1 })
        #expect(paperCapsule.clip(width: 192, height: 48, scale: 2) == nil)
    }

    /// Canvas and Metal share the same soft grain appearance and continuous text exclusion.
    @Test func navigationStarAlphaAndRadiusFollowTheCanvasTwinkle() {
        let t = 2.0, w = Double(OrbitRow.size.width), h = Double(OrbitRow.size.height), scale: Float = 2
        let motion = NavigationStarMotion()
        var points: [CGPoint] = []
        for frame in 0...60 { points = motion.sample(time: Double(frame) / 30, selection: 1) }
        let out = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: NavigationStarScene.capacity)
        defer { out.deallocate() }
        let n = NavigationStarScene.encode(points: points, into: out, capacity: NavigationStarScene.capacity,
                                           time: t, width: w, height: h, scale: scale)
        var i = 0
        var dimmed = 0
        for (index, point) in points.enumerated() {
            let x = point.x * w, y = point.y * h
            let visibility = NavigationStarMotion.textVisibility(at: point)
            if visibility < 1 { dimmed += 1 }
            let grain = NavigationStarMotion.appearance(index, time: t)
            #expect(abs(Double(out[i].alpha) - grain.haloOpacity * visibility) < 1e-6)
            #expect(abs(Double(out[i].halfWidth) - grain.haloRadius * Double(scale)) < 1e-4)
            i += 1
            #expect(abs(out[i].x - Float(x) * scale) < 1e-3 && abs(out[i].y - Float(y) * scale) < 1e-3)
            #expect(abs(Double(out[i].alpha) - grain.opacity * visibility) < 1e-6)
            #expect(abs(Double(out[i].halfWidth) - grain.radius * Double(scale)) < 1e-4)
            i += 1
        }
        #expect(i == n)
        // The dimming rule has to bite on a settled field, or the test proves nothing about it.
        #expect(dimmed > 0)
    }

    /// Home's modes draw the dock's field a step quieter: the same sprites, every alpha scaled.
    @Test func navigationStrengthScalesAlphaAndNothingElse() {
        let motion = NavigationStarMotion()
        var points: [CGPoint] = []
        for frame in 0...60 { points = motion.sample(time: Double(frame) / 30, selection: 1) }
        let capacity = NavigationStarScene.capacity
        let full = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: capacity)
        let quiet = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: capacity)
        defer { full.deallocate(); quiet.deallocate() }
        let w = Double(OrbitRow.size.width), h = Double(OrbitRow.size.height), strength = NavigationStarField.modeStrength
        let n = NavigationStarScene.encode(points: points, into: full, capacity: capacity, time: 2, width: w, height: h, scale: 2)
        let m = NavigationStarScene.encode(points: points, into: quiet, capacity: capacity, time: 2, width: w, height: h, scale: 2,
                                           strength: strength)
        #expect(n == m && n > 0)
        for i in 0..<n {
            #expect(quiet[i].x == full[i].x && quiet[i].y == full[i].y && quiet[i].halfWidth == full[i].halfWidth
                    && quiet[i].kind == full[i].kind)
            #expect(abs(Double(quiet[i].alpha) - Double(full[i].alpha) * strength) < 1e-6)
        }
    }

    /// A point primitive is capped at 511 px: the 184 pt capsule's glow fits at 2× and would be
    /// silently cropped at 3×, which is what the encoder's assertion is there to catch.
    @Test func glowSpriteFitsThePointSizeLimitAtTwoTimesButNotAtThree() {
        let scene = ControlLightScene(glows: true, inset: 4, breathes: true, emphasized: false, dimmed: false,
                                      haloStrength: 0.85, haloSpeed: 1, glowTint: white, haloTint: white)
        let out = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: scene.capacity)
        defer { out.deallocate() }
        let capsule = Double(LuminousActionButton.capsuleWidth)
        _ = scene.encode(into: out, capacity: scene.capacity, time: 2.3, width: capsule + 8, height: 48, scale: 2)
        let expected: Float = (2 * Float(capsule * 0.58 * 2)).rounded(.up) + 2   // 429 px
        #expect(out[0].spriteSize == expected)
        #expect(out[0].spriteSize <= ParticlePoint.maxSpriteSize && out[0].fitsPointSizeLimit)
        // Not through `encode`: the assertion would trap first, which is the point of it.
        let wide = ParticlePoint(x: 0, y: 0, halfWidth: Float(capsule * 0.58 * 3), halfHeight: 1,
                                 alpha: 1, kind: ParticlePoint.glow, color: 0)
        #expect(!wide.fitsPointSizeLimit)
    }
}
