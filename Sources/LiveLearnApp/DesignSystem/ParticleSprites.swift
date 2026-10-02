import AppKit
import SwiftUI

/// Pre-rendered soft dots: a linear radial falloff from the tint to clear, the exact shading
/// the canvases used to fill per halo with `.radialGradient`. Drawing one small image is a blit;
/// a gradient fill is a shading pass with its own setup, and the dust field wants fifty of them
/// a frame. Built once per tint and kept for the life of the process.
enum ParticleSprites {
    /// 64 px across: enough for the 10–12 pt halos at 2× without visible banding.
    private static let pixels = 64
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [UInt32: Image] = [:]

    /// The halo sprite for an `RRGGBB` tint. Draw it centred on the halo with `context.opacity`
    /// set to the halo's peak alpha.
    static func halo(_ hex: UInt32) -> Image {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[hex] { return cached }
        let image = Image(decorative: make(hex), scale: 2)
        cache[hex] = image
        return image
    }

    private static func make(_ hex: UInt32) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
        let colors = [CGColor(colorSpace: space, components: [r, g, b, 1])!,
                      CGColor(colorSpace: space, components: [r, g, b, 0])!] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        let centre = CGPoint(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2)
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                   endRadius: CGFloat(pixels) / 2, options: [])
        return context.makeImage()!
    }
}
