import SwiftUI
import MacAudio

/// The same source form as before a session, with local draft bindings and explicit apply.
///
/// Every value the draft changes against the running session carries a star point in the
/// gutter (round 12) and is written in `ink` among `ink2` values, so the popover shows what 应用
/// will restart with instead of leaving the reader to diff from memory. The restart note and the
/// one commit share the last row: the note (and any error) on the left, the compact stellar
/// capsule on the rag.
struct ActiveSessionSourceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State var selection: SessionSourceSelection
    @State private var applying = false
    @State private var error: String?
    @State private var lastComputer: SessionSourceSelection.Computer = .system
    /// Any difference from the running session enables 应用 — including an application list
    /// kept behind 全部应用, which `DraftChanges` leaves unmarked because the capture would not
    /// change. So the capsule can light with no star in the form; narrowing this is a behaviour
    /// change, not part of the visual round.
    private var canApply: Bool { selection.validationError == nil && selection != SessionSourceSelection(model: model) && !applying }

    var body: some View {
        let changes = DraftChanges(draft: selection, live: SessionSourceSelection(model: model))
        SourceConfigurationPopover(title: "音源与语言", cancelTitle: "取消", onClose: { dismiss() }) {
            VStack(spacing: LLMetrics.space(5)) {
                SourceChannel(title: "电脑里的声音", enabled: computerOn, changed: changes.computerChannel) {
                    SourceField(label: "音源", changed: changes.computerSource) {
                        ComputerSourceMenu(font: LLFont.value, color: valueInk(changes.computerSource), draft: $selection)
                    }
                    SourceField(label: "翻译方向", changed: changes.listenDirection) {
                        DirectionMenu(source: $selection.languages.listenSource, target: $selection.languages.listenTarget,
                                      font: LLFont.value, color: valueInk(changes.listenDirection))
                    }
                }
                SourceConfigurationDivider()
                SourceChannel(title: "我说的话", enabled: $selection.microphoneEnabled, changed: changes.microphoneChannel) {
                    SourceField(label: "麦克风", changed: changes.microphone) {
                        MicrophoneMenu(font: LLFont.value, color: valueInk(changes.microphone), refresh: true, draft: $selection.microphone)
                    }
                    SourceField(label: "翻译方向", changed: changes.micDirection) {
                        DirectionMenu(source: $selection.languages.micSource, target: $selection.languages.micTarget,
                                      font: LLFont.value, color: valueInk(changes.micDirection))
                    }
                }
            }
            SourceConfigurationDivider()
            HStack(alignment: .center, spacing: LLMetrics.space(4)) {
                VStack(alignment: .leading, spacing: 6) {
                    // Broken at the comma: beside the capsule the sentence takes two lines, and
                    // a free wrap left a three-character widow.
                    Text("应用后会保留当前记录，\n并按新音源与语言重新开始翻译。")
                        .font(LLFont.label).lineSpacing(2).foregroundStyle(theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = error ?? selection.validationError {
                        Text(message).font(LLFont.label).lineSpacing(2).foregroundStyle(theme.brick)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 250, alignment: .leading)
                Spacer(minLength: 0)
                Button {
                    applying = true
                    error = nil
                    Task { @MainActor in
                        error = await model.applySessionSources(selection)
                        applying = false
                        if error == nil { dismiss() }
                    }
                } label: {
                    Text(applying ? "正在切换…" : "应用并重新开始")
                }
                .buttonStyle(CompactCapsuleButtonStyle())
                .disabled(!canApply)
            }
        }
        .disabled(applying)
        .interactiveDismissDisabled(applying)
        .onChange(of: selection) { _, _ in error = nil }
        .onAppear {
            lastComputer = selection.computer == .off
                ? (model.settings.listenToApplications ? .applications : .system)
                : selection.computer
        }
    }

    /// A value the draft changed is written in `ink` beside its star; an unchanged one rests in
    /// `ink2` and lifts under the pointer. Exactly `ink2`, never a mix: `PaperMenu` lifts a label
    /// only when its colour is one of the quiet inks.
    private func valueInk(_ changed: Bool) -> Color { changed ? theme.ink : theme.ink2 }

    private var computerOn: Binding<Bool> {
        Binding(get: { selection.computer != .off }, set: { enabled in
            if enabled {
                selection.computer = lastComputer
            } else {
                if selection.computer != .off { lastComputer = selection.computer }
                selection.computer = .off
            }
        })
    }
}

/// Which parts of the draft differ from the running session. Only what the capture would
/// actually do counts: the application list matters only while the channel listens to chosen
/// applications (a list kept behind 全部应用 changes nothing), and a device by its uid.
struct DraftChanges: Equatable {
    var computerChannel = false
    var computerSource = false
    var listenDirection = false
    var microphoneChannel = false
    var microphone = false
    var micDirection = false

    init(draft: SessionSourceSelection, live: SessionSourceSelection) {
        computerChannel = (draft.computer == .off) != (live.computer == .off)
        computerSource = draft.computer != live.computer
            || (draft.computer == .applications
                && Set(draft.applications.map(\.bundleIdentifier)) != Set(live.applications.map(\.bundleIdentifier)))
        listenDirection = draft.languages.listenSource != live.languages.listenSource
            || draft.languages.listenTarget != live.languages.listenTarget
        microphoneChannel = draft.microphoneEnabled != live.microphoneEnabled
        microphone = draft.microphone?.uid != live.microphone?.uid
        micDirection = draft.languages.micSource != live.languages.micSource
            || draft.languages.micTarget != live.languages.micTarget
    }
}
