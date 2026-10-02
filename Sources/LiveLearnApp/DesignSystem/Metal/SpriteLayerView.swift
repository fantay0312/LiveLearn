import AppKit
import Metal
import SwiftUI
import ParticleMath

/// One small ambient surface drawn as point sprites: the sprites a frame needs at `time`, in the
/// order its Canvas would fill them, and the tints they index. Scenes are plain values — the
/// parameters of one Canvas view — so a changed scene is a changed frame, and the encoders run
/// without a GPU in the tests.
///
/// A scene owns no per-frame storage: everything an encoder needs to keep between its passes
/// lives in a `Workspace` the host allocates once, so a 30 Hz layer allocates nothing per frame
/// (the pattern of `StardustGeometry.Workspace`). Anything the scene *samples* rather than
/// computes — the navigation field's motion — is taken in `advance(to:workspace:)`, called once
/// per rendered frame, which keeps `encode` a pure function of its inputs.
protocol SpriteScene: Equatable {
    /// Scratch the encoder reuses frame after frame; one per mounted layer.
    associatedtype Workspace: AnyObject
    static func makeWorkspace() -> Workspace
    /// The most points one frame can need; the vertex ring is sized to it.
    var capacity: Int { get }
    /// Tints indexed by `ParticlePoint.color`, sRGB 0–1 (at most eight).
    var palette: [SIMD4<Float>] { get }
    /// Whether the scene's clock runs (`LuminousMotion`'s per-surface `active`).
    var active: Bool { get }
    /// The frame rate while the app is active (`LuminousMotion.rate`).
    var rate: Double { get }
    /// Samples whatever the scene reads from a stateful source into the workspace, once per
    /// rendered frame, before `encode`. Default: nothing to sample.
    func advance(to time: Double, workspace: Workspace)
    /// Writes the frame's sprites for a `width × height` point layer at backing `scale`.
    /// Returns the number written; 0 when `capacity` is too small.
    func encode(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, time: Double,
                width: Double, height: Double, scale: Float, workspace: Workspace) -> Int
    /// The capsule the frame's glow sprites are clipped to, in pixels, or nil.
    func clip(width: Double, height: Double, scale: Float) -> ParticleFrame.Clip?
}

extension SpriteScene {
    var rate: Double { 30 }
    func advance(to time: Double, workspace: Workspace) {}
    func clip(width: Double, height: Double, scale: Float) -> ParticleFrame.Clip? { nil }

    /// The frame at `time`, encoded into `buffer` (which holds at least `capacity` points).
    /// `advance(to:workspace:)` must already have run for this instant.
    func frame(into buffer: MTLBuffer, time: Double, width: Double, height: Double, scale: Float,
               workspace: Workspace) -> ParticleFrame {
        let room = buffer.length / MemoryLayout<ParticlePoint>.stride
        let out = buffer.contents().bindMemory(to: ParticlePoint.self, capacity: room)
        let count = encode(into: out, capacity: room, time: time, width: width, height: height, scale: scale, workspace: workspace)
        return ParticleFrame(vertices: buffer, points: 0..<count, palette: palette, glow: nil,
                             clip: clip(width: width, height: height, scale: scale))
    }

    /// One frame with a workspace of its own, for the tests and one-off renders that do not keep
    /// a layer around. A live layer reuses the host's workspace instead.
    func encode(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, time: Double,
                width: Double, height: Double, scale: Float) -> Int {
        let workspace = Self.makeWorkspace()
        advance(to: time, workspace: workspace)
        return encode(into: out, capacity: capacity, time: time, width: width, height: height, scale: scale, workspace: workspace)
    }
}

/// A `SpriteScene` in a Metal layer with the clock and the gates of `LuminousMotion`
/// (`ParticleMetalHostView`). The SwiftUI view around it keeps its Canvas for a static render,
/// a frozen time, Reduce Motion and a machine without a GPU; this view is only mounted live.
struct SpriteLayerView<Scene: SpriteScene>: NSViewRepresentable {
    let renderer: ParticleMetalRenderer
    var scene: Scene

    func makeNSView(context: Context) -> SpriteHostView<Scene> {
        let view = SpriteHostView(renderer: renderer, scene: scene)
        apply(to: view, context)
        return view
    }

    func updateNSView(_ view: SpriteHostView<Scene>, context: Context) {
        apply(to: view, context)
    }

    static func dismantleNSView(_ view: SpriteHostView<Scene>, coordinator: ()) {
        view.detach()
    }

    private func apply(to view: SpriteHostView<Scene>, _ context: Context) {
        view.ambientPaused = context.environment.ambientMotionPaused
        view.reduceMotion = context.environment.accessibilityReduceMotion
        view.set(scene)
    }
}

@MainActor
final class SpriteHostView<Scene: SpriteScene>: ParticleMetalHostView {
    private(set) var scene: Scene
    private var clock = AmbientClock()
    /// Allocated once with the view: the encoders write into it instead of into fresh arrays.
    private let workspace = Scene.makeWorkspace()
    private var buffers: [MTLBuffer] = []
    private var bufferCapacity = 0
    private var bufferIndex = 0

    init(renderer: ParticleMetalRenderer, scene: Scene) {
        self.scene = scene
        super.init(renderer: renderer)
        foregroundRate = scene.rate
        reserve(scene.capacity)
    }

    /// A new scene is a parameter change of the Canvas it stands for: the gate is re-evaluated
    /// and a frame drawn — at the next tick when playing, once now at the frozen time when not.
    func set(_ scene: Scene) {
        guard scene != self.scene else { return }
        self.scene = scene
        foregroundRate = scene.rate
        reserve(scene.capacity)
        refreshPlaying()
        requestFrame()
    }

    private func reserve(_ capacity: Int) {
        guard capacity > bufferCapacity else { return }
        buffers = renderer.makeVertexBuffers(capacity: capacity, label: "sprites \(Scene.self)")
        bufferCapacity = capacity
        bufferIndex = 0
    }

    override func applyGate(_ open: Bool) -> Bool {
        clock.set(playing: open && scene.active)
        return clock.playing
    }

    override func render(at now: Date) {
        guard !buffers.isEmpty else { return }
        // See `AmbientSkyHostView.render`: the ring advances only for a frame the GPU took, so
        // the buffer being written is never one still being read.
        let buffer = buffers[bufferIndex]
        let time = clock.time(at: now)
        // Sampled once per frame, here rather than inside the encoder: a scene that reads a
        // stateful source must advance it exactly as often as a frame is drawn.
        scene.advance(to: time, workspace: workspace)
        // Stateful scenes can finish a flight without a SwiftUI parameter update.
        if foregroundRate != scene.rate { foregroundRate = scene.rate }
        let frame = scene.frame(into: buffer, time: time, width: Double(bounds.width),
                                height: Double(bounds.height), scale: Float(metalLayer.contentsScale),
                                workspace: workspace)
        if renderer.draw(frame, into: metalLayer, inFlight: inFlight) {
            bufferIndex = (bufferIndex + 1) % buffers.count
        }
    }
}
