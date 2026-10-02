import AppKit
import CoreGraphics

/// Development aid behind `--capture-window`: a window as the window server composites it —
/// Metal layers, the modal's blur and all — written to a PNG at the backing resolution, so a
/// Canvas frame and a Metal frame can be compared pixel for pixel without a screen recording
/// permission (a process may image its own windows; `screencapture -l` from a terminal may not).
enum WindowCapture {
    private typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?

    /// The window to capture: the largest visible document-level window (the main window; the
    /// settings modal lives inside it). SwiftUI keeps small helper windows around whose
    /// identifiers can also start with the scene id, so the identifier is not the criterion.
    @MainActor
    static var target: NSWindow? {
        NSApp.windows.filter { $0.isVisible && $0.level == .normal && $0.frame.width > 300 && $0.frame.height > 300 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    @MainActor
    static func write(_ window: NSWindow?, to url: URL) -> Bool {
        guard let window else { return false }
        // Resolved by name: `CGWindowListCreateImage` is deprecated in favour of ScreenCaptureKit,
        // which needs the screen-recording permission even for the process's own window.
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return false }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        guard let image = create(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                 [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            FileHandle.standardError.write(Data("captured window \(window.windowNumber) \(Int(window.frame.width))×\(Int(window.frame.height)) pt (\(image.width)×\(image.height) px) → \(url.path)\n".utf8))
            return true
        } catch {
            return false
        }
    }
}
