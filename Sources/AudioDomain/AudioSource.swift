import Foundation

public enum AudioSourceKind: String, Sendable, Codable, CaseIterable {
    case microphone
    case application
    case system

    /// Label used everywhere a lane needs a text tag. Never dropped in favor of color.
    public var label: String {
        switch self {
        case .microphone: return "麦克风"
        case .application: return "应用"
        case .system: return "系统声"
        }
    }
}

/// What the user chose to listen to. Stores stable identity, never a list index or a PID.
///
/// An application source may name several applications at once (their audio processes are
/// mixed into one tap). `bundleIdentifier` is the first of them, kept for older archives and
/// single-app callers; `allBundleIdentifiers` is the whole set.
public struct AudioSourceDescriptor: Sendable, Hashable, Codable, Identifiable {
    public var kind: AudioSourceKind
    /// Core Audio device UID for microphones.
    public var deviceUID: String?
    /// Bundle identifier for applications (the first one when several are chosen).
    public var bundleIdentifier: String?
    /// Application path, kept so the same app can be re-identified after relaunch.
    public var applicationPath: String?
    public var displayName: String
    /// Every application in this source, in the order the user chose them. Nil (absent in
    /// archives written before multi-app capture) means just `bundleIdentifier`.
    public var bundleIdentifiers: [String]?

    public init(kind: AudioSourceKind, deviceUID: String? = nil, bundleIdentifier: String? = nil, applicationPath: String? = nil, displayName: String, bundleIdentifiers: [String]? = nil) {
        self.kind = kind
        self.deviceUID = deviceUID
        self.bundleIdentifier = bundleIdentifier ?? bundleIdentifiers?.first
        self.applicationPath = applicationPath
        self.displayName = displayName
        // One id is the plain single-app shape; only a real set is stored as a list.
        if let list = bundleIdentifiers, list.count > 1 {
            self.bundleIdentifiers = list
        } else {
            self.bundleIdentifiers = nil
        }
    }

    /// All applications of an application source; empty for other kinds.
    public var allBundleIdentifiers: [String] {
        guard kind == .application else { return [] }
        if let list = bundleIdentifiers, !list.isEmpty { return list }
        return bundleIdentifier.map { [$0] } ?? []
    }

    public var id: String {
        switch kind {
        case .microphone: return "mic:\(deviceUID ?? "default")"
        case .application:
            let ids = allBundleIdentifiers
            return "app:\(ids.isEmpty ? displayName : ids.sorted().joined(separator: "+"))"
        case .system: return "system"
        }
    }

    /// "Safari", "Safari、Zoom", "Safari 等 3 个应用": one phrase for a set of app names.
    public static func applicationsLabel(_ names: [String]) -> String {
        switch names.count {
        case 0: return "选择应用"
        case 1: return names[0]
        case 2: return "\(names[0])、\(names[1])"
        default: return "\(names[0]) 等 \(names.count) 个应用"
        }
    }

    /// "应用 · Safari", "麦克风 · MacBook Pro麦克风", "系统声".
    public var tag: String {
        switch kind {
        case .system: return kind.label
        default: return "\(kind.label) · \(displayName)"
        }
    }

    public static let defaultMicrophone = AudioSourceDescriptor(kind: .microphone, deviceUID: nil, displayName: "默认麦克风")
    public static let system = AudioSourceDescriptor(kind: .system, displayName: "系统声")
}
