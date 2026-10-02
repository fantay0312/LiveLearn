// libopus 20 ms CBR encode and 40 ms speech_opus repacketize (spec §14.2–14.3).
import COpus
import COpusShim

public let opusApplicationRestrictedLowDelay: Int32 = 2051
public let opusBitrate: Int32 = 63600
public let opusCBRFrameBytes = 159
public let speechOpusPacketBytes = 320
public let speechOpusPrefix: [UInt8] = [0xBB, 0x42, 0x01]

private let opusSetBitrateRequest: Int32 = 4002
private let opusSetVBRRequest: Int32 = 4006
private let opusSetComplexityRequest: Int32 = 4010
private let opusSetSignalRequest: Int32 = 4024
private let opusSignalVoice: Int32 = 3001

public enum OpusError: Error, CustomStringConvertible, Equatable {
    case library(String)
    /// The Python tree calls this OpusProfileError: any deviation from 159/320 bytes.
    case incompatibleProfile(String)
    case badInput(String)

    public var description: String {
        switch self {
        case .library(let m): return m
        case .incompatibleProfile(let m): return "incompatible profile: \(m)"
        case .badInput(let m): return m
        }
    }
}

public func opusVersionString() -> String {
    guard let p = opus_get_version_string() else { return "unknown" }
    return String(cString: p)
}

/// Assembles two 159-byte CBR frames into the 320-byte `bb 42 01` speech_opus packet.
@inline(__always)
public func packSpeechOpus(first: UnsafeRawBufferPointer, second: UnsafeRawBufferPointer,
                           into packet: UnsafeMutableRawBufferPointer) throws {
    guard first.count == opusCBRFrameBytes, second.count == opusCBRFrameBytes else {
        throw OpusError.incompatibleProfile(
            "20 ms CBR frame must be \(opusCBRFrameBytes) bytes, got \(first.count) and \(second.count)")
    }
    guard (first[0] & 0xFC) == (second[0] & 0xFC) else {
        throw OpusError.incompatibleProfile("paired 20 ms Opus TOC configs must match")
    }
    guard packet.count == speechOpusPacketBytes else {
        throw OpusError.incompatibleProfile("speech_opus packet must be \(speechOpusPacketBytes) bytes, got \(packet.count)")
    }
    packet[0] = (first[0] & 0xFC) | 0x03
    packet[1] = 0x42
    packet[2] = 0x01
    UnsafeMutableRawBufferPointer(rebasing: packet[3..<161]).copyMemory(from: UnsafeRawBufferPointer(rebasing: first[1...]))
    UnsafeMutableRawBufferPointer(rebasing: packet[161..<319]).copyMemory(from: UnsafeRawBufferPointer(rebasing: second[1...]))
    packet[319] = 0
    guard packet[0] == 0xBB else {
        throw OpusError.incompatibleProfile(
            "speech_opus prefix must be bb4201, got \(String(format: "%02x%02x%02x", packet[0], packet[1], packet[2]))")
    }
}

public func packSpeechOpus(first: [UInt8], second: [UInt8]) throws -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: speechOpusPacketBytes)
    try first.withUnsafeBytes { f in
        try second.withUnsafeBytes { s in
            try packet.withUnsafeMutableBytes { try packSpeechOpus(first: f, second: s, into: $0) }
        }
    }
    return packet
}

/// One libopus encoder configured exactly like the reference profile. Not thread-safe (the
/// encoder carries state between 20 ms frames, so a session must feed it in order).
public final class SpeechOpusEncoder {
    private let enc: OpaquePointer
    // Preallocated scratch: aligned Int16 staging for 20 ms, two 159-byte CBR frames.
    private let staging: UnsafeMutablePointer<Int16>
    private let frameA: UnsafeMutablePointer<UInt8>
    private let frameB: UnsafeMutablePointer<UInt8>
    private let scratchCapacity = 4000
    private var hasPendingHalf = false

    public init() throws {
        var err: Int32 = 0
        guard let created = opus_encoder_create(Int32(sampleRate), 1, opusApplicationRestrictedLowDelay, &err), err == 0 else {
            throw OpusError.library("opus_encoder_create failed: \(err)")
        }
        enc = created
        staging = .allocate(capacity: opusFrameSamples)
        frameA = .allocate(capacity: 4000)
        frameB = .allocate(capacity: 4000)
        for (request, value) in [
            (opusSetBitrateRequest, opusBitrate),
            (opusSetVBRRequest, Int32(0)),
            (opusSetComplexityRequest, Int32(10)),
            (opusSetSignalRequest, opusSignalVoice),
        ] {
            let rc = typeless_opus_encoder_ctl_int(enc, request, value)
            if rc != 0 {
                opus_encoder_destroy(enc)
                staging.deallocate(); frameA.deallocate(); frameB.deallocate()
                throw OpusError.incompatibleProfile("opus_encoder_ctl \(request)=\(value) failed: \(rc)")
            }
        }
    }

    deinit {
        opus_encoder_destroy(enc)
        staging.deallocate()
        frameA.deallocate()
        frameB.deallocate()
    }

    /// Encodes 320 aligned samples into `out` (capacity >= 4000). Returns 159 or throws.
    @inline(__always)
    private func encodeFrame(_ pcm: UnsafePointer<Int16>, into out: UnsafeMutablePointer<UInt8>) throws -> Int {
        let n = opus_encode(enc, pcm, Int32(opusFrameSamples), out, Int32(scratchCapacity))
        if n < 0 { throw OpusError.library("opus_encode failed: \(n)") }
        if Int(n) != opusCBRFrameBytes {
            throw OpusError.incompatibleProfile("20 ms CBR frame must be \(opusCBRFrameBytes) bytes, got \(n)")
        }
        return Int(n)
    }

    /// Copies 640 raw bytes (any alignment) into the aligned staging buffer.
    @inline(__always)
    private func stage(_ pcm: UnsafeRawBufferPointer) {
        UnsafeMutableRawPointer(staging).copyMemory(from: pcm.baseAddress!, byteCount: opusFrameBytes)
    }

    /// 20 ms PCM (640 bytes) → 159-byte CBR frame.
    public func encode20ms(_ pcm: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer) throws -> Int {
        guard pcm.count == opusFrameBytes else { throw OpusError.badInput("20 ms PCM must be \(opusFrameBytes) bytes") }
        guard out.count >= opusCBRFrameBytes else { throw OpusError.badInput("output buffer too small") }
        stage(pcm)
        let n = try encodeFrame(staging, into: frameA)
        out.copyMemory(from: UnsafeRawBufferPointer(start: frameA, count: n))
        return n
    }

    public func encode20ms(_ pcm: [UInt8]) throws -> [UInt8] {
        try validatePCM16Length(pcm.count)
        var out = [UInt8](repeating: 0, count: opusCBRFrameBytes)
        _ = try pcm.withUnsafeBytes { p in try out.withUnsafeMutableBytes { try encode20ms(p, into: $0) } }
        return out
    }

    /// 40 ms PCM (1280 bytes) → 320-byte speech_opus packet written into `packet`. Zero heap
    /// allocation: two encodes into preallocated scratch, then a fixed-size assembly.
    public func encode40ms(_ pcm: UnsafeRawBufferPointer, into packet: UnsafeMutableRawBufferPointer) throws {
        guard pcm.count == frameBytes else { throw OpusError.badInput("40 ms PCM must be \(frameBytes) bytes") }
        stage(UnsafeRawBufferPointer(rebasing: pcm[0..<opusFrameBytes]))
        let na = try encodeFrame(staging, into: frameA)
        stage(UnsafeRawBufferPointer(rebasing: pcm[opusFrameBytes..<frameBytes]))
        let nb = try encodeFrame(staging, into: frameB)
        try packSpeechOpus(first: UnsafeRawBufferPointer(start: frameA, count: na),
                           second: UnsafeRawBufferPointer(start: frameB, count: nb), into: packet)
        hasPendingHalf = false
    }

    public func encode40ms(_ pcm: [UInt8]) throws -> [UInt8] {
        try validatePCM16Length(pcm.count)
        var packet = [UInt8](repeating: 0, count: speechOpusPacketBytes)
        try pcm.withUnsafeBytes { p in try packet.withUnsafeMutableBytes { try encode40ms(p, into: $0) } }
        return packet
    }

    /// Streaming half-packet API for the microphone path: encode each 20 ms half as soon as it is
    /// captured; returns `true` when `packet` has been completed by the second half.
    public func pushHalf(_ pcm20: UnsafeRawBufferPointer, into packet: UnsafeMutableRawBufferPointer) throws -> Bool {
        guard pcm20.count == opusFrameBytes else { throw OpusError.badInput("20 ms PCM must be \(opusFrameBytes) bytes") }
        stage(pcm20)
        if !hasPendingHalf {
            _ = try encodeFrame(staging, into: frameA)
            hasPendingHalf = true
            return false
        }
        let nb = try encodeFrame(staging, into: frameB)
        hasPendingHalf = false
        try packSpeechOpus(first: UnsafeRawBufferPointer(start: frameA, count: opusCBRFrameBytes),
                           second: UnsafeRawBufferPointer(start: frameB, count: nb), into: packet)
        return true
    }

    public var hasPendingHalfFrame: Bool { hasPendingHalf }

    /// `encode_pcm`: whole buffer → packets. Trailing PCM shorter than 40 ms is an error unless `pad`.
    public func encodePCM(_ pcm: [UInt8], pad: Bool = false) throws -> [[UInt8]] {
        let (frames, rest) = try framePCM(pcm, pad: pad)
        if !rest.isEmpty { throw OpusError.badInput("trailing PCM shorter than 40 ms; pad only on explicit finish") }
        var out: [[UInt8]] = []
        out.reserveCapacity(frames.count)
        for f in frames { out.append(try encode40ms(f)) }
        return out
    }
}

/// `encode_wav_file`: returns the packet count; writes the concatenated 320-byte packets.
public func encodeWAVFile(input: String, output: String, pad: Bool = true) throws -> Int {
    let pcm = try readWAV(path: input)
    let encoder = try SpeechOpusEncoder()
    let packets = try encoder.encodePCM(pcm, pad: pad)
    var blob: [UInt8] = []
    blob.reserveCapacity(packets.count * speechOpusPacketBytes)
    for p in packets { blob.append(contentsOf: p) }
    try writeFile(path: output, bytes: blob)
    return packets.count
}
