import SwiftUI
import MacAudio
import AudioDomain

/// "Which sound on this computer": one paper menu shared by session setup and Settings. Every
/// running application is a tick; several can be ticked (the sheet stays open) and their audio
/// is mixed into one channel. "全部应用（系统声）" is the default and the way back from a ticked set.
///
/// The title is the fact the sentence needs: "全部应用", one name, "A、B", "A 等 3 个应用", or
/// "选择应用" in the accent while the channel is narrowed but nothing is ticked yet.
struct ComputerSourceMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var font: Font = LLFont.body
    /// Color of the title when it states a choice; the pending state is always the accent.
    var color: Color? = nil
    var draft: Binding<SessionSourceSelection>? = nil

    var body: some View {
        if let draft {
            draftMenu(draft)
        } else {
        let pending = model.useApplication && model.selectedApplications.isEmpty
        let title = model.useSystem ? "全部应用" : model.selectedApplicationsLabel
        PaperMenu(title: title, font: font, color: pending ? theme.accent : (color ?? theme.ink2), help: "采集电脑里的哪些声音") { [model] in
            var items: [PaperMenuItem] = [
                .check("全部应用（系统声）", id: "all", on: model.useSystem) { if !model.useSystem { model.selectAllApplications() } },
                .divider(),
            ]
            items += model.applications.map { app in
                .check(app.name, id: app.bundleIdentifier, detail: app.isPlayingAudio ? "正在发声" : nil, on: model.isSelected(app)) { model.toggle(application: app) }
            }
            // Ticked apps that have quit are not in the running list; they stay visible so they
            // can be unticked.
            items += model.selectedApplications.filter { s in !model.applications.contains { $0.bundleIdentifier == s.bundleIdentifier } }.map { app in
                .check(app.name, id: app.bundleIdentifier, detail: "未运行", on: model.isSelected(app)) { model.toggle(application: app) }
            }
            items.append(.divider("refresh"))
            items.append(.row("刷新列表", keepsOpen: true) { model.refreshDevices() })
            return items
        }
        }
    }

    private func draftMenu(_ draft: Binding<SessionSourceSelection>) -> some View {
        let selected = draft.wrappedValue
        let title = selected.computer == .system ? "全部应用" : (selected.applications.isEmpty ? "选择应用" : AudioSourceDescriptor.applicationsLabel(selected.applications.map(\.name)))
        return PaperMenu(title: title, font: font, color: selected.computer == .applications && selected.applications.isEmpty ? theme.accent : (color ?? theme.ink2), help: "采集电脑里的哪些声音") {
            var items: [PaperMenuItem] = [
                .check("全部应用（系统声）", id: "all", on: draft.wrappedValue.computer == .system) { draft.wrappedValue.computer = .system },
                .divider()
            ]
            let current = model.applications
            let missing = draft.wrappedValue.applications.filter { selected in !current.contains { $0.bundleIdentifier == selected.bundleIdentifier } }
            items += (current + missing).map { app in
                .check(app.name, id: app.bundleIdentifier,
                       detail: current.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) ? (app.isPlayingAudio ? "正在发声" : nil) : "未运行",
                       on: draft.wrappedValue.computer == .applications && draft.wrappedValue.applications.contains { $0.bundleIdentifier == app.bundleIdentifier }) {
                    draft.wrappedValue.toggleApplication(app)
                }
            }
            items.append(.divider("refresh"))
            items.append(.row("刷新列表", keepsOpen: true) { model.refreshSourceInventory() })
            return items
        }
    }
}

/// Which microphone: the devices by name, the system default noted; the sidebar adds 刷新列表.
struct MicrophoneMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var font: Font = LLFont.body
    var color: Color? = nil
    var refresh = false
    var draft: Binding<AudioInputDevice?>? = nil

    var body: some View {
        if let draft {
            draftMenu(draft)
        } else {
        PaperMenu(title: model.selectedMicrophone?.name ?? "默认麦克风", font: font, color: color ?? theme.ink2, help: "用哪个麦克风") { [model, refresh] in
            var items: [PaperMenuItem] = [.row("默认麦克风", id: "default", selected: model.selectedMicrophone == nil) { model.select(microphone: nil) }]
            items += model.microphones.map { mic in
                PaperMenuItem.row(mic.name, id: mic.uid, detail: mic.isDefault ? "系统默认" : nil, selected: model.selectedMicrophone?.uid == mic.uid) { model.select(microphone: mic) }
            }
            if refresh {
                items.append(.divider())
                items.append(.row("刷新列表", keepsOpen: true) { model.refreshDevices() })
            }
            return items
        }
        }
    }

    private func draftMenu(_ draft: Binding<AudioInputDevice?>) -> some View {
        PaperMenu(title: draft.wrappedValue?.name ?? "默认麦克风", font: font, color: color ?? theme.ink2, help: "用哪个麦克风") {
            var microphones = model.microphones
            if let selected = draft.wrappedValue, !microphones.contains(where: { $0.uid == selected.uid }) { microphones.append(selected) }
            var items: [PaperMenuItem] = [.row("默认麦克风", id: "default", selected: draft.wrappedValue == nil) { draft.wrappedValue = nil }]
            items += microphones.map { mic in
                .row(mic.name, id: mic.uid, detail: mic.isDefault ? "系统默认" : nil, selected: draft.wrappedValue?.uid == mic.uid) { draft.wrappedValue = mic }
            }
            if refresh {
                items.append(.divider())
                items.append(.row("刷新列表", keepsOpen: true) { model.refreshSourceInventory() })
            }
            return items
        }
    }
}
