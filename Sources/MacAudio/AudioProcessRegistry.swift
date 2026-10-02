import Foundation
import CoreAudio
import AppKit
import Darwin

/// One Core Audio process object. `objectID` is a Core Audio identity, `pid` is a kernel one;
/// neither is a long-term identity for the user's choice (that is the bundle identifier).
public struct AudioProcessInfo: Sendable, Hashable, Identifiable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningOutput: Bool
    public let isRunningInput: Bool
    public var id: AudioObjectID { objectID }
}

public enum AudioProcessRegistry {
    public static func allProcesses() -> [AudioProcessInfo] {
        guard let ids = try? CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, as: AudioObjectID.self) else { return [] }
        return ids.compactMap { info(for: $0) }
    }

    public static func info(for objectID: AudioObjectID) -> AudioProcessInfo? {
        guard let pid = try? CoreAudioProperty.value(objectID, kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
        let bundle = try? CoreAudioProperty.string(objectID, kAudioProcessPropertyBundleID)
        let out = ((try? CoreAudioProperty.value(objectID, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
        let inp = ((try? CoreAudioProperty.value(objectID, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) ?? 0) != 0
        return AudioProcessInfo(objectID: objectID, pid: pid, bundleID: bundle.flatMap { $0.isEmpty ? nil : $0 }, isRunningOutput: out, isRunningInput: inp)
    }

    public static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        guard let id = try? CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTranslatePIDToProcessObject, qualifier: pid, initial: AudioObjectID(0)) else { return nil }
        return id == 0 ? nil : id
    }

    public static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard got == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}

// MARK: - Application identity

public struct RunningApplicationSummary: Sendable, Identifiable, Hashable {
    public let bundleIdentifier: String
    public let name: String
    public let path: String?
    public let pid: pid_t
    /// Any process in this app's audio membership currently outputs audio.
    public let isPlayingAudio: Bool
    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String, path: String?, pid: pid_t, isPlayingAudio: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        self.pid = pid
        self.isPlayingAudio = isPlayingAudio
    }
}

/// Resolution of "the app the user picked" into current Core Audio process objects.
public struct ApplicationAudioMembership: Sendable, Equatable {
    public var bundleIdentifier: String
    public var rootPIDs: [pid_t]
    public var memberObjectIDs: [AudioObjectID]
    public var memberPIDs: [pid_t]
    public var isRunning: Bool
    public var anyOutputRunning: Bool
}

/// Tracks which processes legitimately belong to the chosen application (doc §6.3).
/// Never walks up to the desktop shell, never widens to the whole system.
public enum ApplicationAudioIdentityResolver {
    public static let maxAncestorDepth = 6

    @MainActor
    public static func candidateApplications() -> [RunningApplicationSummary] {
        let processes = allProcessesByPID()
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let bid = app.bundleIdentifier, app.processIdentifier != own else { return nil }
            let members = members(ofRoots: [app.processIdentifier], bundleID: bid, processes: processes)
            let playing = members.contains { $0.isRunningOutput }
            return RunningApplicationSummary(bundleIdentifier: bid, name: app.localizedName ?? bid, path: app.bundleURL?.path, pid: app.processIdentifier, isPlayingAudio: playing)
        }.sorted { ($0.isPlayingAudio ? 0 : 1, $0.name) < ($1.isPlayingAudio ? 0 : 1, $1.name) }
    }

    public static func resolve(bundleIdentifier: String) -> ApplicationAudioMembership {
        // "pid:1234" is a development-only identity for command-line audio tools without a bundle.
        let roots: [pid_t]
        if bundleIdentifier.hasPrefix("pid:"), let pid = pid_t(bundleIdentifier.dropFirst(4)) {
            roots = kill(pid, 0) == 0 ? [pid] : []
        } else {
            roots = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier)
        }
        let processes = allProcessesByPID()
        let members = members(ofRoots: roots, bundleID: bundleIdentifier, processes: processes)
        return ApplicationAudioMembership(
            bundleIdentifier: bundleIdentifier,
            rootPIDs: roots,
            memberObjectIDs: members.map(\.objectID).sorted(),
            memberPIDs: members.map(\.pid).sorted(),
            isRunning: !roots.isEmpty,
            anyOutputRunning: members.contains { $0.isRunningOutput }
        )
    }

    /// Several applications as one membership: the union of their audio processes, running when
    /// any of them runs. Feeds one process tap that mixes all of them.
    public static func resolve(bundleIdentifiers: [String]) -> ApplicationAudioMembership {
        if bundleIdentifiers.count == 1 { return resolve(bundleIdentifier: bundleIdentifiers[0]) }
        var roots: [pid_t] = []
        var objects = Set<AudioObjectID>()
        var pids = Set<pid_t>()
        var running = false
        var output = false
        for bid in bundleIdentifiers {
            let m = resolve(bundleIdentifier: bid)
            roots.append(contentsOf: m.rootPIDs)
            objects.formUnion(m.memberObjectIDs)
            pids.formUnion(m.memberPIDs)
            running = running || m.isRunning
            output = output || m.anyOutputRunning
        }
        return ApplicationAudioMembership(
            bundleIdentifier: bundleIdentifiers.joined(separator: "+"),
            rootPIDs: roots,
            memberObjectIDs: objects.sorted(),
            memberPIDs: pids.sorted(),
            isRunning: running,
            anyOutputRunning: output
        )
    }

    private static func allProcessesByPID() -> [pid_t: AudioProcessInfo] {
        var out: [pid_t: AudioProcessInfo] = [:]
        for p in AudioProcessRegistry.allProcesses() { out[p.pid] = p }
        return out
    }

    /// A Core Audio process belongs to the app if its pid is a root, a descendant of a root
    /// within `maxAncestorDepth`, or its bundle id is a helper of the root bundle id.
    private static func members(ofRoots roots: [pid_t], bundleID: String, processes: [pid_t: AudioProcessInfo]) -> [AudioProcessInfo] {
        guard !roots.isEmpty else { return [] }
        let rootSet = Set(roots)
        var out: [AudioProcessInfo] = []
        for (pid, info) in processes {
            if rootSet.contains(pid) {
                out.append(info)
                continue
            }
            if let b = info.bundleID, b.hasPrefix(bundleID + "."), isDescendant(pid, of: rootSet) {
                out.append(info)
                continue
            }
            if isDescendant(pid, of: rootSet) {
                out.append(info)
            }
        }
        return out
    }

    private static func isDescendant(_ pid: pid_t, of roots: Set<pid_t>) -> Bool {
        var current = pid
        for _ in 0..<maxAncestorDepth {
            guard let parent = AudioProcessRegistry.parentPID(of: current), parent > 1 else { return false }
            if roots.contains(parent) { return true }
            current = parent
        }
        return false
    }
}
