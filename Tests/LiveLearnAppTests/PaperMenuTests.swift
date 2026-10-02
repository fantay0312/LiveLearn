import Testing
@testable import LiveLearnApp

@MainActor
struct PaperMenuTests {
    @Test func refreshedItemsKeepTheSameHighlightedValue() {
        var items: [PaperMenuItem] = [.row("A", id: "a") {}, .row("B", id: "b", selected: true) {}]
        var activated: String?
        let session = PaperMenuSession(columns: { [.init(items: items)] }, activate: { activated = $0.id })
        session.highlightChosen()
        items.insert(.row("New", id: "new") {}, at: 0)
        #expect(session.highlightID == "b")
        session.activateHighlighted()
        #expect(activated == "b")
        items.removeAll { $0.id == "b" }
        activated = nil
        session.activateHighlighted()
        #expect(activated == nil && session.highlightID == nil)
    }

    @Test func keyboardSkipsDisabledRowsAndSections() {
        let session = PaperMenuSession(columns: { [.init(items: [
            .section("标题"), .row("禁用", id: "disabled", enabled: false) {},
            .row("第一项", id: "first") {}, .divider(), .row("第二项", id: "second") {}
        ])] }, activate: { _ in })
        session.highlightChosen()
        #expect(session.highlightID == "first")
        session.move(by: 1)
        #expect(session.highlightID == "second")
        session.move(by: 1)
        #expect(session.highlightID == "second")
        session.move(by: -1)
        #expect(session.highlightID == "first")
    }

    @Test func movingToAnEmptyColumnCannotActivateThePreviousColumn() {
        var activated = false
        let session = PaperMenuSession(columns: { [.init(items: [.row("A") {}]), .init(items: [.section("暂无选项")])] }, activate: { _ in activated = true })
        session.highlightChosen(); session.moveColumn(by: 1); session.activateHighlighted()
        #expect(!activated && session.highlight == nil)
    }
}
