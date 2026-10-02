import CoreGraphics
import Foundation

/// Smooth material coordinates. No radial rows, particle grid or rotating wireframe.
enum MembraneGeometry {
    static let samples = 128

    static func contour(time: Double, pointer: CGPoint? = nil, influence: Double = 0, pulse: Double = 0) -> [CGPoint] {
        let t = time.isFinite ? time : 0
        let expansion = 1 + 0.018 * sin(t * 1.08) + min(1, max(0, pulse)) * 0.014
        return (0..<samples).map { index in
            let a = Double(index) / Double(samples) * .pi * 2
            let lobe = 1 + 0.063 * sin(2 * a - t * 0.24 + 0.6)
                + 0.036 * sin(3 * a + t * 0.19 - 0.8)
                + 0.008 * sin(5 * a - t * 0.12)
            let radius = 0.365 * lobe * expansion
            let p = CGPoint(x: 0.50 + cos(a) * radius * 1.04,
                            y: 0.47 + sin(a) * radius * 0.97 + sin(t * 0.37) * 0.008)
            return pulled(p, pointer: pointer, influence: influence)
        }
    }

    static func pulled(_ point: CGPoint, pointer: CGPoint?, influence: Double) -> CGPoint {
        guard let pointer, pointer.x.isFinite, pointer.y.isFinite, influence.isFinite else { return point }
        let dx = pointer.x - point.x, dy = pointer.y - point.y
        let falloff = exp(-(dx * dx + dy * dy) / 0.085) * min(1, max(0, influence)) * 0.18
        return CGPoint(x: point.x + min(0.035, max(-0.035, dx * falloff)),
                       y: point.y + min(0.035, max(-0.035, dy * falloff)))
    }

    static func fold(_ index: Int, time: Double, pointer: CGPoint?, influence: Double) -> [CGPoint] {
        let t = time.isFinite ? time : 0
        let drift = sin(t * 0.31 + Double(index) * 1.8) * 0.025
        let curves: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
            (.init(x: 0.25, y: 0.20), .init(x: 0.99, y: 0.10 + drift), .init(x: 0.16, y: 0.63), .init(x: 0.71, y: 0.79)),
            (.init(x: 0.20, y: 0.30), .init(x: 0.78, y: 0.09 - drift), .init(x: 0.02, y: 0.70 + drift), .init(x: 0.64, y: 0.82)),
            (.init(x: 0.29, y: 0.77), .init(x: 0.74, y: 0.94 + drift), .init(x: 0.88, y: 0.36), .init(x: 0.64, y: 0.19))
        ]
        let c = curves[min(2, max(0, index))]
        return (0...80).map { step in
            let u = Double(step) / 80, v = 1 - u
            let point = CGPoint(x: v * v * v * c.0.x + 3 * v * v * u * c.1.x + 3 * v * u * u * c.2.x + u * u * u * c.3.x,
                                y: v * v * v * c.0.y + 3 * v * v * u * c.1.y + 3 * v * u * u * c.2.y + u * u * u * c.3.y)
            return pulled(point, pointer: pointer, influence: influence * (index == 2 ? 0.45 : 0.80))
        }
    }
}
