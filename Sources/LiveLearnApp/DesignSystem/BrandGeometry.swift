import CoreGraphics
import Foundation

/// Two counterbalanced light currents around a common nucleus, normalized to 32 × 32.
/// Runtime, template PDFs and SVG exports share these closed Bézier shapes.
enum LLBrandGeometry {
    static let canvas: CGFloat = 32
    enum Command {
        case move(CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
        case close
    }

    static let parts: [[Command]] = [
        [.move(CGPoint(x: 6.0, y: 18.2)),
         .curve(CGPoint(x: 3.3, y: 11.7), CGPoint(x: 8.0, y: 5.0), CGPoint(x: 15.2, y: 5.4)),
         .curve(CGPoint(x: 20.1, y: 5.5), CGPoint(x: 24.5, y: 7.6), CGPoint(x: 26.7, y: 11.0)),
         .curve(CGPoint(x: 22.8, y: 8.55), CGPoint(x: 18.6, y: 7.6), CGPoint(x: 14.8, y: 8.2)),
         .curve(CGPoint(x: 9.8, y: 8.95), CGPoint(x: 6.1, y: 12.6), CGPoint(x: 6.0, y: 18.2)), .close],
        [.move(CGPoint(x: 26.0, y: 13.8)),
         .curve(CGPoint(x: 28.7, y: 20.3), CGPoint(x: 24.0, y: 27.0), CGPoint(x: 16.8, y: 26.6)),
         .curve(CGPoint(x: 11.9, y: 26.5), CGPoint(x: 7.5, y: 24.4), CGPoint(x: 5.3, y: 21.0)),
         .curve(CGPoint(x: 9.2, y: 23.45), CGPoint(x: 13.4, y: 24.4), CGPoint(x: 17.2, y: 23.8)),
         .curve(CGPoint(x: 22.2, y: 23.05), CGPoint(x: 25.9, y: 19.4), CGPoint(x: 26.0, y: 13.8)), .close]
    ]

    static func path(for index: Int, in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for command in parts[index] {
            switch command {
            case .move(let p): path.move(to: p)
            case .curve(let a, let b, let end): path.addCurve(to: end, control1: a, control2: b)
            case .close: path.closeSubpath()
            }
        }
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / canvas, y: rect.height / canvas)
        return path.copy(using: &transform)!
    }

    static func nucleus(in rect: CGRect, active: Bool = true) -> CGPath {
        let p = CGMutablePath()
        if active {
            p.move(to: CGPoint(x: 16, y: 13.6))
            p.addQuadCurve(to: CGPoint(x: 17.95, y: 16), control: CGPoint(x: 16.3, y: 15.7))
            p.addQuadCurve(to: CGPoint(x: 16, y: 18.4), control: CGPoint(x: 16.3, y: 16.3))
            p.addQuadCurve(to: CGPoint(x: 14.05, y: 16), control: CGPoint(x: 15.7, y: 16.3))
            p.addQuadCurve(to: CGPoint(x: 16, y: 13.6), control: CGPoint(x: 15.7, y: 15.7))
            p.closeSubpath()
        } else {
            p.addEllipse(in: CGRect(x: 14.85, y: 14.85, width: 2.3, height: 2.3))
        }
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / canvas, y: rect.height / canvas)
        return p.copy(using: &transform)!
    }

    static func svgPath(for index: Int) -> String {
        func point(_ p: CGPoint) -> String { "\(p.x) \(p.y)" }
        return parts[index].map { command in
            switch command {
            case .move(let p): "M\(point(p))"
            case .curve(let a, let b, let end): "C\(point(a)) \(point(b)) \(point(end))"
            case .close: "Z"
            }
        }.joined(separator: " ")
    }
    static let nucleusSVG = "M16 13.6 Q16.3 15.7 17.95 16 Q16.3 16.3 16 18.4 Q15.7 16.3 14.05 16 Q15.7 15.7 16 13.6 Z"
}
