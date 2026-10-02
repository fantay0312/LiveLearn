import AppKit
import CoreGraphics
import ScreenCaptureKit
import os

/// Two consecutive samples outside a dead band change the ink. No screenshot is retained.
struct CaptionBackdropTone {
    private(set) var isBright = false
    private var candidate: Bool?
    private var confirmations = 0

    mutating func update(luminance: Double) -> Bool {
        guard luminance.isFinite else { return isBright }
        let desired: Bool
        if luminance > 0.68 { desired = true }
        else if luminance < 0.46 { desired = false }
        else { candidate = nil; confirmations = 0; return isBright }
        guard desired != isBright else { candidate = nil; confirmations = 0; return isBright }
        if candidate == desired { confirmations += 1 }
        else { candidate = desired; confirmations = 1 }
        if confirmations >= 2 { isBright = desired; candidate = nil; confirmations = 0 }
        return isBright
    }
}

@MainActor
enum CaptionBackdropSampler {
    private static var cached: (windowID: CGWindowID, displayID: CGDirectDisplayID, frame: CGRect, filter: SCContentFilter)?
    private static let log = Logger(subsystem: "com.fantasy.livelearn", category: "caption-contrast")

    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    static func luminance(below window: NSWindow) async -> Double? {
        guard hasAccess, let mainScreen = NSScreen.screens.first,
              let displayID = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
        let windowID = CGWindowID(window.windowNumber)
        let image: CGImage
        do {
            if cached?.windowID != windowID || cached?.displayID != displayID {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }),
                      let caption = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
                cached = (windowID, displayID, display.frame, SCContentFilter(display: display, excludingWindows: [caption]))
            }
            guard let cached else { return nil }
            let frame = window.frame
            let region = CGRect(x: frame.minX + frame.width * 0.18 - cached.frame.minX,
                                y: mainScreen.frame.maxY - frame.maxY + frame.height * 0.40 - cached.frame.minY,
                                width: frame.width * 0.64, height: max(24, frame.height * 0.24))
            let config = SCStreamConfiguration()
            config.sourceRect = region.intersection(CGRect(origin: .zero, size: cached.frame.size))
            guard !config.sourceRect.isEmpty else { return nil }
            config.width = 64
            // Matching the crop's aspect ratio avoids screenshot letterboxing becoming the
            // median "background" colour of this deliberately small brightness sample.
            config.height = max(2, Int(ceil(32 * config.sourceRect.height / config.sourceRect.width)) * 2)
            config.scalesToFit = true
            config.preservesAspectRatio = false
            config.showsCursor = false
            image = try await SCScreenshotManager.captureImage(contentFilter: cached.filter, configuration: config)
        } catch {
            log.error("Background brightness sample failed: \(error.localizedDescription, privacy: .public)")
            cached = nil
            return nil
        }
        var values = [UInt8](repeating: 0, count: 32)
        let measured = values.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 8, height: 4, bitsPerComponent: 8,
                                          bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 4))
            return true
        }
        guard measured else { return nil }
        let sorted = values.sorted()
        return Double(sorted[sorted.count / 2]) / 255
    }
}
