import AppKit
import Testing
@testable import LiveLearnApp

@MainActor
struct TranslationSettingsComponentTests {
    private final class Controller: NSViewController {
        var selections: [Int] = []
        @objc func selectSection(_ number: NSNumber) { selections.append(number.intValue) }
    }

    @Test func returningToThePageDoesNotReplayAnOldMenuSelection() {
        let component = TranslationSettingsComponent()
        let controller = Controller()
        let request = UUID()
        component.select(6, requestID: request, in: controller)
        component.select(6, requestID: request, in: controller)
        #expect(controller.selections == [6])
        component.select(6, requestID: UUID(), in: controller)
        #expect(controller.selections == [6, 6])
        component.select(nil, requestID: UUID(), in: controller)
        #expect(controller.selections == [6, 6])
    }
}
