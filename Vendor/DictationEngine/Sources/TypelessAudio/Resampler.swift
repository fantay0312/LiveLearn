// Device-rate Float32 mono → 16 kHz Int16 mono through AudioToolbox's AudioConverter (pull
// model). Runs on the encode thread, never on the IO thread; no allocation after init.
import AudioToolbox
import Foundation

public struct ResamplerError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

private let kNoMoreInput: OSStatus = 0x7E11_7E11 // private "input exhausted" code

public final class Resampler {
    public let inputRate: Double
    public let outputRate: Double = 16000
    private var converter: AudioConverterRef? = nil
    private let staging: UnsafeMutablePointer<Float>
    private let stagingCapacity: Int
    private var provider: ((UnsafeMutablePointer<Float>, Int) -> Int)? = nil
    public var ratio: Double { inputRate / outputRate }

    public init(inputRate: Double) throws {
        self.inputRate = inputRate
        stagingCapacity = 8192
        staging = .allocate(capacity: stagingCapacity)
        if inputRate == outputRate { return }
        var inFormat = AudioStreamBasicDescription(
            mSampleRate: inputRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: outputRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1,
            mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var conv: AudioConverterRef? = nil
        let status = AudioConverterNew(&inFormat, &outFormat, &conv)
        guard status == noErr, let c = conv else {
            staging.deallocate()
            throw ResamplerError(message: "AudioConverterNew failed: \(status)")
        }
        converter = c
        var quality: UInt32 = kAudioConverterQuality_Medium
        AudioConverterSetProperty(c, kAudioConverterSampleRateConverterQuality, UInt32(MemoryLayout<UInt32>.size), &quality)
        var prime: UInt32 = kConverterPrimeMethod_None
        AudioConverterSetProperty(c, kAudioConverterPrimeMethod, UInt32(MemoryLayout<UInt32>.size), &prime)
    }

    deinit {
        if let c = converter { AudioConverterDispose(c) }
        staging.deallocate()
    }

    /// Input frames the caller should have available before asking for `outFrames`.
    public func inputFramesNeeded(for outFrames: Int) -> Int {
        Int((Double(outFrames) * ratio).rounded(.up)) + (converter == nil ? 0 : 64)
    }

    /// Produces up to `frames` Int16 samples into `out`, pulling Float32 input via `provide`
    /// (`provide(dst, maxCount)` → count copied). Returns produced frames.
    public func convert(into out: UnsafeMutablePointer<Int16>, frames: Int,
                        provide: (UnsafeMutablePointer<Float>, Int) -> Int) -> Int {
        guard let c = converter else {
            // Same rate: float → int16 with clipping.
            let n = provide(staging, min(frames, stagingCapacity))
            for i in 0..<n {
                let v = staging[i] * 32767
                out[i] = Int16(max(-32768, min(32767, v)))
            }
            return n
        }
        return withoutActuallyEscaping(provide) { escapable -> Int in
            provider = escapable
            defer { provider = nil }
            var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 2), mData: UnsafeMutableRawPointer(out)))
            var packets = UInt32(frames)
            let status = AudioConverterFillComplexBuffer(c, resamplerInputProc, Unmanaged.passUnretained(self).toOpaque(), &packets, &outList, nil)
            if status != noErr && status != kNoMoreInput { return 0 }
            return Int(packets)
        }
    }

    fileprivate func supplyInput(_ ioPackets: UnsafeMutablePointer<UInt32>, _ ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let want = min(Int(ioPackets.pointee), stagingCapacity)
        let got = provider?(staging, want) ?? 0
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        list[0].mNumberChannels = 1
        list[0].mDataByteSize = UInt32(got * 4)
        list[0].mData = got > 0 ? UnsafeMutableRawPointer(staging) : nil
        ioPackets.pointee = UInt32(got)
        return got == 0 ? kNoMoreInput : noErr
    }
}

private let resamplerInputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, _, userData in
    guard let userData = userData else { ioPackets.pointee = 0; return kNoMoreInput }
    let resampler = Unmanaged<Resampler>.fromOpaque(userData).takeUnretainedValue()
    return resampler.supplyInput(ioPackets, ioData)
}
