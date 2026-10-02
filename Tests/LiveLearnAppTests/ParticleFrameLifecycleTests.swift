import AppKit
import Testing
@testable import LiveLearnApp

@MainActor
@Suite(.serialized)
struct ParticleFrameLifecycleTests {
    private final class FrameHost: ParticleMetalHostView {
        override func applyGate(_ open: Bool) -> Bool { open }
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 80, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    @Test func replacementDriverResumesEvenWhenLogicalStateIsAlreadyPlaying() throws {
        let renderer = try #require(ParticleMetalRenderer.shared)
        let window = window()
        let view = FrameHost(renderer: renderer)
        defer { view.detach(); window.close() }
        window.contentView = view
        #expect(view.playing)
        #expect(!view.frameDriverPaused)

        // Reattaching a host recreates the native driver without changing the logical gate.
        view.viewDidMoveToWindow()
        #expect(view.playing)
        #expect(!view.frameDriverPaused)
    }

    @Test func movingAnActiveViewToAnotherVisibleWindowKeepsItsDriverRunning() throws {
        let renderer = try #require(ParticleMetalRenderer.shared)
        let first = window()
        let second = window()
        let view = FrameHost(renderer: renderer)
        defer { view.detach(); first.close(); second.close() }
        first.contentView?.addSubview(view)
        #expect(view.playing)
        second.contentView?.addSubview(view)
        #expect(view.window === second)
        #expect(view.playing)
        #expect(!view.frameDriverPaused)
    }

    @Test func pauseReasonsAndDetachmentStillStopTheNativeDriver() throws {
        let renderer = try #require(ParticleMetalRenderer.shared)
        let window = window()
        let view = FrameHost(renderer: renderer)
        defer { view.detach(); window.close() }
        window.contentView = view
        for _ in 0..<3 {
            view.ambientPaused = true
            #expect(!view.playing && view.frameDriverPaused)
            view.ambientPaused = false
            #expect(view.playing && !view.frameDriverPaused)
            view.reduceMotion = true
            #expect(!view.playing && view.frameDriverPaused)
            view.reduceMotion = false
            #expect(view.playing && !view.frameDriverPaused)
        }
        view.detach()
        #expect(!view.playing && view.frameDriverPaused)
    }
}
