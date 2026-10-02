import SwiftUI
import CaptionDomain

/// "英语 → 中文" as one fact: one sheet with two columns, the source languages at the left and
/// the targets at the right, so one control changes both ends and the pair stays in view while
/// choosing. Common languages sit at the top of each column; the rest follow under "更多语言".
/// A source pick keeps the sheet open for the target; picking the current target as the source
/// swaps the two, so the direction is never the same language twice.
struct DirectionMenu: View {
    @Binding var source: String
    @Binding var target: String
    var font: Font = LLFont.body
    var color: Color? = nil
    /// Offer "自动" as the source: only recognizers that detect languages accept it, and the
    /// start gate says so when the chosen one does not.
    var allowAuto = true
    @Environment(\.theme) private var theme

    var body: some View {
        PaperMenu(title: StatusCopy.direction(source, target), font: font, color: color ?? theme.ink2, help: "源语言与目标语言") {
            [PaperMenuColumn(title: "源语言", items: sourceItems), PaperMenuColumn(title: "目标语言", items: targetItems)]
        }
    }

    private var sourceItems: [PaperMenuItem] {
        var items: [PaperMenuItem] = []
        if allowAuto {
            items.append(.row("自动识别", id: LanguageCatalog.auto, selected: source == LanguageCatalog.auto, keepsOpen: true) { pick(source: LanguageCatalog.auto) })
            items.append(.divider())
        }
        items += LanguageCatalog.common.map { lang in
            .row(lang.name, id: lang.code, selected: source == lang.code, keepsOpen: true) { pick(source: lang.code) }
        }
        items.append(.section("更多语言"))
        items += LanguageCatalog.more.map { lang in
            .row(lang.name, id: lang.code, selected: source == lang.code, keepsOpen: true) { pick(source: lang.code) }
        }
        return items
    }

    private var targetItems: [PaperMenuItem] {
        var items = LanguageCatalog.common.filter { $0.code != source }.map { lang in
            PaperMenuItem.row(lang.name, id: lang.code, selected: target == lang.code) { target = lang.code }
        }
        items.append(.section("更多语言"))
        items += LanguageCatalog.more.filter { $0.code != source }.map { lang in
            PaperMenuItem.row(lang.name, id: lang.code, selected: target == lang.code) { target = lang.code }
        }
        return items
    }

    private func pick(source code: String) {
        if code == target {
            let old = source
            target = old == LanguageCatalog.auto ? (LanguageCatalog.common.first { $0.code != code }?.code ?? target) : old
        }
        source = code
    }
}

/// One language: common ones first, the rest under "更多语言" in the same column.
struct LanguageMenu: View {
    @Binding var selection: String
    var font: Font = LLFont.body
    var color: Color? = nil
    var allowAuto = false
    /// What the choice is for ("收听的源语言"): the control's accessibility name.
    var help: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        PaperMenu(title: LanguageCatalog.name(selection), font: font, color: color ?? theme.ink, help: help) {
            var items: [PaperMenuItem] = []
            if allowAuto {
                items.append(.row("自动识别", id: LanguageCatalog.auto, selected: selection == LanguageCatalog.auto) { selection = LanguageCatalog.auto })
                items.append(.divider())
            }
            items += LanguageCatalog.common.map { lang in
                .row(lang.name, id: lang.code, selected: selection == lang.code) { selection = lang.code }
            }
            items.append(.section("更多语言"))
            items += LanguageCatalog.more.map { lang in
                .row(lang.name, id: lang.code, selected: selection == lang.code) { selection = lang.code }
            }
            return items
        }
    }
}
