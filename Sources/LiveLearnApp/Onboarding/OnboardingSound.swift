import AppKit

@MainActor
final class OnboardingSound {
    private var sound: NSSound?

    func play() {
        stop()
        let rate = 22_050
        let count = rate / 2
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            let envelope = min(1, time / 0.025) * pow(1 - Double(index) / Double(count), 3)
            let note = sin(2 * .pi * 523.25 * time) + 0.35 * sin(2 * .pi * 783.99 * time)
            var sample = Int16(note * envelope * 1_800).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count)); wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate))
        append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(pcm.count)); wav.append(pcm)
        sound = NSSound(data: wav)
        sound?.volume = 0.35
        sound?.play()
    }

    func stop() { sound?.stop(); sound = nil }
}
