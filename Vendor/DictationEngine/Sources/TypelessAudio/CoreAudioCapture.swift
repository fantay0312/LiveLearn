// Direct CoreAudio microphone capture via an AUHAL (kAudioUnitSubType_HALOutput) with the input
// bus enabled and the output bus disabled. Replaces the Python `ffmpeg -f avfoundation` pipe
// (extra process + tens of ms of pipe buffering).
//
// Realtime IO callback contract: AudioUnitRender into a preallocated buffer, copy into the SPSC
// ring, publish a timestamp, signal a Mach semaphore. No allocation, no locks, no Swift async.
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization
import TypelessCore

public struct AudioDeviceInfo: Sendable {
    public var id: AudioDeviceID
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var nominalSampleRate: Double
    public var isDefaultInput: Bool
    public var bufferFrameSize: UInt32
    public var bufferFrameRange: (min: UInt32, max: UInt32)

    public func json(index: Int) -> JSONValue {
        .obj([
            ("id", .int(Int64(index))),
            ("name", .string(name)),
            ("channels", .int(Int64(inputChannels))),
            ("default_samplerate", .double(nominalSampleRate)),
            ("host", .string("coreaudio")),
            ("uid", .string(uid)),
            ("device_id", .int(Int64(id))),
            ("default", .bool(isDefaultInput)),
            ("buffer_frames", .int(Int64(bufferFrameSize))),
        ])
    }
}

public struct AudioCaptureError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Property helpers

private func propertyAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T? {
    var address = propertyAddress(selector, scope: scope)
    var size = UInt32(MemoryLayout<T>.size)
    var out = value
    let status = withUnsafeMutablePointer(to: &out) { ptr in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer(ptr))
    }
    return status == noErr ? out : nil
}

private func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>? = nil
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
    }
    guard status == noErr, let cf = value?.takeRetainedValue() else { return "" }
    return cf as String
}

private func inputChannelCount(_ device: AudioDeviceID) -> Int {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    var channels = 0
    for buffer in list { channels += Int(buffer.mNumberChannels) }
    return channels
}

public enum AudioDevices {
    public static func defaultInputDevice() -> AudioDeviceID? {
        guard let id: AudioDeviceID = getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: 0),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    public static func info(_ id: AudioDeviceID, defaultId: AudioDeviceID?) -> AudioDeviceInfo? {
        let channels = inputChannelCount(id)
        guard channels > 0 else { return nil }
        let rate: Double = getProperty(id, kAudioDevicePropertyNominalSampleRate, default: 0.0) ?? 0
        let frames: UInt32 = getProperty(id, kAudioDevicePropertyBufferFrameSize, scope: kAudioDevicePropertyScopeInput, default: 0) ?? 0
        let range: AudioValueRange = getProperty(id, kAudioDevicePropertyBufferFrameSizeRange, scope: kAudioDevicePropertyScopeInput,
                                                 default: AudioValueRange(mMinimum: 0, mMaximum: 0)) ?? AudioValueRange(mMinimum: 0, mMaximum: 0)
        return AudioDeviceInfo(
            id: id, uid: getString(id, kAudioDevicePropertyDeviceUID), name: getString(id, kAudioObjectPropertyName),
            inputChannels: channels, nominalSampleRate: rate, isDefaultInput: id == defaultId, bufferFrameSize: frames,
            bufferFrameRange: (UInt32(range.mMinimum), UInt32(range.mMaximum)))
    }

    public static func listInput() -> [AudioDeviceInfo] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        let def = defaultInputDevice()
        return ids.compactMap { info($0, defaultId: def) }
    }

    /// `spec`: nil/"default" → default input; numeric → index in `listInput()`; else UID or name substring.
    public static func resolve(_ spec: String?) throws -> AudioDeviceInfo {
        let devices = listInput()
        guard !devices.isEmpty else { throw AudioCaptureError("no CoreAudio input devices") }
        guard let spec = spec, !spec.isEmpty, spec != "default" else {
            if let def = devices.first(where: { $0.isDefaultInput }) { return def }
            return devices[0]
        }
        let trimmed = spec.hasPrefix(":") ? String(spec.dropFirst()) : spec
        if let idx = Int(trimmed), idx >= 0, idx < devices.count { return devices[idx] }
        if let byUID = devices.first(where: { $0.uid == spec }) { return byUID }
        if let byName = devices.first(where: { $0.name.localizedCaseInsensitiveContains(spec) }) { return byName }
        throw AudioCaptureError("no input device matches '\(spec)'")
    }
}

// MARK: - Capture

public final class MicCapture {
    public let device: AudioDeviceInfo
    public let ring: SPSCRingBuffer
    public let signal: semaphore_t
    public private(set) var sampleRate: Double = 0
    public private(set) var bufferFrames: UInt32 = 0
    public let callbacks = Atomic<Int>(0)
    public let framesCaptured = Atomic<Int>(0)
    /// Monotonic ns of the most recent IO callback (end of the newest captured chunk).
    public let lastCaptureNs = Atomic<UInt64>(0)
    public let renderErrors = Atomic<Int>(0)

    private var unit: AudioUnit? = nil
    private var bufferList: UnsafeMutableAudioBufferListPointer
    private var renderBuffer: UnsafeMutablePointer<Float>
    private let maxFrames = 4096
    private var originalBufferFrames: UInt32? = nil
    private var running = false

    public init(device: AudioDeviceInfo, requestedBufferFrames: UInt32 = 256, ringSeconds: Double = 2) {
        self.device = device
        ring = SPSCRingBuffer(capacity: Int(max(device.nominalSampleRate, 16000) * ringSeconds))
        var sem: semaphore_t = 0
        semaphore_create(mach_task_self_, &sem, SYNC_POLICY_FIFO, 0)
        signal = sem
        bufferList = AudioBufferList.allocate(maximumBuffers: 1)
        renderBuffer = .allocate(capacity: maxFrames)
        renderBuffer.initialize(repeating: 0, count: maxFrames)
        bufferFrames = requestedBufferFrames
    }

    deinit {
        stop()
        free(bufferList.unsafeMutablePointer)
        renderBuffer.deallocate()
        semaphore_destroy(mach_task_self_, signal)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw AudioCaptureError("\(what) failed: OSStatus \(status)") }
    }

    public func start() throws {
        if running { return }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw AudioCaptureError("AUHAL component not found") }
        var newUnit: AudioUnit? = nil
        try check(AudioComponentInstanceNew(component, &newUnit), "AudioComponentInstanceNew")
        guard let au = newUnit else { throw AudioCaptureError("AudioComponentInstanceNew returned nil") }
        unit = au

        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)), "enable input")
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)), "disable output")
        var deviceId = device.id
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceId, UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")

        // Smallest stable IO buffer: clamp the request into the device's supported range.
        // The nominal sample rate is never changed (system-wide side effect).
        let range = device.bufferFrameRange
        var frames = bufferFrames
        if range.max > 0 { frames = min(max(frames, range.min), range.max) }
        var current: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = propertyAddress(kAudioDevicePropertyBufferFrameSize, scope: kAudioDevicePropertyScopeInput)
        if AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &current) == noErr {
            originalBufferFrames = current
            if current != frames {
                var want = frames
                if AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &want) != noErr {
                    frames = current
                }
            }
        }
        bufferFrames = frames
        var maxSlice: UInt32 = UInt32(maxFrames)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxSlice, UInt32(MemoryLayout<UInt32>.size)), "max frames per slice")

        // Device format on the input scope of bus 1 tells us the hardware rate.
        var hwFormat = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hwFormat, &fmtSize), "get hw format")
        sampleRate = hwFormat.mSampleRate > 0 ? hwFormat.mSampleRate : device.nominalSampleRate

        // Client format: Float32 mono at the hardware rate (AUHAL cannot resample; we do it later).
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set client format")
        if hwFormat.mChannelsPerFrame > 1 {
            var map: [Int32] = [0]
            _ = AudioUnitSetProperty(au, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &map, UInt32(MemoryLayout<Int32>.size))
        }

        var callback = AURenderCallbackStruct(inputProc: micInputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
        try check(AudioUnitInitialize(au), "AudioUnitInitialize")
        try check(AudioOutputUnitStart(au), "AudioOutputUnitStart")
        running = true
    }

    public func stop() {
        guard let au = unit else { return }
        if running {
            AudioOutputUnitStop(au)
            running = false
        }
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        unit = nil
        if let original = originalBufferFrames, original != bufferFrames {
            var restore = original
            var address = propertyAddress(kAudioDevicePropertyBufferFrameSize, scope: kAudioDevicePropertyScopeInput)
            _ = AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &restore)
        }
        semaphore_signal(signal)
    }

    /// Realtime path (called from the IO thread through `micInputCallback`).
    @inline(__always)
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timestamp: UnsafePointer<AudioTimeStamp>,
                            _ bus: UInt32, _ frames: UInt32) {
        guard let au = unit else { return }
        let n = Int(min(frames, UInt32(maxFrames)))
        bufferList[0].mNumberChannels = 1
        bufferList[0].mDataByteSize = UInt32(n * 4)
        bufferList[0].mData = UnsafeMutableRawPointer(renderBuffer)
        let status = AudioUnitRender(au, flags, timestamp, bus, UInt32(n), bufferList.unsafeMutablePointer)
        if status != noErr {
            renderErrors.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let got = Int(bufferList[0].mDataByteSize) / 4
        ring.write(renderBuffer, count: got)
        framesCaptured.wrappingAdd(got, ordering: .relaxed)
        callbacks.wrappingAdd(1, ordering: .relaxed)
        lastCaptureNs.store(monotonicNanos(), ordering: .releasing)
        semaphore_signal(signal)
    }
}

private let micInputCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    let capture = Unmanaged<MicCapture>.fromOpaque(refCon).takeUnretainedValue()
    capture.render(flags, timestamp, bus, frames)
    return noErr
}
