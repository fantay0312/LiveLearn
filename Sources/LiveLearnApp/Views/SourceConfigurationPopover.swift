import SwiftUI

/// The shell of the source and language popovers (idle, active, language-only): a title in
/// `LLFont.title`, the close action on the right rag, and the form on the near-black ground.
///
/// Round 12: the dark ground carries a few still stars in the empty band beside the title —
/// placed, not scattered — instead of a live 85-star canvas that put grey specks beside the
/// text and ran a clock on top of Home. The popover's own chrome (the NSPopover arrow and rim)
/// is given the same ground through `presentationBackground`, so no system material shows
/// around the painted body. The ✕ is a bare glyph and 取消 a bare word, both flush on the rag
/// the switches and the apply capsule end on.
struct SourceConfigurationPopover<Content: View>: View {
    let title: String
    /// The form's width, fixed: a popover that hugged its values would grow around its arrow
    /// when a pick in a paper menu that stays open (a source language) lengthened the label,
    /// and slide the label out from under the open sheet.
    var width: CGFloat = 480
    var cancelTitle: String? = nil
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: LLMetrics.space(5)) {
            HStack(alignment: .center) {
                Text(title).font(LLFont.title).foregroundStyle(theme.ink)
                Spacer(minLength: LLMetrics.space(4))
                close
                    .accessibilityLabel(cancelTitle ?? "关闭\(title)")
                    .help(cancelTitle ?? "关闭 · Esc")
                    .keyboardShortcut(.cancelAction)
            }
            content()
        }
        .padding(LLMetrics.space(5))
        .frame(width: width, alignment: .leading)
        .background {
            theme.ground
            if theme.isDark { PopoverSky() }
        }
        .presentationBackground(theme.ground)
    }

    @ViewBuilder
    private var close: some View {
        if let cancelTitle {
            Button(cancelTitle, action: onClose).buttonStyle(TextButtonStyle(flush: true))
        } else {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12))
            }
            .buttonStyle(GlyphButtonStyle(flush: .trailing))
        }
    }
}

/// Points of light in the band between the title and the close action — the only empty sky
/// in the popover — drawn with the settings sky's recipe (pearl #ECEFF4 / ice #B7D3F6; 1.9 /
/// 1.15 / 0.7 pt), bare points with no glint: a cross-lit star on the title's line read as a
/// sparkle stamped on the title. Five in the 480 pt source popover (42–77 % of the width), three
/// in a narrower one (44–70 %), 12–52 pt from the top: at least 16 pt clear of the title's
/// words and of the ✕'s hit area (`Round12FoundationTests` measures both shells). A plain
/// `Canvas` with no clock.
struct PopoverSky: View {
    typealias Star = (x: CGFloat, y: CGFloat, diameter: CGFloat, alpha: Double, ice: Bool)

    /// The stars of a popover `width` wide, in points.
    static func stars(width: CGFloat) -> [Star] {
        // x as a share of the width, y in points from the top.
        let layout: [Star] = width < 360
            ? [(0.44, 18, 1.15, 0.28, false), (0.57, 44, 0.7, 0.20, true), (0.70, 24, 1.9, 0.50, false)]
            : [(0.42, 16, 0.7, 0.20, false), (0.51, 44, 1.15, 0.30, true), (0.60, 22, 1.9, 0.52, false),
               (0.69, 52, 0.7, 0.18, false), (0.77, 12, 1.15, 0.28, false)]
        return layout.map { ($0.x * width, $0.y, $0.diameter, $0.alpha, $0.ice) }
    }

    var body: some View {
        Canvas { context, size in
            for star in Self.stars(width: size.width) {
                let d = star.diameter
                let tint = star.ice ? Color(hex: 0xB7D3F6) : Color(hex: 0xECEFF4)
                context.fill(Path(ellipseIn: CGRect(x: star.x - d / 2, y: star.y - d / 2, width: d, height: d)),
                             with: .color(tint.opacity(star.alpha)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The rule between the popover's sections: from the text column, fading at its far end.
struct SourceConfigurationDivider: View {
    var body: some View { FadingRule() }
}

/// One audio channel of the source form (电脑里的声音 / 我说的话), shared by the idle and the
/// active popover; callers decide whether the bindings are live or a draft.
///
/// The name is bare text (round 12: the channel icons read as an icon list, and the filled
/// monitor was the heaviest mass in the popover): 15/500, `ink` while the channel is on and
/// `ink3` while it is off, with the switch on the right rag. Its fields sit 16 pt under it on
/// the same text column, two to a row. `changed` hangs a star point in the gutter left of the
/// name when a draft turns the channel on against the running session. A channel the draft
/// turns off gets none — the star means "chosen", and the brightest marks in the popover would
/// point at what was switched off; its switch shows that change.
struct SourceChannel<Fields: View>: View {
    let title: String
    @Binding var enabled: Bool
    var changed = false
    @ViewBuilder var fields: () -> Fields
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: LLMetrics.space(4)) {
            HStack(spacing: LLMetrics.space(3)) {
                Text(title).font(LLFont.heading)
                    .foregroundStyle(enabled ? theme.ink : theme.ink3)
                    .draftMark(changed && enabled)
                Spacer()
                Toggle(title, isOn: $enabled).toggleStyle(QuietSwitchStyle()).labelsHidden()
            }
            if enabled {
                HStack(alignment: .top, spacing: LLMetrics.space(5), content: fields)
            }
        }
    }
}

/// A field of a channel: an 11 pt `ink3` label over its value (a paper menu, written by the
/// caller in `LLFont.value`). Values rest in `ink2`, as configuration does everywhere (Home's
/// line reads the same values in the same ink), and lift to `ink` under the pointer and while
/// their sheet is open; the channel name above them keeps `ink`. `changed` hangs a star point
/// left of the value when the draft differs from what the session is running, and the caller
/// writes that value in `ink` — the star is never the only sign — so the popover shows what 应用
/// will change.
struct SourceField<Content: View>: View {
    let label: String
    var changed = false
    @ViewBuilder var content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(LLFont.label).foregroundStyle(theme.ink3)
            content().lineLimit(1).truncationMode(.middle)
                .frame(minHeight: 24, alignment: .leading)
                .draftMark(changed)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    /// The draft's star point, hung in the gutter with its centre 10 pt left of the text (its
    /// 8 pt slot spans −14…−6): near enough to belong to the value, 14 pt clear of the popover's
    /// rim, and marking a value never moves it.
    func draftMark(_ changed: Bool) -> some View {
        overlay(alignment: .leading) {
            if changed { StarMark().offset(x: -14) }
        }
    }
}

struct SessionSourcePopover: View {
    let onClose: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var showingCaptureInfo = false

    var body: some View {
        SourceConfigurationPopover(title: "音源与语言", onClose: onClose) {
            channels
            SourceConfigurationDivider()
            utilityRow
        }
    }

    /// The two channels on live bindings — the same `SourceChannel` / `SourceField` form as the
    /// active editor's draft, so the popover does not change shape when a session starts.
    private var channels: some View {
        @Bindable var model = model
        @Bindable var settings = model.settings
        return VStack(spacing: LLMetrics.space(5)) {
            SourceChannel(title: "电脑里的声音", enabled: computerOn) {
                SourceField(label: "音源") { ComputerSourceMenu(font: LLFont.value) }
                SourceField(label: "翻译方向") {
                    DirectionMenu(source: $settings.listenSourceLanguage, target: $settings.listenTargetLanguage, font: LLFont.value)
                }
            }
            SourceConfigurationDivider()
            SourceChannel(title: "我说的话", enabled: $model.useMicrophone) {
                SourceField(label: "麦克风") { MicrophoneMenu(font: LLFont.value, refresh: true) }
                SourceField(label: "翻译方向") {
                    DirectionMenu(source: $settings.micSourceLanguage, target: $settings.micTargetLanguage, font: LLFont.value)
                }
            }
        }
    }

    /// The computer channel is on while either capture is: turning it on resumes the chosen
    /// applications when there are any, else the whole system's sound.
    private var computerOn: Binding<Bool> {
        Binding(get: { model.useApplication || model.useSystem }, set: { enabled in
            if enabled {
                if model.settings.listenToApplications && !model.selectedApplications.isEmpty {
                    model.useApplication = true
                } else { model.useSystem = true }
            } else {
                model.useApplication = false
                model.useSystem = false
            }
        })
    }

    /// The engine as a label over a value link, then 检查音源 and ⓘ on the value's baseline,
    /// 12 pt apart, the ⓘ flush on the rag.
    private var utilityRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: LLMetrics.space(3)) {
            VStack(alignment: .leading, spacing: 0) {
                Text("处理引擎").font(LLFont.label).foregroundStyle(theme.ink3)
                Button {
                    onClose()
                    model.settings.requestedSettingsTab = .engine
                    UnifiedSettingsPresentation.shared.open()
                } label: {
                    HStack(spacing: 5) {
                        Text(model.blueprint.summary).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                    }
                }
                .buttonStyle(TextButtonStyle(flush: true))
                .accessibilityLabel("翻译引擎：\(model.blueprint.summary)")
                .help(model.readinessSummary)
            }
            Spacer(minLength: 0)
            Button(model.isCheckingSource ? "检查中…" : "检查音源") { model.runSourceCheck() }
                .buttonStyle(TextButtonStyle(flush: true))
                .disabled(!model.hasSource || model.isCheckingSource)
                .help("通过真实采集路径检查 3 秒，不识别、不保存")
                .fixedSize()
            Button { showingCaptureInfo.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 13))
            }
            .buttonStyle(GlyphButtonStyle(tint: theme.ink3, flush: .trailing))
            .accessibilityLabel("音频权限与数据去向")
            .popover(isPresented: $showingCaptureInfo) {
                VStack(alignment: .leading, spacing: LLMetrics.space(3)) {
                    Text("首次采集时，macOS 会询问录音权限。只处理你选定的来源；麦克风仅在启用后采集。")
                    Text(model.engineDescription)
                }
                .font(LLFont.body).lineSpacing(LLLeading.body).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(20).frame(width: 340).background(theme.ground)
                .presentationBackground(theme.ground)
            }
        }
    }
}

/// The language-only popover: one direction per lane, the same value style as the source
/// popover. 320 pt (the source popover's 480 left a single column of values 60 % empty) holds
/// every pair on one line except 葡萄牙语（葡萄牙） ↔ 葡萄牙语（巴西）, which truncates in the
/// middle.
struct SessionLanguagePopover: View {
    let onClose: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var settings = model.settings
        SourceConfigurationPopover(title: "翻译方向", width: 320, onClose: onClose) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(model.draftLanes) { lane in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lane.name).font(LLFont.label).foregroundStyle(theme.ink3)
                        if lane.id == "mic" {
                            DirectionMenu(source: $settings.micSourceLanguage, target: $settings.micTargetLanguage,
                                          font: LLFont.value)
                                .accessibilityLabel("麦克风语言方向")
                        } else {
                            DirectionMenu(source: $settings.listenSourceLanguage, target: $settings.listenTargetLanguage,
                                          font: LLFont.value)
                                .accessibilityLabel("电脑声音语言方向")
                        }
                    }
                }
            }
            .disabled(model.isActive)
        }
    }
}
