import AppKit
import SwiftUI

@MainActor
final class TranslationSettingsComponent {
    static let shared = TranslationSettingsComponent()
    private var loadedBundle: Bundle?
    private var cachedController: NSViewController?
    private var appliedSelectionRequest: UUID?

    func controller() throws -> NSViewController {
        if let cachedController {
            cachedController.perform(NSSelectorFromString("refreshPreferences"))
            return cachedController
        }
        guard let plugins = ModuleLibrary.shared.directory(.textTranslation)?.appendingPathComponent("PlugIns"),
              let bundle = Bundle(url: plugins.appendingPathComponent("LiveLearnTranslationSettings.bundle")) else {
            throw TranslationFeatureError.unavailable("文字翻译设置组件缺失，请在功能管理中重新安装。")
        }
        try bundle.loadAndReturnError()
        loadedBundle = bundle
        guard let type = bundle.principalClass as? NSViewController.Type else {
            throw TranslationFeatureError.unavailable("文字翻译设置组件版本不兼容。")
        }
        let controller = type.init(nibName: nil, bundle: bundle)
        let handler: @convention(block) (NSDictionary) -> Void = { event in
            MainActor.assumeIsolated {
                guard let action = event["action"] as? String,
                      ["settings.reload", "settings.recording", "query"].contains(action) else { return }
                TranslationFeature.shared.perform(action, text: event["text"] as? String)
            }
        }
        controller.setValue(handler, forKey: "eventHandler")
        cachedController = controller
        return controller
    }

    var requiresRestartToUnload: Bool { loadedBundle != nil }

    func select(_ section: Int?, requestID: UUID, in controller: NSViewController) {
        let selector = NSSelectorFromString("selectSection:")
        guard let section, appliedSelectionRequest != requestID, controller.responds(to: selector) else { return }
        controller.perform(selector, with: NSNumber(value: section))
        appliedSelectionRequest = requestID
    }
}

struct EmbeddedTranslationSettings: NSViewControllerRepresentable {
    let section: Int?
    let requestID: UUID
    let developerMode: Bool
    @Environment(\.theme) private var theme
    @Environment(\.interfaceScale) private var interfaceScale

    func makeNSViewController(context: Context) -> NSViewController {
        do {
            return try TranslationSettingsComponent.shared.controller()
        } catch {
            return NSHostingController(rootView: SettingsPage(title: "文字翻译") {
                // An error, so brick; the stellar one, because this page is hosted without the
                // app's environment and draws with the default (stellar) tokens throughout.
                SettingsNote(error.localizedDescription, color: LLTheme.stellar.brick)
            }.padding(24))
        }
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {
        controller.view.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let selector = NSSelectorFromString("setInterfaceScale:")
        if controller.responds(to: selector) { controller.perform(selector, with: NSNumber(value: Double(interfaceScale))) }
        let modeSelector = NSSelectorFromString("setDeveloperMode:")
        if controller.responds(to: modeSelector) { controller.perform(modeSelector, with: NSNumber(value: developerMode)) }
        TranslationSettingsComponent.shared.select(section, requestID: requestID, in: controller)
    }
}
