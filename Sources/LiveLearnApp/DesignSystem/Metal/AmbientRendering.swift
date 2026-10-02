import AppKit
import SwiftUI

/// Which path a Home particle layer draws with.
enum AmbientRenderer: Sendable {
    /// The SwiftUI `Canvas` code: the reference look, and the only path for static renders,
    /// frozen frames and Reduce Motion.
    case canvas
    /// GPU point sprites in a `CAMetalLayer`, driven by a display link instead of a
    /// `TimelineView`, so SwiftUI performs no render pass for the layer at all.
    case metal
}

/// One ambient surface that can draw with Metal. Only `--ambient-layers` distinguishes them:
/// the product mounts every one of them on the GPU.
enum AmbientLayer: String, CaseIterable, Sendable {
    /// `AmbientSky` — the stars and the dust in one full-window layer.
    case sky
    /// `SessionOrbHero`'s stardust core.
    case core
    case wordmark
    /// The dock's navigation stars.
    case nav
    /// Home's mode orbit: the same navigation dust around the selected mode.
    case nebula
    /// `LuminousActionButton`'s breathing light and halo.
    case button
}

/// Process-wide switches for the ambient layers, read once from the command line (the
/// development flags are documented next to `--open-settings` in `LiveLearnApp.swift`).
enum AmbientRendering {
    /// Opt-in lifecycle and five-second frame counters; never records input or audio.
    static let trace = CommandLine.arguments.contains("--trace-ambient")

    /// `--ambient-layers <a,b,…>`: a **development** flag that mounts only the named Metal
    /// layers; every other surface falls back to its Canvas branch. Absent (the product) every
    /// layer is on. It exists so the cost of one layer can be measured against another's, and
    /// nothing in the product reads it.
    static let enabledLayers: Set<AmbientLayer> = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ambient-layers"), i + 1 < args.count else { return Set(AmbientLayer.allCases) }
        if args[i + 1] == "none" { return [] }
        return Set(args[i + 1].split(separator: ",").compactMap { AmbientLayer(rawValue: String($0).trimmingCharacters(in: .whitespaces)) })
    }()

    /// `--ambient-probe ticks-only|no-links`: **development** flags that take one cost away at a
    /// time so a measurement can tell them apart. `ticks-only`: every Metal host's display link
    /// keeps ticking but no frame is built or presented. `no-links`: no host ever starts its
    /// link at all — each layer draws the one frame a stopped surface draws and then holds it.
    /// Nothing in the product reads either.
    static let probe: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ambient-probe"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// The links tick; nothing is built or presented.
    static let ticksOnly = probe == "ticks-only"
    /// No link ever runs; every layer holds its first frame.
    static let noLinks = probe == "no-links"

    /// `--ambient-renderer canvas|metal`: the path the opted-in Home layers use. Metal unless the
    /// flag says otherwise; a caller that does not opt in stays on Canvas either way.
    static let preferred: AmbientRenderer = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--ambient-renderer"), i + 1 < args.count, args[i + 1] == "canvas" { return .canvas }
        return .metal
    }()

    /// `--ambient-time <seconds>`: pins every ambient clock — each `LuminousMotion` and each
    /// Metal display link — to one instant that never advances, so a Canvas frame and a Metal
    /// frame of the same moment can be captured and compared.
    static let pinnedTime: Double? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ambient-time"), i + 1 < args.count,
              let time = Double(args[i + 1]), time.isFinite else { return nil }
        return max(0, time)
    }()

    /// The renderer a view that asked for `requested` draws with, or nil for Canvas. Metal only
    /// for a live surface — no static render, no frozen time, no Reduce Motion — on a usable GPU,
    /// and only while `--ambient-layers` (a development flag, all layers by default) keeps that
    /// layer on the GPU.
    @MainActor
    static func metalRenderer(for requested: AmbientRenderer, layer: AmbientLayer, staticRender: Bool, frozenTime: Double?, reduceMotion: Bool) -> ParticleMetalRenderer? {
        guard requested == .metal, preferred == .metal, enabledLayers.contains(layer),
              !staticRender, frozenTime == nil, !reduceMotion else { return nil }
        return ParticleMetalRenderer.shared
    }

    /// The form for a caller that does not name its layer. `SessionOrbHero` (the stardust core)
    /// is the only one; every surface this task owns names itself, so `--ambient-layers` can
    /// mount them one at a time.
    @MainActor
    static func metalRenderer(for requested: AmbientRenderer, staticRender: Bool, frozenTime: Double?, reduceMotion: Bool) -> ParticleMetalRenderer? {
        metalRenderer(for: requested, layer: .core, staticRender: staticRender, frozenTime: frozenTime, reduceMotion: reduceMotion)
    }

    /// sRGB components of a design-system colour, for the shader palette.
    static func components(_ color: Color) -> SIMD4<Float> {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return SIMD4(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent), Float(ns.alphaComponent))
    }

    static func components(hex: UInt32) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, 1)
    }
}
