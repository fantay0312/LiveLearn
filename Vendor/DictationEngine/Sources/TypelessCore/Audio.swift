// PCM16 / WAV validation and 40 ms framing (spec §14.1).
import Foundation

public let sampleRate = 16000
public let channels = 1
public let sampleWidth = 2
public let frameMs = 40
public let frameSamples = 640
public let frameBytes = frameSamples * sampleWidth // 1280
public let opusFrameMs = 20
public let opusFrameSamples = 320
public let opusFrameBytes = opusFrameSamples * sampleWidth // 640

public enum AudioError: Error, Equatable, CustomStringConvertible {
    case oddLength
    case wav(String)
    public var description: String {
        switch self {
        case .oddLength: return "pcm length must be a multiple of 2"
        case .wav(let m): return m
        }
    }
}

@inline(__always)
public func validatePCM16Length(_ count: Int) throws {
    if count % sampleWidth != 0 { throw AudioError.oddLength }
}

/// Shipped Adapter PCM splitter: 1280-byte frames; the tail is zero-padded only on finish.
/// Byte-oriented ring-less buffer; `drain` hands out frames as raw pointers (no copies).
public struct PCMFramer {
    public private(set) var buffer: [UInt8]
    private var readOffset = 0

    public init(capacity: Int = 16 * 1024) {
        buffer = []
        buffer.reserveCapacity(capacity)
    }

    public var pendingBytes: Int { buffer.count - readOffset }

    public mutating func append(_ data: UnsafeRawBufferPointer) throws {
        try validatePCM16Length(data.count)
        if readOffset > 0 && readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset > 4096 {
            buffer.removeFirst(readOffset)
            readOffset = 0
        }
        buffer.append(contentsOf: data)
    }

    public mutating func append(_ data: [UInt8]) throws {
        try data.withUnsafeBytes { try append($0) }
    }

    /// Calls `body` for each complete 1280-byte frame. With `finish`, the remaining tail (if any)
    /// is zero-padded into one last frame; `body` receives a pointer valid only during the call.
    public mutating func drain(finish: Bool, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        while buffer.count - readOffset >= frameBytes {
            let start = readOffset
            readOffset += frameBytes
            try buffer.withUnsafeBytes { raw in
                try body(UnsafeRawBufferPointer(rebasing: raw[start..<start + frameBytes]))
            }
        }
        if finish && buffer.count - readOffset > 0 {
            var padded = [UInt8](repeating: 0, count: frameBytes)
            padded.withUnsafeMutableBytes { dst in
                buffer.withUnsafeBytes { src in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[readOffset..<buffer.count]))
                }
            }
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            try padded.withUnsafeBytes { try body($0) }
        }
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        }
    }

    /// Convenience port of `take_pcm_frames(buffer, incoming, finish=)`.
    public mutating func takeFrames(incoming: [UInt8] = [], finish: Bool = false) throws -> [[UInt8]] {
        if !incoming.isEmpty { try append(incoming) }
        var out: [[UInt8]] = []
        try drain(finish: finish) { out.append(Array($0)) }
        return out
    }
}

/// `frame_pcm`: split into 40 ms frames; pad the tail only when `pad` (explicit finish).
public func framePCM(_ pcm: [UInt8], pad: Bool = false) throws -> (frames: [[UInt8]], rest: [UInt8]) {
    try validatePCM16Length(pcm.count)
    var frames: [[UInt8]] = []
    var offset = 0
    while offset + frameBytes <= pcm.count {
        frames.append(Array(pcm[offset..<offset + frameBytes]))
        offset += frameBytes
    }
    var rest = Array(pcm[offset...])
    if pad && !rest.isEmpty {
        rest.append(contentsOf: [UInt8](repeating: 0, count: frameBytes - rest.count))
        frames.append(rest)
        rest = []
    } else if pad && frames.isEmpty && rest.isEmpty {
        frames.append([UInt8](repeating: 0, count: frameBytes))
    }
    return (frames, rest)
}

// MARK: - WAV

private func le16(_ b: UnsafeRawBufferPointer, _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
private func le32(_ b: UnsafeRawBufferPointer, _ o: Int) -> Int {
    Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
}

/// Reads a RIFF/WAVE file and validates 16 kHz / mono / 16-bit / PCM (same errors as `read_wav`).
public func readWAV(path: String) throws -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw AudioError.wav("cannot read wav: \(path)")
    }
    return try data.withUnsafeBytes { raw -> [UInt8] in
        guard raw.count >= 12,
              raw[0] == 0x52, raw[1] == 0x49, raw[2] == 0x46, raw[3] == 0x46, // RIFF
              raw[8] == 0x57, raw[9] == 0x41, raw[10] == 0x56, raw[11] == 0x45 // WAVE
        else { throw AudioError.wav("file does not start at RIFF id") }
        var offset = 12
        var fmtSeen = false
        var pcm: [UInt8]? = nil
        while offset + 8 <= raw.count {
            let id = String(decoding: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + 4]), as: UTF8.self)
            let size = le32(raw, offset + 4)
            let body = offset + 8
            let end = min(body + size, raw.count)
            if id == "fmt " {
                guard size >= 16 else { throw AudioError.wav("bad fmt chunk") }
                var tag = le16(raw, body)
                let ch = le16(raw, body + 2)
                let rate = le32(raw, body + 4)
                let bits = le16(raw, body + 14)
                if tag == 0xFFFE, size >= 40 { tag = le16(raw, body + 24) } // WAVE_FORMAT_EXTENSIBLE subformat
                if ch != channels { throw AudioError.wav("wav must be mono") }
                if rate != sampleRate { throw AudioError.wav("wav must be 16000 Hz") }
                if bits != 16 { throw AudioError.wav("wav must be 16-bit PCM") }
                if tag != 1 { throw AudioError.wav("wav must be uncompressed PCM") }
                fmtSeen = true
            } else if id == "data" {
                guard fmtSeen else { throw AudioError.wav("data chunk before fmt chunk") }
                pcm = Array(raw[body..<end])
                break
            }
            offset = body + size + (size & 1)
        }
        guard fmtSeen, var out = pcm else { throw AudioError.wav("wav missing fmt/data chunk") }
        if out.count % 2 != 0 { out.removeLast() }
        return out
    }
}

public func writeWAV(path: String, pcm: [UInt8]) throws {
    try validatePCM16Length(pcm.count)
    var out: [UInt8] = []
    out.reserveCapacity(44 + pcm.count)
    func u32(_ v: Int) { out.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]) }
    func u16(_ v: Int) { out.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
    out.append(contentsOf: "RIFF".utf8); u32(36 + pcm.count); out.append(contentsOf: "WAVE".utf8)
    out.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(channels); u32(sampleRate)
    u32(sampleRate * channels * sampleWidth); u16(channels * sampleWidth); u16(16)
    out.append(contentsOf: "data".utf8); u32(pcm.count); out.append(contentsOf: pcm)
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(out).write(to: url)
}
