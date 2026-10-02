import Foundation
import os

/// One switch the app flips while it speaks a translation aloud: the microphone lane keeps
/// its clock (packets keep flowing, correctly timed) but carries silence, so the room's
/// loudspeaker does not feed the app's own voice back into recognition.
public final class MicrophoneGate: Sendable {
    public static let shared = MicrophoneGate()
    private let muted = OSAllocatedUnfairLock(initialState: false)

    public var isMuted: Bool {
        get { muted.withLock { $0 } }
        set { muted.withLock { $0 = newValue } }
    }
}
