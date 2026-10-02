import AppKit
import SwiftUI
import ParticleMath

/// `--render-ambient-parity <dir> [scale…]`: the Canvas frame and the Metal frame of one instant,
/// written side by side, so the GPU path can be checked against the reference pixel by pixel
/// without a window. Canvas frames come from `ImageRenderer` (the same RenderBox rasteriser the
/// window uses, in sRGB); Metal frames from an offscreen target, composited the way the window
/// server composites the layer: source-over in 8-bit sRGB.
///
/// Every pair is rendered at **1× and 2×** (the default; a trailing comma list of scales
/// overrides it) and the scale is part of the file name. 1× is the harder half: a 0.23 pt
/// wordmark grain, a 0.25 pt navigation ray and a 0.28 pt nebula grain each land inside a single
/// pixel there, where the box/disc coverage of the shader and CoreGraphics' antialiaser have the
/// least room to agree.
///
/// Files, per scale: `canvas-sky@2x.png` / `metal-sky@2x.png` (the Home idle sky in the default
/// window: 290 stars and the dust at intensity 1), `…-sky-rails…` (the 85 stars of the other
/// pages keeping off the vocabulary page's rail and top line), `canvas-core…` / `metal-core…`
/// (the 360 pt idle core, dark theme), `…-core-running…` / `…-core-paused…` (the same instant in
/// the running and paused moods) and `…-core-light…` / `…-core-paused-light…` (the light
/// theme); then the four sprite scenes against their canvases (`renderSprites`):
/// `wordmark[-light]` (98 × 36), `nav-<selection>-<flight|settled>[-light]` (the star field the
/// dock and Home's modes share, on `OrbitRow`'s 264 × 44, which is their real geometry) and
/// `nav-1-settled-modes` (the same field at Home's `modeStrength`), `nebula-192x48[-light]` (the capsule's
/// orbit alone), and the action button's light `light-<state>` in the layer that state's button
/// really has: 192 × 48 for the 184 pt capsule every primary state shares (the capsule plus the
/// halo's 4 pt on each side), 80 × 48 for the stop button, which has no glow and no padding.
/// `wordmark-sparse` is the ablation of the wordmark's recorded deviation
/// (`SparseWordmarkScene`), not a surface the product draws.
@MainActor
enum AmbientParityRenderer {
    /// The pinned instant every frame is rendered at.
    static let time = 2.3
    /// The backing scales every pair is rendered at, unless the flag names others.
    static let defaultScales: [CGFloat] = [1, 2]
    static let activity = 0.12

    static func render(to directory: URL, scales: [CGFloat] = defaultScales) throws {
        for scale in scales { try render(to: directory, scale: scale) }
    }

    static func render(to directory: URL, scale: CGFloat) throws {
        guard let renderer = ParticleMetalRenderer.shared else { throw failure("no Metal device") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = "@\(Int(scale))x"

        // Sky.
        let skySize = LLMetrics.defaultWindow
        let canvasSky = try canvas(ZStack {
            Color.black
            StellarAtmosphere(immersive: true, active: true)
            LuminousParticleFlow(active: true, intensity: 1)
        }, size: skySize, scale: scale)
        try write(canvasSky, to: directory.appendingPathComponent("canvas-sky\(suffix).png"))
        let sky = AmbientSkyFrame()
        guard let skyBuffer = renderer.makeVertexBuffers(capacity: sky.capacity, label: "parity sky").first else { throw failure("sky buffer") }
        let skyFrame = sky.encode(into: skyBuffer, stars: .init(immersive: true, active: true), starTime: time,
                                  dust: .init(active: true, intensity: 1, sampleStride: 1), dustTime: time, input: nil, inputTime: 0,
                                  width: skySize.width, height: skySize.height, scale: Float(scale))
        guard let metalSky = renderer.renderImage(skyFrame, width: pixels(skySize.width, scale), height: pixels(skySize.height, scale)) else { throw failure("sky render") }
        try write(composite(metalSky, over: nil, size: skySize, scale: scale), to: directory.appendingPathComponent("metal-sky\(suffix).png"))

        // The sky off Home, keeping off the vocabulary page's rail and top line.
        let keepOut = RootView.skyKeepOut(on: .vocabulary, historyWidth: 0, window: skySize)
        let canvasRails = try canvas(ZStack {
            Color.black
            StellarAtmosphere(immersive: false, active: true, keepOut: keepOut)
        }, size: skySize, scale: scale)
        try write(canvasRails, to: directory.appendingPathComponent("canvas-sky-rails\(suffix).png"))
        let railsFrame = sky.encode(into: skyBuffer, stars: .init(immersive: false, active: true, keepOut: keepOut), starTime: time,
                                    dust: nil, dustTime: time, input: nil, inputTime: 0,
                                    width: skySize.width, height: skySize.height, scale: Float(scale))
        guard let metalRails = renderer.renderImage(railsFrame, width: pixels(skySize.width, scale), height: pixels(skySize.height, scale)) else { throw failure("rails render") }
        try write(composite(metalRails, over: nil, size: skySize, scale: scale), to: directory.appendingPathComponent("metal-sky-rails\(suffix).png"))

        // Core, in its static form (the phase `SessionOrbHero` uses for a frozen frame): dark in
        // the three moods, and light.
        let side: CGFloat = 360
        let phase = time * (1 + activity * 3.2)
        let core = StardustCoreFrame()
        guard let coreBuffer = renderer.makeVertexBuffers(capacity: core.capacity, label: "parity core").first else { throw failure("core buffer") }
        let cores: [(String, LLTheme, StardustMood)] = [("core", .stellar, .idle), ("core-running", .stellar, .running),
                                                        ("core-paused", .stellar, .paused), ("core-light", .wilds, .idle),
                                                        ("core-paused-light", .wilds, .paused)]
        for (name, theme, mood) in cores {
            let canvasCore = try canvas(ZStack {
                theme.ground
                StardustOrganism(time: phase, activity: activity, mood: mood).environment(\.theme, theme)
            }, size: CGSize(width: side, height: side), scale: scale)
            try write(canvasCore, to: directory.appendingPathComponent("canvas-\(name)\(suffix).png"))
            let gradient = try canvas(ZStack {
                theme.ground
                StardustGlowGradient(pulse: 0).environment(\.theme, theme)
            }, size: CGSize(width: side, height: side), scale: scale)
            let coreFrame = core.encode(into: coreBuffer, renderer: renderer, phase: phase, activity: activity, mood: mood, pointer: nil, influence: 0,
                                        pulse: 0, palette: StardustPalette(theme: theme), side: side, scale: Float(scale),
                                        width: pixels(side, scale), height: pixels(side, scale))
            guard let metalCore = renderer.renderImage(coreFrame, width: pixels(side, scale), height: pixels(side, scale)) else { throw failure("core render") }
            try write(composite(metalCore, over: gradient, size: CGSize(width: side, height: side), scale: scale),
                      to: directory.appendingPathComponent("metal-\(name)\(suffix).png"))
        }
        try renderSprites(renderer: renderer, to: directory, scale: scale, suffix: suffix)
        print("ambient parity frames written to \(directory.path) (t = \(time), scale \(scale))")
    }

    /// The four small surfaces: each Canvas over the theme ground next to its sprite scene
    /// composited over the same ground, at the size the surface has in the window.
    private static func renderSprites(renderer: ParticleMetalRenderer, to directory: URL, scale: CGFloat, suffix: String) throws {
        let capacity = [WordmarkScene.capacity, NavigationStarScene.capacity, NebulaHaloScene.capacity, ControlLightScene.capacity].max()!
        guard let buffer = renderer.makeVertexBuffers(capacity: capacity, label: "parity sprites").first else { throw failure("sprite buffer") }
        /// `workspace` must already hold whatever the scene samples for `time`
        /// (`advance(to:workspace:)`); nothing here advances it, so a stateful motion is stepped
        /// exactly once per captured frame by its caller.
        func pair<S: SpriteScene, V: View>(_ name: String, scene: S, workspace: S.Workspace, canvas view: V,
                                           size: CGSize, time: Double, theme: LLTheme) throws {
            let reference = try canvas(ZStack { theme.ground; view }.environment(\.theme, theme), size: size, scale: scale)
            try write(reference, to: directory.appendingPathComponent("canvas-\(name)\(suffix).png"))
            let ground = try canvas(theme.ground, size: size, scale: scale)
            let frame = scene.frame(into: buffer, time: time, width: size.width, height: size.height,
                                    scale: Float(scale), workspace: workspace)
            guard let image = renderer.renderImage(frame, width: pixels(size.width, scale), height: pixels(size.height, scale)) else { throw failure("\(name) render") }
            try write(composite(image, over: ground, size: size, scale: scale), to: directory.appendingPathComponent("metal-\(name)\(suffix).png"))
        }
        func tint(_ hex: UInt32, _ theme: LLTheme) -> SIMD4<Float> {
            theme.isDark ? AmbientRendering.components(hex: hex) : AmbientRendering.components(theme.accent)
        }

        // Wordmark, 98 × 36, the header's frozen frame at `time`.
        for theme in [LLTheme.stellar, .wilds] {
            let scene = WordmarkScene(tint: AmbientRendering.components(ParticleWordmark.tint(theme)), engraved: !theme.isDark)
            try pair("wordmark\(theme.isDark ? "" : "-light")", scene: scene, workspace: WordmarkScene.makeWorkspace(),
                     canvas: ParticleWordmark(frozenTime: time), size: CGSize(width: 98, height: 36), time: time, theme: theme)
        }
        // The control for the wordmark's one recorded deviation (W1): the same grains, the same
        // bins, the same rects — at one eighth of the density, where two grains of a bin almost
        // never land in the same pixel. What is left in this pair is the box sprite against
        // CoreGraphics' rect antialiasing alone; whatever the full-density pair shows on top of
        // it is the same-bin union. See `SparseWordmarkScene`.
        try pair("wordmark-sparse", scene: SparseWordmarkScene(tint: tint(0xE3F0F6, .stellar)),
                 workspace: SparseWordmarkScene.makeWorkspace(), canvas: SparseWordmarkCanvas(time: time),
                 size: CGSize(width: 98, height: 36), time: time, theme: .stellar)

        // Navigation stars in the orbit row's background. One motion drives both paths: the
        // scene's encoder is pure, so the very points the Canvas is handed are the points it
        // encodes. Settled and mid-flight moments of every selection, at 30 Hz.
        let navSize = OrbitRow.size
        let motion = NavigationStarMotion()
        let navWorkspace = NavigationStarScene.makeWorkspace()
        var frame = 0
        /// `modes` also captures the settled field at Home's quieter `modeStrength`.
        func nav(_ selection: Int, frames: Int, capture name: String, themes: [LLTheme] = [.stellar], modes: Bool = false) throws {
            var t = 0.0
            for _ in 0..<frames {
                t = Double(frame) / 30
                navWorkspace.points = motion.sample(time: t, selection: selection)
                frame += 1
            }
            for theme in themes {
                try pair("nav-\(selection)-\(name)\(theme.isDark ? "" : "-light")",
                         scene: NavigationStarScene(motion: motion, selection: selection, tint: tint(0xD8E9F2, theme), halos: theme.isDark),
                         workspace: navWorkspace, canvas: NavigationStarCanvas(points: navWorkspace.points, time: t),
                         size: navSize, time: t, theme: theme)
            }
            if modes {
                let strength = NavigationStarField.modeStrength
                try pair("nav-\(selection)-\(name)-modes",
                         scene: NavigationStarScene(motion: motion, selection: selection, tint: tint(0xD8E9F2, .stellar), strength: strength),
                         workspace: navWorkspace, canvas: NavigationStarCanvas(points: navWorkspace.points, time: t, strength: strength),
                         size: navSize, time: t, theme: .stellar)
            }
        }
        try nav(1, frames: 90, capture: "settled", themes: [.stellar, .wilds], modes: true)
        try nav(2, frames: 12, capture: "flight")
        try nav(2, frames: 78, capture: "settled")
        try nav(0, frames: 12, capture: "flight")
        try nav(0, frames: 78, capture: "settled")
        try nav(1, frames: 12, capture: "flight")

        // The capsule's orbit alone, in the capsule's halo layer (184 pt + 4 pt each side).
        for theme in [LLTheme.stellar, .wilds] {
            let size = CGSize(width: LuminousActionButton.capsuleWidth + 8, height: 48)
            try pair("nebula-\(Int(size.width))x\(Int(size.height))\(theme.isDark ? "" : "-light")",
                     scene: NebulaHaloScene(strength: 0.85, tint: tint(0xD9EDF3, theme), halos: theme.isDark),
                     workspace: NebulaHaloScene.makeWorkspace(),
                     canvas: NebulaHalo(time: time, strength: 0.85), size: size, time: time, theme: theme)
        }

        // Every action-button light the product mounts on Metal, in the layer it really has: the
        // capsule plus the halo's 4 pt on each side (`LuminousActionButton`'s `padding(-4)`), or
        // the bare capsule for the stop button, which has no glow and no padding. The 184 pt
        // capsule at breath phases 0 / 0.5 / 1 (t = 0, 1.15, 2.3 s of the 4.6 s breath), plain
        // and hovered, disabled and busy holding the breath at 0.25, on paper (no glow, no
        // soft halos); then the session rail's pause and its 80 pt stop. The Canvas is composed
        // exactly as `LuminousActionButton` composes it.
        struct LightState {
            var name: String
            var appearance: SessionActionAppearance
            var enabled: Bool
            var highlighted: Bool
            var time: Double
            var theme: LLTheme
            /// The button's own width: the capsule's, or the stop button's.
            var capsule: CGFloat = LuminousActionButton.capsuleWidth
        }
        var states: [LightState] = []
        for (label, t) in [("p0", 0.0), ("p50", 1.15), ("p100", 2.3)] {
            states.append(LightState(name: "light-start-\(label)", appearance: .start, enabled: true, highlighted: false, time: t, theme: .stellar))
            states.append(LightState(name: "light-start-hover-\(label)", appearance: .start, enabled: true, highlighted: true, time: t, theme: .stellar))
        }
        states.append(LightState(name: "light-start-disabled", appearance: .start, enabled: false, highlighted: false, time: 2.3, theme: .stellar))
        states.append(LightState(name: "light-connecting-busy", appearance: .connecting, enabled: true, highlighted: false, time: 2.3, theme: .stellar))
        states.append(LightState(name: "light-start-p50-light", appearance: .start, enabled: true, highlighted: false, time: 1.15, theme: .wilds))
        // The session rail (`ActiveHomeSessionView`): the running session's pause button (the
        // same capsule) and the 80 pt stop button, whose scene has no glow, no inset and no clip.
        states.append(LightState(name: "light-pause-p50", appearance: .pause, enabled: true, highlighted: false, time: 1.15, theme: .stellar))
        states.append(LightState(name: "light-stop", appearance: .stop, enabled: true, highlighted: false, time: 2.3, theme: .stellar,
                                 capsule: LuminousActionButton.stopWidth))
        states.append(LightState(name: "light-stop-hover", appearance: .stop, enabled: true, highlighted: true, time: 2.3, theme: .stellar,
                                 capsule: LuminousActionButton.stopWidth))
        for state in states {
            let busy = state.appearance.isBusy
            let theme = state.theme
            let stop = state.appearance == .stop
            let glows = !stop && theme.isDark
            let inset: CGFloat = stop ? 0 : 4
            let size = CGSize(width: state.capsule + inset * 2, height: 48)
            let breathes = !stop && state.enabled && !busy
            let strength = !state.enabled ? 0.20 : (stop ? (state.highlighted ? 0.60 : 0.18) : (state.highlighted ? 1.0 : 0.85))
            let scene = ControlLightScene(glows: glows, inset: Double(inset), breathes: breathes, emphasized: state.highlighted,
                                          dimmed: !state.enabled || busy, haloStrength: strength, haloSpeed: busy ? 1.9 : 1,
                                          glowTint: tint(0xE3F0F6, theme), haloTint: tint(0xD9EDF3, theme), halos: theme.isDark)
            let breath = breathes ? (1 - cos(state.time * .pi * 2 / 4.6)) / 2 : 0.25
            let light = ZStack {
                if glows {
                    ControlBreathingLight(phase: breath, color: Color(hex: 0xE3F0F6),
                                          emphasized: state.highlighted, dimmed: !state.enabled || busy)
                        .clipShape(Capsule())
                        .frame(width: state.capsule, height: size.height)
                }
                NebulaHalo(time: state.time * (busy ? 1.9 : 1), strength: strength)
                    .frame(width: size.width, height: size.height)
            }
            try pair(state.name, scene: scene, workspace: ControlLightScene.makeWorkspace(), canvas: light,
                     size: size, time: state.time, theme: theme)
        }
    }

    private static func pixels(_ points: CGFloat, _ scale: CGFloat) -> Int { Int((points * scale).rounded()) }

    /// A view rendered as its static frame at `time`, at `scale`.
    private static func canvas<V: View>(_ view: V, size: CGSize, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.staticRender, true).environment(\.staticMotionTime, time))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard let image = renderer.cgImage else { throw failure("ImageRenderer produced no image") }
        return image
    }

    /// `image` (premultiplied sRGB) source-over `background` (or black) in an 8-bit sRGB context.
    private static func composite(_ image: CGImage, over background: CGImage?, size: CGSize, scale: CGFloat) throws -> CGImage {
        let width = pixels(size.width, scale), height = pixels(size.height, scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw failure("no composite context")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .none
        if let background {
            context.draw(background, in: rect)
        } else {
            context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
            context.fill(rect)
        }
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw failure("composite failed") }
        return result
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw failure("png encode failed") }
        try png.write(to: url)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AmbientParityRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// One eighth of `ParticleWordmark`'s grains, otherwise `WordmarkScene` exactly: the same
/// positions, the same five alpha bins in the same order, the same rects, no halos (a halo is
/// every 157th grain and would not survive the decimation evenly).
///
/// It exists to separate the two things that can make a sprite differ from its Canvas: the box
/// sprite's coverage against CoreGraphics' antialiasing of the same rect, which this pair
/// isolates, and the same-bin union, which only the full-density pair has. Canvas puts every
/// grain of a bin into one path and fills it once, so their coverages combine by nonzero winding
/// — they *add* where two grains merely share a pixel and do *not* add where they overlap; one
/// source-over sprite per grain does neither, falling short in the first case and overshooting in
/// the second. Measured at t = 2.3: at this density the pair is one pixel of six levels and no
/// ink bias at either scale, so the box coverage is exact and the whole of the wordmark's
/// residual is the union. Diagnostic only — the product never draws it,
/// `--render-ambient-parity` does.
private struct SparseWordmarkScene: SpriteScene {
    static let stride = 8
    var tint: SIMD4<Float>
    var active = true
    var rate: Double { 15 }
    var palette: [SIMD4<Float>] { [tint] }
    var capacity: Int { (ParticleWordmark.grains.count + Self.stride - 1) / Self.stride }

    final class Workspace {}
    static func makeWorkspace() -> Workspace { Workspace() }

    func encode(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, time: Double,
                width: Double, height: Double, scale: Float, workspace: Workspace) -> Int {
        let grains = ParticleWordmark.grains
        let sX = sin(time * 0.65), cX = cos(time * 0.65)
        let sY = sin(time * 0.53), cY = cos(time * 0.53)
        let sL = sin(time * 0.75), cL = cos(time * 0.75)
        let s = Double(scale)
        var written = 0
        for bin in 0..<5 {
            for index in Swift.stride(from: 0, to: grains.count, by: Self.stride) {
                let grain = grains[index]
                let light = 0.68 + (sL * grain.cosPhase + cL * grain.sinPhase) * 0.22
                guard min(4, max(0, Int(light * 5))) == bin, written < capacity else { continue }
                let x = grain.point.x + (sX * grain.cosPhase + cX * grain.sinPhase) * 0.12
                let y = grain.point.y + (cY * grain.cosPhase - sY * grain.sinPhase) * 0.10
                let half = Float(grain.radius * s)
                out[written] = ParticlePoint(x: Float(x * s), y: Float(y * s), halfWidth: half, halfHeight: half,
                                             alpha: Float((Double(bin) + 0.5) / 5), kind: ParticlePoint.box, color: 0)
                written += 1
            }
        }
        return written
    }
}

/// The Canvas reference for `SparseWordmarkScene`: `ParticleWordmark`'s own fill, grain for
/// grain, over the same eighth of the grains.
private struct SparseWordmarkCanvas: View {
    let time: Double
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { context, _ in
            let color = theme.isDark ? Color(hex: 0xE3F0F6) : theme.accent
            let sX = sin(time * 0.65), cX = cos(time * 0.65)
            let sY = sin(time * 0.53), cY = cos(time * 0.53)
            let sL = sin(time * 0.75), cL = cos(time * 0.75)
            var bins = Array(repeating: Path(), count: 5)
            for index in Swift.stride(from: 0, to: ParticleWordmark.grains.count, by: SparseWordmarkScene.stride) {
                let grain = ParticleWordmark.grains[index]
                let x = grain.point.x + (sX * grain.cosPhase + cX * grain.sinPhase) * 0.12
                let y = grain.point.y + (cY * grain.cosPhase - sY * grain.sinPhase) * 0.10
                let light = 0.68 + (sL * grain.cosPhase + cL * grain.sinPhase) * 0.22
                bins[min(4, max(0, Int(light * 5)))].addRect(CGRect(x: x - grain.radius, y: y - grain.radius,
                    width: grain.radius * 2, height: grain.radius * 2))
            }
            for index in bins.indices where !bins[index].isEmpty {
                context.fill(bins[index], with: .color(color.opacity((Double(index) + 0.5) / 5)))
            }
        }.accessibilityHidden(true)
    }
}
