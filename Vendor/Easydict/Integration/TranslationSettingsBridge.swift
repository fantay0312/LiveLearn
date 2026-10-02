import AppKit
import SwiftUI
import Defaults

enum TranslationSettingsResources {
    static let bundle = Bundle(for: LiveLearnTranslationSettingsController.self)
    static let preferencesDomain = bundle.bundleIdentifier!
    static let preferences = UserDefaults(suiteName: preferencesDomain)!
}

extension Defaults.Key {
    convenience init(translationKey name: String, default value: Value) {
        self.init(name, default: value, suite: TranslationSettingsResources.preferences)
    }

    convenience init<T>(translationKey name: String) where Value == T? {
        self.init(name, suite: TranslationSettingsResources.preferences)
    }
}

func LLSettingsLocalizedString(_ key: String, comment: String) -> String {
    I18nHelper.shared.localizedBundle.localizedString(forKey: key, value: nil, table: nil)
}

func LLSettingsText(_ key: LocalizedStringKey) -> Text {
    Text(key, bundle: TranslationSettingsResources.bundle)
}

@_disfavoredOverload
func LLSettingsText<S: StringProtocol>(_ value: S) -> Text { Text(value) }
func LLSettingsText(verbatim value: String) -> Text { Text(verbatim: value) }
@_disfavoredOverload
func LLSettingsText(_ value: AttributedString) -> Text { Text(value) }
@_disfavoredOverload
func LLSettingsText(_ resource: LocalizedStringResource) -> Text {
    Text(LocalizedStringResource(resource.defaultValue, table: resource.table, locale: resource.locale,
                                 bundle: .atURL(TranslationSettingsResources.bundle.bundleURL)))
}

func LLSettingsString(localized value: String.LocalizationValue, comment: StaticString? = nil) -> String {
    String(localized: value, bundle: TranslationSettingsResources.bundle,
           locale: Locale(identifier: I18nHelper.shared.localizeCode), comment: comment)
}

func LLSettingsString(localized resource: LocalizedStringResource) -> String {
    String(localized: resource.defaultValue, table: resource.table,
           bundle: TranslationSettingsResources.bundle, locale: Locale(identifier: I18nHelper.shared.localizeCode))
}

/// The original settings views run inside a host-owned view controller, never a second window.
@objc(LiveLearnTranslationSettingsController)
final class LiveLearnTranslationSettingsController: NSViewController {
    private let state = TranslationSettingsViewState()
    private let languageState = LanguageState()
    private var observations: [NSObjectProtocol] = []
    private var lastPreferences: NSDictionary = [:]
    private var changedWork: DispatchWorkItem?
    @objc var eventHandler: ((NSDictionary) -> Void)?
    static weak var active: LiveLearnTranslationSettingsController?

    override func loadView() {
        Self.active = self
        let content = TranslationSettingsContent(state: state)
            .environmentObject(languageState)
            .defaultAppStorage(TranslationSettingsResources.preferences)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        view = hosting
        lastPreferences = preferencesSnapshot()
        observations.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: TranslationSettingsResources.preferences, queue: .main
        ) { [weak self] _ in self?.preferencesChanged() })
        observations.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPreferences() })
    }

    @objc func selectSection(_ number: NSNumber) {
        guard let section = SettingTab(rawValue: number.intValue) else { return }
        state.section = section
    }

    @objc func setInterfaceScale(_ number: NSNumber) {
        let value = CGFloat(number.doubleValue)
        if value.isFinite, value > 0, state.interfaceScale != value { state.interfaceScale = value }
    }

    @objc func setDeveloperMode(_ number: NSNumber) {
        guard state.developerMode != number.boolValue else { return }
        state.developerMode = number.boolValue
        if !state.developerMode, state.section == .advanced { state.section = .general }
    }

    @objc func refreshPreferences() {
        TranslationSettingsResources.preferences.synchronize()
        let snapshot = preferencesSnapshot()
        guard snapshot != lastPreferences else { return }
        let keys = Set(lastPreferences.allKeys.compactMap { $0 as? String })
            .union(snapshot.allKeys.compactMap { $0 as? String })
            .filter { (lastPreferences[$0] as? NSObject) != (snapshot[$0] as? NSObject) }
        lastPreferences = snapshot
        for key in keys {
            TranslationSettingsResources.preferences.willChangeValue(forKey: key)
            TranslationSettingsResources.preferences.didChangeValue(forKey: key)
        }
        if keys.contains(where: { $0 == "kServiceInfoStorageKey" || $0.hasPrefix("kAllServiceTypesKey-") }) {
            NotificationCenter.default.postServiceUpdateNotification()
        }
        updateLocale()
    }

    func preferencesChanged() {
        changedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.preferencesSnapshot()
            guard snapshot != self.lastPreferences else { return }
            self.lastPreferences = snapshot
            self.updateLocale()
            TranslationSettingsResources.preferences.synchronize()
            self.eventHandler?(["action": "settings.reload"])
        }
        changedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func preferencesSnapshot() -> NSDictionary {
        (TranslationSettingsResources.preferences.persistentDomain(forName: TranslationSettingsResources.preferencesDomain) ?? [:]) as NSDictionary
    }

    private func updateLocale() {
        let code = I18nHelper.shared.localizeCode
        if state.localeCode != code { state.localeCode = code }
    }

    deinit {
        changedWork?.cancel()
        observations.forEach(NotificationCenter.default.removeObserver)
    }
}

private final class TranslationSettingsViewState: ObservableObject {
    @Published var developerMode = false
    @Published var interfaceScale: CGFloat = 1
    @Published var section = SettingTab.general
    @Published var localeCode = I18nHelper.shared.localizeCode
}

private struct TranslationSettingsContent: View {
    @ObservedObject var state: TranslationSettingsViewState
    @Environment(\.colorScheme) private var colorScheme

    /// The page sits in the host's page column, so its own width is the pane's: the title and
    /// everything under it take the host's centred gutter (`contentGutter`) from here.
    var body: some View {
        GeometryReader { pane in
            let gutter = LiveLearnSettingsPage.contentGutter(pane: pane.size.width)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("文字翻译").font(.system(size: 24, weight: .regular))
                    Text("设置查询语言、翻译服务与取词方式。")
                        .font(.system(size: 13)).foregroundStyle(RailInk.of(dark: colorScheme == .dark).ink2)
                }
                .padding(.leading, gutter).padding(.top, 52)
                SettingView(selection: $state.section, developerMode: state.developerMode)
                    .id(state.localeCode)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.settingsContentGutter, gutter)
        }
        .foregroundStyle(RailInk.of(dark: colorScheme == .dark).ink)
        .environment(\.settingsInteractionEnabled, true)
        .environment(\.locale, .init(identifier: state.localeCode))
        .environment(\.translationInterfaceScale, state.interfaceScale)
    }
}

enum MenuBarIconType: String, CaseIterable, Defaults.Serializable, Identifiable {
    case square = "square_menu_bar_icon"
    case rounded = "rounded_menu_bar_icon"
    var id: Self { self }
}

extension Bool {
    var toggledValue: Bool {
        get { !self }
        mutating set { self = !newValue }
    }
}
