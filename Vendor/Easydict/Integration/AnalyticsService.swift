// LiveLearn adaptation of Easydict's AnalyticsService, GPL-3.0.
// Original copyright (c) 2025 izual. Translation does not enable upstream telemetry.
import Foundation
@objc(EZAnalyticsService)
@objcMembers
final class AnalyticsService: NSObject {
    @objc(setupCrashLogService) static func setupCrashService() {}
    static func setCrashEnabled(_ enabled: Bool) {}
    @objc(logEventWithName:parameters:)
    static func logEvent(withName name: String, parameters: [String: Any]?) {}
    @objc(logWindowAppear:) static func logWindowAppear(_ windowType: EZWindowType) {}
    @objc(logQueryService:) static func logQueryService(_ service: QueryService) {}
    static func logAppInfo() {}
    static func textLengthRange(_ text: String) -> String {
        switch text.utf16.count {
        case ...10: "1-10"
        case ...50: "10-50"
        case ...200: "50-200"
        case ...1000: "200-1000"
        case ...5000: "1000-5000"
        default: "5000-∞"
        }
    }
}
