// Adapted from Easydict BuiltInAIService (c) 2024 izual, GPL-3.0.
// LiveLearn retains the AI translation/tools while using user-configured services.
import Foundation
@objc(EZBuiltInAIService)
class BuiltInAIService: BaseOpenAIService {
    public override func name() -> String { "AI 翻译" }
    public override func serviceType() -> ServiceType { .builtInAI }
    public override func apiKeyRequirement() -> ServiceAPIKeyRequirement { .userProvided }
    public override func configurationListItems() -> Any {
        StreamConfigurationView(service: self, showAPIKeySection: true, showEndpointSection: true)
    }
    override var canFetchRemoteModels: Bool { true }
}
