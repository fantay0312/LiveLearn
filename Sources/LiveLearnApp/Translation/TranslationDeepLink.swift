import Foundation

enum TranslationDeepLink {
    /// Only accept a text-query URL. No helper command, file path or configuration action
    /// can be selected through the public URL scheme.
    static func text(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "livelearn",
              ["query", "translate"].contains(url.host?.lowercased() ?? ""),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems?.filter { $0.name == "text" } ?? []
        guard items.count == 1, let text = items.first?.value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 262_144 else { return nil }
        return text
    }
}
