import SwiftUI

/// A translucent body with a rear envelope, overlapping folds and local reflected light.
struct MembraneOrganism: View {
    let time: Double
    var pointer: CGPoint? = nil
    var influence = 0.0
    var pulse = 0.0
    @Environment(\.theme) private var theme
    private static let inclusions = (0..<24).map { index in
        CGPoint(x: 0.22 + LexiconConstellation.fraction("membrane-\(index)") * 0.56,
                y: 0.20 + LexiconConstellation.fraction("membrane-\(index)", salt: 17) * 0.60)
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let side = min(size.width, size.height)
            let pearl = theme.isDark ? Color(hex: 0xEDF4F2) : theme.accent
            let ice = theme.isDark ? Color(hex: 0xB4D0DF) : theme.ink2
            let shell = closed(MembraneGeometry.contour(time: time, pointer: pointer, influence: influence, pulse: pulse), side: side)
            let rear = closed(MembraneGeometry.contour(time: time - 1.4).map {
                CGPoint(x: 0.52 + ($0.x - 0.50) * 0.94, y: 0.46 + ($0.y - 0.47) * 0.96)
            }, side: side)

            context.fill(rear, with: .linearGradient(Gradient(colors: [ice.opacity(0.018), pearl.opacity(0.038), .clear]),
                startPoint: .init(x: side * 0.72, y: side * 0.18), endPoint: .init(x: side * 0.24, y: side * 0.84)))
            context.fill(shell, with: .linearGradient(Gradient(stops: [
                .init(color: pearl.opacity(0.07 + pulse * 0.025), location: 0),
                .init(color: ice.opacity(0.023), location: 0.42),
                .init(color: pearl.opacity(0.012), location: 0.72),
                .init(color: ice.opacity(0.065), location: 1)
            ]), startPoint: .init(x: side * 0.18, y: side * 0.16), endPoint: .init(x: side * 0.80, y: side * 0.86)))

            var interior = context
            interior.clip(to: shell)
            interior.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [pearl.opacity(0.106), .clear]),
                center: .init(x: side * 0.28, y: side * 0.26), startRadius: 0, endRadius: side * 0.33))
            interior.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [ice.opacity(0.065), .clear]),
                center: .init(x: side * 0.73, y: side * 0.66), startRadius: 0, endRadius: side * 0.27))
            for index in [2, 0, 1] {
                let points = MembraneGeometry.fold(index, time: time, pointer: pointer, influence: influence)
                let normals = taperedNormals(points)
                let shade = index == 2 ? ice : pearl
                let opacity = index == 2 ? 0.42 : (index == 0 ? 1.0 : 0.49)
                // Broad, one-sided sheets gather light toward their crease. Fine steps
                // make a continuous material falloff instead of stacked luminous wires.
                for layer in 0..<18 {
                    let progress = Double(layer) / 17
                    let width = 0.12 * pow(1 - progress, 1.6) + 0.0015
                    let alpha = (0.010 + progress * progress * 0.018) * opacity
                    let fold = ribbon(points, normals: normals, width: width, side: side)
                    interior.fill(fold, with: .linearGradient(Gradient(colors: [.clear, shade.opacity(alpha), shade.opacity(alpha * 0.80), .clear]),
                        startPoint: points.first!.scaled(side), endPoint: points.last!.scaled(side)))
                }
                interior.stroke(open(points, side: side), with: .linearGradient(Gradient(stops: [
                    .init(color: .clear, location: 0), .init(color: shade.opacity(0.44 * opacity), location: 0.26),
                    .init(color: shade.opacity((index == 2 ? 0 : 0.12) * opacity), location: 0.60),
                    .init(color: shade.opacity((index == 2 ? 0 : 0.18) * opacity), location: 0.80),
                    .init(color: .clear, location: 1)
                ]), startPoint: points.first!.scaled(side), endPoint: points.last!.scaled(side)), lineWidth: max(0.6, side * 0.002))
            }

            // Sparse inclusions drift inside the volume; they never form rows or a perimeter.
            for index in 0..<24 {
                let x = Self.inclusions[index].x + sin(time * 0.18 + Double(index)) * 0.012
                let y = Self.inclusions[index].y + cos(time * 0.14 + Double(index)) * 0.012
                let radius = side * (index % 7 == 0 ? 0.0017 : 0.0011)
                interior.fill(Path(ellipseIn: CGRect(x: x * side, y: y * side, width: radius * 2, height: radius * 2)),
                              with: .color(pearl.opacity(index % 7 == 0 ? 0.30 : 0.13)))
            }

            context.stroke(shell, with: .linearGradient(Gradient(stops: [
                .init(color: pearl.opacity(0.60), location: 0), .init(color: pearl.opacity(0.16), location: 0.23),
                .init(color: .clear, location: 0.48), .init(color: .clear, location: 0.74),
                .init(color: ice.opacity(0.32), location: 1)
            ]), startPoint: .init(x: side * 0.16, y: side * 0.16), endPoint: .init(x: side * 0.84, y: side * 0.84)),
                           lineWidth: max(0.7, side * 0.0026))
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func closed(_ points: [CGPoint], side: CGFloat) -> Path {
        var path = open(points, side: side)
        path.closeSubpath()
        return path
    }

    private func open(_ points: [CGPoint], side: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first.scaled(side))
        for point in points.dropFirst() { path.addLine(to: point.scaled(side)) }
        return path
    }

    private func taperedNormals(_ points: [CGPoint]) -> [CGPoint] {
        points.indices.map { index in
            let before = points[max(0, index - 1)], after = points[min(points.count - 1, index + 1)]
            let dx = after.x - before.x, dy = after.y - before.y
            let length = max(0.001, hypot(dx, dy))
            let u = Double(index) / Double(points.count - 1)
            let taper = pow(max(0, sin(u * .pi)), 0.85)
            return CGPoint(x: -dy / length * taper, y: dx / length * taper)
        }
    }

    private func ribbon(_ points: [CGPoint], normals: [CGPoint], width: Double, side: CGFloat) -> Path {
        let left = zip(points, normals).map { p, n in CGPoint(x: p.x + n.x * width, y: p.y + n.y * width) }
        let right = zip(points, normals).reversed().map { p, n in CGPoint(x: p.x - n.x * width * 0.12, y: p.y - n.y * width * 0.12) }
        return closed(left + right, side: side)
    }
}

private extension CGPoint {
    func scaled(_ value: CGFloat) -> CGPoint { CGPoint(x: x * value, y: y * value) }
}
