import AppKit
import Foundation
import CoreText

/// Native asset generator. BrandGeometry.swift is the single source for the glyph.
@main
struct BrandAssetGenerator {
    static let paper = "F4F6F8"
    static let ink = "273749"
    static let accent = "4F7896"
    static let darkPaper = "05080D"
    static let darkInk = "EEF6FF"
    static let darkAccent = "9DC5DD"

    static func color(_ hex: String) -> CGColor {
        let value = UInt32(hex, radix: 16)!
        return CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    static func drawMark(_ context: CGContext, rect: CGRect, dark: Bool = false, monochrome: Bool = false, active: Bool = false, glow: Bool = false) {
        context.saveGState()
        for index in LLBrandGeometry.parts.indices {
            let path = LLBrandGeometry.path(for: index, in: rect)
            if monochrome {
                context.setFillColor(color("000000"))
                context.addPath(path); context.fillPath()
            } else {
                let stops = dark ? (index == 0 ? ["F5F7F8", "D0DBE3", "A1B5C8"] : ["8EA9BC", "BFCDD5", "E4ECF0"]) :
                    (index == 0 ? ["263A4B", "426078", "6186A1"] : ["739AAF", "4D748D", "2C4559"])
                if glow {
                    context.saveGState()
                    context.setShadow(offset: .zero, blur: rect.width * 0.014, color: color(darkAccent).copy(alpha: 0.10))
                    context.setFillColor(color(stops[1])); context.addPath(path); context.fillPath()
                    context.restoreGState()
                }
                context.saveGState()
                context.addPath(path); context.clip()
                let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(color) as CFArray, locations: [0, 0.56, 1])!
                context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            }
        }
        context.setFillColor(color(monochrome ? "000000" : (dark ? "F7FCFF" : ink)))
        context.addPath(LLBrandGeometry.nucleus(in: rect, active: monochrome ? active : true)); context.fillPath()
        context.restoreGState()
    }

    static func drawIcon(_ context: CGContext, rect: CGRect) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
        let plate = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), cornerWidth: 198, cornerHeight: 198, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 10), blur: 18, color: color("000000").copy(alpha: 0.28))
        context.setFillColor(color(darkPaper)); context.addPath(plate); context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(plate); context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [color("121923"), color("080D13"), color("030507")] as CFArray, locations: [0, 0.45, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 110, y: 80), end: CGPoint(x: 874, y: 940), options: [])
        context.restoreGState()
        context.addPath(plate); context.setStrokeColor(color("D1E6F8").copy(alpha: 0.09)!)
        context.setLineWidth(1.5); context.strokePath()
        drawMark(context, rect: CGRect(x: 128, y: 128, width: 768, height: 768), dark: true, glow: rect.width >= 128)
        context.restoreGState()
    }

    static func png(width: Int, height: Int, to url: URL, draw: (CGContext) -> Void) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "BrandAssets", code: 1)
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BrandAssets", code: 2)
        }
        try data.write(to: url, options: .atomic)
    }

    static func svgMark(dark: Bool = false, monochrome: Bool = false) -> String {
        let suffix = dark ? "dark" : "light"
        let colors = dark ? [["F5F7F8", "D0DBE3", "A1B5C8"], ["8EA9BC", "BFCDD5", "E4ECF0"]] :
            [["263A4B", "426078", "6186A1"], ["739AAF", "4D748D", "2C4559"]]
        let defs = monochrome ? "" : "<defs>" + (0..<2).map { index in
            "<linearGradient id=\"ribbon-\(index)-\(suffix)\" x1=\"0\" y1=\"0\" x2=\"32\" y2=\"32\" gradientUnits=\"userSpaceOnUse\"><stop stop-color=\"#\(colors[index][0])\"/><stop offset=\".56\" stop-color=\"#\(colors[index][1])\"/><stop offset=\"1\" stop-color=\"#\(colors[index][2])\"/></linearGradient>"
        }.joined() + "</defs>"
        let shapes = LLBrandGeometry.parts.indices.map { index in
            let fill = monochrome ? "#\(dark ? darkInk : ink)" : "url(#ribbon-\(index)-\(suffix))"
            return "<path d=\"\(LLBrandGeometry.svgPath(for: index))\" fill=\"\(fill)\"/>"
        }.joined(separator: "\n")
        let core = monochrome ? (dark ? darkInk : ink) : (dark ? "F7FCFF" : ink)
        return defs + shapes + "<path d=\"\(LLBrandGeometry.nucleusSVG)\" fill=\"#\(core)\"/>"
    }

    static var svgIconBody: String {
        """
        <defs><linearGradient id="plate" x1=".1" y1="0" x2=".9" y2="1"><stop stop-color="#121923"/><stop offset=".45" stop-color="#080D13"/><stop offset="1" stop-color="#030507"/></linearGradient></defs>
        <rect x="64" y="64" width="896" height="896" rx="198" fill="url(#plate)" stroke="#D1E6F8" stroke-opacity=".09" stroke-width="1.5"/>
        <g transform="translate(128 128) scale(24)">\(svgMark(dark: true))</g>
        """
    }

    static func svg(_ body: String, viewBox: String, title: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(viewBox)" role="img" aria-labelledby="title">
        <title id="title">\(title)</title>
        \(body)
        </svg>

        """
    }

    static func writeText(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url, options: .atomic) }

    static func pdf(to url: URL, active: Bool) throws {
        var box = CGRect(x: 0, y: 0, width: 18, height: 18)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw NSError(domain: "BrandAssets", code: 3) }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: 18)
        context.scaleBy(x: 1, y: -1)
        drawMark(context, rect: CGRect(x: -1, y: -1, width: 20, height: 20), monochrome: true, active: active)
        context.endPDFPage()
        context.closePDF()
    }

    static func label(_ text: String, context: CGContext, x: CGFloat, y: CGFloat, size: CGFloat, hex: String, weight: NSFont.Weight = .regular) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(cgColor: color(hex))!
        ]))
        context.saveGState()
        context.translateBy(x: x, y: y + size); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func previewSheet(_ context: CGContext) {
        context.setFillColor(color("090D12")); context.fill(CGRect(x: 0, y: 0, width: 1080, height: 640))
        drawIcon(context, rect: CGRect(x: 28, y: 54, width: 510, height: 510))
        label("LiveLearn", context: context, x: 572, y: 68, size: 43, hex: darkInk, weight: .medium)
        label("双股流光 · 同一星核", context: context, x: 575, y: 128, size: 17, hex: "A8BBCB")
        label("与星云界面一致的应用标识", context: context, x: 575, y: 163, size: 13, hex: "778B9E")
        context.setFillColor(color("EDF1F5")); context.fill(CGRect(x: 572, y: 222, width: 172, height: 116))
        drawMark(context, rect: CGRect(x: 620, y: 241, width: 76, height: 76), monochrome: true, active: true)
        context.setFillColor(color("17212B")); context.fill(CGRect(x: 770, y: 222, width: 172, height: 116))
        drawMark(context, rect: CGRect(x: 818, y: 241, width: 76, height: 76), dark: true)
        label("单色标识", context: context, x: 572, y: 350, size: 12, hex: "8FA3B4")
        label("银蓝标识", context: context, x: 770, y: 350, size: 12, hex: "8FA3B4")
        for (index, side) in [16, 32, 64, 128].enumerated() {
            let x: CGFloat = [574, 634, 718, 842][index]
            drawIcon(context, rect: CGRect(x: x, y: CGFloat(528 - side), width: CGFloat(side), height: CGFloat(side)))
            label("\(side) px", context: context, x: x, y: 546, size: 11, hex: "8FA3B4")
        }
        label("原生矢量 / 透明外围 / 单色菜单栏", context: context, x: 60, y: 590, size: 12, hex: "71869A")
    }

    static var previewSVG: String {
        svg("""
        <rect width="1080" height="640" fill="#090D12"/>
        <g transform="translate(28 54) scale(.498046875)">\(svgIconBody)</g>
        <text x="572" y="111" fill="#EEF6FF" font-family="-apple-system,Helvetica Neue,sans-serif" font-size="43" font-weight="500">LiveLearn</text>
        <text x="575" y="149" fill="#A8BBCB" font-family="-apple-system,PingFang SC,sans-serif" font-size="17">双股流光 · 同一星核</text>
        <rect x="572" y="222" width="172" height="116" fill="#EDF1F5"/>
        <g transform="translate(620 241) scale(2.375)">\(svgMark(monochrome: true))</g>
        <g transform="translate(770 230) scale(3)">\(svgMark(dark: true, monochrome: true))</g>
        <text x="575" y="430" fill="#8FA3B4" font-family="-apple-system,PingFang SC,sans-serif" font-size="14">原生矢量 · 应用图标 · 单色菜单栏</text>
        """, viewBox: "0 0 1080 640", title: "LiveLearn 星核标识")
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: generate-brand-assets <assets-directory> <iconset-directory>\n", stderr)
            exit(1)
        }
        let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        for directory in [assets, iconset] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let suffix = scale == 2 ? "@2x" : ""
                try png(width: pixels, height: pixels, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")) {
                    drawIcon($0, rect: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                }
            }
        }
        try png(width: 1024, height: 1024, to: assets.appendingPathComponent("app-icon.png")) {
            drawIcon($0, rect: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        try writeText(svg(svgIconBody, viewBox: "0 0 1024 1024", title: "LiveLearn 双流星核应用图标"), to: assets.appendingPathComponent("app-icon.svg"))
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try writeText(svg(svgMark(dark: dark), viewBox: "0 0 32 32", title: "LiveLearn 标志"), to: assets.appendingPathComponent("mark-\(suffix).svg"))
            try writeText(svg(svgMark(dark: dark, monochrome: true), viewBox: "0 0 32 32", title: "LiveLearn 单色标志"), to: assets.appendingPathComponent("mark-monochrome-\(suffix).svg"))
            let lockup = "<g transform=\"translate(4 4) scale(1.75)\">\(svgMark(dark: dark))</g><text x=\"78\" y=\"45\" fill=\"#\(dark ? darkInk : ink)\" font-family=\"-apple-system, BlinkMacSystemFont, Helvetica Neue, sans-serif\" font-size=\"38\" font-weight=\"500\" letter-spacing=\"-0.8\">LiveLearn</text>"
            try writeText(svg(lockup, viewBox: "0 0 270 64", title: "LiveLearn 字标"), to: assets.appendingPathComponent("wordmark-\(suffix).svg"))
        }
        try pdf(to: assets.appendingPathComponent("MenuBarTemplate.pdf"), active: false)
        try pdf(to: assets.appendingPathComponent("MenuBarActiveTemplate.pdf"), active: true)
        for active in [false, true] {
            try png(width: 72, height: 72, to: assets.appendingPathComponent(active ? "menu-active-preview.png" : "menu-idle-preview.png")) { context in
                context.setFillColor(color("EDF1F5")); context.fill(CGRect(x: 0, y: 0, width: 72, height: 72))
                context.scaleBy(x: 4, y: 4)
                drawMark(context, rect: CGRect(x: -1, y: -1, width: 20, height: 20), monochrome: true, active: active)
            }
        }
        try png(width: 1080, height: 640, to: assets.appendingPathComponent("brand-preview.png"), draw: previewSheet)
        try writeText(previewSVG, to: assets.appendingPathComponent("brand-preview.svg"))
        print("Brand vectors, PNGs, template PDFs, and 10 icon representations generated.")
    }
}
