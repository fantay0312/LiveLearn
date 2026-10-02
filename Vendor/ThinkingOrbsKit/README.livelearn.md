# ThinkingOrbsKit in LiveLearn

Source: the user's local LibrariesDev collection, `Libraries.dev/packages/thinking-orbs/ports/ios/ThinkingOrbsKit`.
Spec 1.0.0, thinking-orbs 0.3.1, MIT; copyright 2026 Jakub Antalik. See `LICENSE`.

LiveLearn uses the native SwiftUI `composing` state (ribbon) shown as “组织中” in the collection's demo. No WebView, network service, or JavaScript runtime is involved. The wrapper supplies the recognition status and a 32 pt display size; the 64 pt preset preserves the reference's dense dotted appearance. Reduced motion and static preview time are supported by the upstream component.

The main session hero now uses LiveLearn's own native Canvas stardust core, following the user's
2026-09-12 request to replace the gray membrane. The large `breathing` ring is no longer its renderer.
This package remains in use for the caption recognition `composing` state described above.

Local changes: cap TimelineView to 30 fps; add opt-in ringSegments and particleScale for large
renditions. These optional parameters preserve breathing lanes, waveform, orientation and
speed. Fine renditions batch
grayscale/alpha drawing; default rendering remains unchanged. Upstream golden vectors are
bundled as test resources so the vendored tests run independently of the original checkout.
