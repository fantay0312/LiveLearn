import Foundation
import Security
import SessionDomain

/// Minimal Keychain wrapper. Secrets never enter UserDefaults, logs or diagnostics.
enum KeychainStore {
    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain 错误 \(status)" }
    }

    static func save(service: String, account: String, secret: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Writes a content-free diagnostics JSON next to the user's Downloads folder.
enum DiagnosticsExporter {
    static func export(_ snapshot: SessionSnapshot) -> String {
        var lanes: [[String: Any]] = []
        for l in snapshot.lanes {
            lanes.append([
                "lane": l.id,
                "sourceKind": l.configuration.source.kind.rawValue,
                "captureState": l.capture.state.rawValue,
                "captureEpoch": l.capture.captureEpoch,
                "format": l.capture.format?.summary ?? "",
                "callbacks": l.capture.callbackCount,
                "queuedMs": l.capture.queuedNs / 1_000_000,
                "droppedMs": l.capture.droppedNs / 1_000_000,
                "providerLink": l.providerLink.rawValue,
                "providerEpoch": l.providerEpoch,
                "reconnectAttempts": l.reconnectAttempts,
                "lastError": l.lastError ?? "",
            ])
        }
        let payload: [String: Any] = [
            "app": "LiveLearn",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "sessionState": snapshot.state.rawValue,
            "elapsedMs": snapshot.elapsedNs / 1_000_000,
            "segmentCount": snapshot.captions.segments.count,
            "gapCount": snapshot.captions.items.filter { if case .gap = $0 { return true } else { return false } }.count,
            "lanes": lanes,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let url = dir.appendingPathComponent("LiveLearn-diagnostics-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url)
            return "已写入 \(url.path)"
        } catch {
            return "导出失败：\(error)"
        }
    }
}
