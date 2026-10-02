import Foundation
import Metal
import QuartzCore
import simd
import ParticleMath

/// One frame of a particle layer: which sprites to draw, with what tints, over what glow.
struct ParticleFrame {
    var vertices: MTLBuffer
    /// The sprites drawn onto the layer, in this order (the buffer is already sorted the way
    /// the canvas would fill its paths).
    var points: Range<Int>
    /// Tints indexed by `ParticlePoint.color`, sRGB components 0–1 (no linearisation: the
    /// canvases blend in gamma space, so does this).
    var palette: [SIMD4<Float>]
    /// The blurred light under the grains (`StardustOrganism`'s lit dust), if the layer has one.
    var glow: Glow?
    /// The capsule the frame's glow sprites (`ParticlePoint.glow`) are clipped to, in pixels;
    /// nil leaves them unclipped. The other kinds are never clipped (the halo around the action
    /// button extends past its capsule, as its canvas does).
    var clip: Clip? = nil

    struct Clip: Equatable {
        var center: SIMD2<Float>
        var halfExtent: SIMD2<Float>
    }

    struct Glow {
        /// Boxes accumulated into the mask.
        var lit: Range<Int>
        /// Gaussian sigma in pixels.
        var sigma: Float
        /// Tint (rgb) and peak alpha (a) of the light.
        var tint: SIMD4<Float>
        var textures: GlowTextures
    }
}

/// The mask and two blur targets of a glow pass, sized to the layer's drawable.
final class GlowTextures {
    let width: Int
    let height: Int
    let mask: MTLTexture
    let scratch: MTLTexture
    let blurred: MTLTexture

    init?(device: MTLDevice, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let mask = device.makeTexture(descriptor: descriptor), let scratch = device.makeTexture(descriptor: descriptor),
              let blurred = device.makeTexture(descriptor: descriptor) else { return nil }
        mask.label = "particle glow mask"; scratch.label = "particle glow scratch"; blurred.label = "particle glow"
        self.width = width; self.height = height
        self.mask = mask; self.scratch = scratch; self.blurred = blurred
    }
}

/// The process's Metal state for the particle layers: one device and queue, the compiled
/// pipelines, and `draw`, which turns a `ParticleFrame` into one command buffer per frame.
/// `shared` is nil when there is no GPU (a VM, a denied device) or the shaders fail to compile;
/// the views then keep their Canvas path.
@MainActor
final class ParticleMetalRenderer {
    static let shared: ParticleMetalRenderer? = ParticleMetalRenderer()

    /// Frames a layer may have in flight before it skips one instead of blocking the main
    /// thread. The vertex ring has one buffer more than this, so a buffer being written is never
    /// one the GPU still reads.
    static let framesInFlight = 2
    static let vertexBuffers = framesInFlight + 1

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pointPipeline: MTLRenderPipelineState
    private let maskPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let glowPipeline: MTLRenderPipelineState
    private var blurWeights: (sigma: Float, radius: Int, weights: [Float]) = (0, 0, [])

    /// Layout of the shader's `PointUniforms`: the viewport in pixels (padded to 16 bytes),
    /// eight palette entries (offset 16) and the glow clip capsule (offset 144; 160 bytes in all).
    private struct PointUniforms {
        var viewport: SIMD2<Float>
        var padding = SIMD2<Float>(0, 0)
        var palette: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var clip: SIMD4<Float>

        init(viewport: SIMD2<Float>, palette source: [SIMD4<Float>], clip: ParticleFrame.Clip?) {
            self.viewport = viewport
            func at(_ i: Int) -> SIMD4<Float> { i < source.count ? source[i] : SIMD4<Float>(1, 1, 1, 1) }
            palette = (at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7))
            self.clip = clip.map { SIMD4($0.center.x, $0.center.y, $0.halfExtent.x, $0.halfExtent.y) } ?? SIMD4(0, 0, 0, 0)
        }
    }

    private init?() {
        // The encoders write `ParticlePoint` straight into the vertex buffers, so its layout must
        // be the shader's `PointVertex` (24 bytes, the two 16-bit fields at 20 and 22). Swift does
        // not promise C layout; if a toolchain ever changes it, the views keep their Canvas path.
        func decline(_ why: String) -> Bool {
            // The views fall back to Canvas; the reason is logged once so a toolchain or SDK
            // change that quietly reverted the GPU path would still leave a trace.
            FileHandle.standardError.write(Data("ambient metal renderer unavailable: \(why); using Canvas\n".utf8))
            return true
        }
        guard MemoryLayout<ParticlePoint>.stride == 24, MemoryLayout<ParticlePoint>.offset(of: \.alpha) == 16,
              MemoryLayout<ParticlePoint>.offset(of: \.kind) == 20, MemoryLayout<ParticlePoint>.offset(of: \.color) == 22 else {
            _ = decline("ParticlePoint layout is not the shader's PointVertex layout"); return nil
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            _ = decline("no Metal device"); return nil
        }
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: ParticleMetalShaders.source, options: options) }
        catch { _ = decline("shader compilation failed: \(error)"); return nil }
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blend: Bool, additive: Bool = false) -> MTLRenderPipelineState? {
            guard let vertexFunction = library.makeFunction(name: vertex), let fragmentFunction = library.makeFunction(name: fragment) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "\(vertex) / \(fragment)"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            attachment.isBlendingEnabled = blend
            if blend {
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                // Straight-alpha source over a premultiplied destination: the target is cleared to
                // transparent each frame and holds premultiplied colour for the compositor.
                attachment.sourceRGBBlendFactor = additive ? .one : .sourceAlpha
                attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let point = pipeline("particle_vertex", "particle_fragment", format: .bgra8Unorm, blend: true),
              let mask = pipeline("particle_vertex", "mask_fragment", format: .r8Unorm, blend: true, additive: true),
              let blur = pipeline("screen_vertex", "blur_fragment", format: .r8Unorm, blend: false),
              let glow = pipeline("screen_vertex", "glow_fragment", format: .bgra8Unorm, blend: true) else {
            _ = decline("pipeline state creation failed"); return nil
        }
        self.device = device
        self.queue = queue
        queue.label = "LiveLearn particles"
        pointPipeline = point
        maskPipeline = mask
        blurPipeline = blur
        glowPipeline = glow
    }

    /// A ring of shared-memory vertex buffers for `capacity` points.
    func makeVertexBuffers(capacity: Int, label: String) -> [MTLBuffer] {
        (0..<Self.vertexBuffers).compactMap { i in
            let buffer = device.makeBuffer(length: max(1, capacity) * MemoryLayout<ParticlePoint>.stride, options: .storageModeShared)
            buffer?.label = "\(label) \(i)"
            return buffer
        }
    }

    func makeGlowTextures(width: Int, height: Int) -> GlowTextures? {
        GlowTextures(device: device, width: width, height: height)
    }

    /// Encodes and presents one frame. Returns false when the frame was skipped: no drawable was
    /// available without waiting, or `framesInFlight` frames were still on the GPU.
    @discardableResult
    func draw(_ frame: ParticleFrame, into layer: CAMetalLayer, inFlight: DispatchSemaphore) -> Bool {
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        guard let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return false
        }
        commands.label = "particle frame"
        guard encode(frame, into: drawable.texture, commands: commands) else {
            inFlight.signal()
            return false
        }
        commands.addCompletedHandler { _ in inFlight.signal() }
        commands.present(drawable)
        commands.commit()
        return true
    }

    /// Renders one frame into a `width × height` image without a window: the same passes as
    /// `draw`, read back as a premultiplied sRGB image (`--render-ambient-parity`).
    func renderImage(_ frame: ParticleFrame, width: Int, height: Int) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer(),
              encode(frame, into: target, commands: commands) else { return nil }
        commands.commit()
        commands.waitUntilCompleted()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Encodes the frame's passes into `target` (cleared to transparent). False when an encoder
    /// could not be made; nothing is committed here.
    private func encode(_ frame: ParticleFrame, into target: MTLTexture, commands: MTLCommandBuffer) -> Bool {
        var uniforms = PointUniforms(viewport: SIMD2(Float(target.width), Float(target.height)), palette: frame.palette, clip: frame.clip)
        let uniformsLength = MemoryLayout<PointUniforms>.stride
        var glowReady = false
        if let glow = frame.glow, !glow.lit.isEmpty {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = glow.textures.mask
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
                encoder.label = "glow mask"
                encoder.setRenderPipelineState(maskPipeline)
                encoder.setVertexBuffer(frame.vertices, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 1)
                encoder.drawPrimitives(type: .point, vertexStart: glow.lit.lowerBound, vertexCount: glow.lit.count)
                encoder.endEncoding()
                let (radius, weights) = gaussian(sigma: glow.sigma)
                blur(commands, from: glow.textures.mask, to: glow.textures.scratch, step: SIMD2(1, 0), radius: radius, weights: weights)
                blur(commands, from: glow.textures.scratch, to: glow.textures.blurred, step: SIMD2(0, 1), radius: radius, weights: weights)
                glowReady = true
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.label = "particles"
        if glowReady, let glow = frame.glow {
            var tint = glow.tint
            encoder.setRenderPipelineState(glowPipeline)
            encoder.setFragmentTexture(glow.textures.blurred, index: 0)
            encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if !frame.points.isEmpty {
            encoder.setRenderPipelineState(pointPipeline)
            encoder.setVertexBuffer(frame.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: frame.points.lowerBound, vertexCount: frame.points.count)
        }
        encoder.endEncoding()
        return true
    }

    private func blur(_ commands: MTLCommandBuffer, from source: MTLTexture, to target: MTLTexture, step: SIMD2<Float>, radius: Int, weights: [Float]) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "glow blur"
        var step = step
        var radius = Int32(radius)
        encoder.setRenderPipelineState(blurPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&step, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&radius, length: MemoryLayout<Int32>.stride, index: 1)
        weights.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Half of a normalised Gaussian kernel (index 0 is the centre), three sigmas wide.
    private func gaussian(sigma: Float) -> (Int, [Float]) {
        if blurWeights.sigma == sigma, !blurWeights.weights.isEmpty { return (blurWeights.radius, blurWeights.weights) }
        let s = max(0.01, sigma)
        let radius = min(32, max(1, Int((3 * s).rounded(.up))))
        var weights = (0...radius).map { i in expf(-Float(i * i) / (2 * s * s)) }
        let total = weights[0] + 2 * weights.dropFirst().reduce(0, +)
        weights = weights.map { $0 / total }
        blurWeights = (sigma, radius, weights)
        return (radius, weights)
    }
}
