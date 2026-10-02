import Foundation
import CoreAudio
import AudioToolbox

public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let context: String
    public init(_ status: OSStatus, _ context: String) {
        self.status = status
        self.context = context
    }
    public var description: String {
        "\(context) (OSStatus \(status) \(fourCC(status)))"
    }
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
    return "\(status)"
}

/// Thin typed wrappers over AudioObjectGetPropertyData. Never called from an IO callback.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope: scope)
        return AudioObjectHasProperty(objectID, &addr)
    }

    static func value<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, initial: T) throws -> T {
        var addr = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        var out = initial
        let status = withUnsafeMutablePointer(to: &out) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw CoreAudioError(status, "get \(fourCC(OSStatus(bitPattern: selector))) on \(objectID)") }
        return out
    }

    static func value<T, Q>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, qualifier: Q, initial: T) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var out = initial
        var q = qualifier
        let status = withUnsafeMutablePointer(to: &out) { ptr in
            withUnsafePointer(to: &q) { qptr in
                AudioObjectGetPropertyData(objectID, &addr, UInt32(MemoryLayout<Q>.size), qptr, &size, ptr)
            }
        }
        guard status == noErr else { throw CoreAudioError(status, "get \(fourCC(OSStatus(bitPattern: selector))) with qualifier on \(objectID)") }
        return out
    }

    static func array<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as: T.Type) throws -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status, "size \(fourCC(OSStatus(bitPattern: selector))) on \(objectID)") }
        let count = Int(size) / MemoryLayout<T>.stride
        if count == 0 { return [] }
        var out = [T](unsafeUninitializedCapacity: count) { buf, initialized in
            initialized = count
            status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buf.baseAddress!)
        }
        guard status == noErr else { throw CoreAudioError(status, "get \(fourCC(OSStatus(bitPattern: selector))) on \(objectID)") }
        out.removeLast(max(0, count - Int(size) / MemoryLayout<T>.stride))
        return out
    }

    static func string(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var out: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &out) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw CoreAudioError(status, "get string \(fourCC(OSStatus(bitPattern: selector))) on \(objectID)") }
        guard let cf = out?.takeRetainedValue() else { return "" }
        return cf as String
    }

    static func streamCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.stride
    }
}

// MARK: - Devices

public struct AudioInputDevice: Sendable, Identifiable, Hashable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let isDefault: Bool
    public let sampleRate: Double
}

public enum AudioDeviceList {
    public static func inputDevices() -> [AudioInputDevice] {
        guard let ids = try? CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, as: AudioObjectID.self) else { return [] }
        let defaultID = (try? CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0))) ?? 0
        return ids.compactMap { id in
            guard CoreAudioProperty.streamCount(id, scope: kAudioObjectPropertyScopeInput) > 0 else { return nil }
            let uid = (try? CoreAudioProperty.string(id, kAudioDevicePropertyDeviceUID)) ?? ""
            let name = (try? CoreAudioProperty.string(id, kAudioObjectPropertyName)) ?? "未知设备"
            let rate = (try? CoreAudioProperty.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))) ?? 0
            // Skip our own private aggregate devices and other taps.
            if name.hasPrefix("LiveLearn") { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name, isDefault: id == defaultID, sampleRate: rate)
        }
    }

    public static func inputDevice(uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    static func defaultSystemOutputUID() throws -> String {
        let id = try CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioObjectID(0))
        return try CoreAudioProperty.string(id, kAudioDevicePropertyDeviceUID)
    }
}
