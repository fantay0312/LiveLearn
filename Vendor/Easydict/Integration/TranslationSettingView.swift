// LiveLearn navigation around Easydict's original settings pages, GPL-3.0.
import SwiftUI
import AppKit

enum SettingTab: Int {
    case general, service, disabled, advanced, shortcut, privacy, favorites, about
}

struct SettingView: View {
    @Binding var selection: SettingTab
    var developerMode = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsContentGutter) private var gutter

    private var tabs: [(SettingTab, LocalizedStringKey)] { [
        (.general, "setting_general"), (.service, "service"), (.favorites, "favorites.tab"),
        (.disabled, "disabled_app_list"), (.shortcut, "shortcut"), (.advanced, "advanced"),
        (.privacy, "privacy"), (.about, "setting.about")
    ].filter { developerMode || $0.0 != .advanced || selection == .advanced } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs, id: \.0) { tab, title in
                        Button {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            selection = tab
                        } label: {
                            // 13/400 like every other row of choosable words (the rail, the
                            // host's segments and pane strip); the choice is ink and the star.
                            Text(title).font(.system(size: 13))
                                .overlay(alignment: .bottom) {
                                    if selection == tab {
                                        SettingsStarPoint(dark: colorScheme == .dark, stamped: true)
                                    }
                                }
                                .padding(.horizontal, 10).frame(height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TranslationSettingsActionStyle(selected: selection == tab))
                        .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    }
                }
                // The words' 10 pt hit padding hangs outside the column, as the host's
                // segments do, so the first word starts on the title's edge.
                .padding(.leading, gutter - 10).padding(.trailing, 24)
            }
            .padding(.top, 22).padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("文字翻译分类")

            TranslationSettingsRule(dark: colorScheme == .dark)
                .frame(maxWidth: LiveLearnSettingsPage.contentMeasure)
                .padding(.leading, gutter)

            TabView(selection: $selection) {
                ForEach(tabs, id: \.0) { tab, _ in
                    page(tab).tag(tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            // Restore the content inset removed with NSTabView's border.
            .padding(.horizontal, 8)
            .background(TranslationSettingsTabChrome(selection: selection))
            .font(.system(size: 13))
            .tint(colorScheme == .dark ? TranslationSettingsPalette.silver : TranslationSettingsPalette.lightAccent)
            .toggleStyle(TranslationSettingsToggleStyle())
            .buttonStyle(TranslationSettingsActionStyle())
            .textFieldStyle(TranslationSettingsTextFieldStyle())
            .scrollContentBackground(.hidden)
        }
        .onChange(of: selection) { _ in
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    @ViewBuilder private func page(_ tab: SettingTab) -> some View {
        switch tab {
        case .general: GeneralTab()
        case .service: ServiceTab()
        case .favorites: FavoritesTab()
        case .disabled: DisabledAppTab()
        case .shortcut: ShortcutTab()
        case .advanced: AdvancedTab()
        case .privacy: PrivacyTab()
        case .about: AboutTab()
        }
    }
}

/// Keep TabView's selection and appearance lifecycle; the host draws the navigation chrome.
private struct TranslationSettingsTabChrome: NSViewRepresentable {
    let selection: SettingTab
    func makeNSView(context: Context) -> TabChromeView { TabChromeView() }
    func updateNSView(_ view: TabChromeView, context: Context) { view.scheduleUpdate() }

    final class TabChromeView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }

        func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in self?.updateChrome() }
        }

        private func updateChrome() {
            var ancestor = superview
            while let container = ancestor {
                if let tabs = findTabs(in: container) {
                    tabs.tabViewType = .noTabsNoBorder
                    tabs.drawsBackground = false
                    return
                }
                ancestor = container.superview
            }
        }

        private func findTabs(in view: NSView) -> NSTabView? {
            if let tabs = view as? NSTabView { return tabs }
            for child in view.subviews {
                if let tabs = findTabs(in: child) { return tabs }
            }
            return nil
        }
    }
}
