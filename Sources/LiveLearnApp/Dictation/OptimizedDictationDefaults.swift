import Foundation

struct OptimizedDictationDefaults: Decodable, Sendable {
    let url: String
    let appID: String
    let deviceID: String
    let appKey: String
    let tokenRequired: Bool
    enum CodingKeys: String, CodingKey {
        case url, appID = "app_id", deviceID = "device_id", appKey = "app_key", tokenRequired = "token_required"
    }
    static let bundled: Self? = {
        // Service credentials and device identifiers are supplied by the user, never shipped.
        nil
    }()
}
