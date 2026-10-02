import SwiftUI
import AppKit

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRender) private var staticRender
    @State private var step = 0
    @State private var selected: Set<OptionalModule> = []
    @State private var sound = OnboardingSound()
    @AccessibilityFocusState private var headingFocused: Bool
    var previewStep: Int? = nil
    private var current: Int { previewStep ?? step }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Text("LiveLearn").font(.system(size: 16, weight: .medium, design: .serif)).tracking(1)
                    Spacer()
                    Button {
                        model.settings.onboardingSound.toggle()
                        if model.settings.onboardingSound { sound.play() } else { sound.stop() }
                    } label: {
                        Label(model.settings.onboardingSound ? "声音已开" : "声音已关",
                              systemImage: model.settings.onboardingSound ? "speaker.wave.1" : "speaker.slash")
                            .font(LLFont.label)
                    }
                    .buttonStyle(TextButtonStyle())
                    .accessibilityLabel("引导声音")
                    .accessibilityValue(model.settings.onboardingSound ? "开启" : "关闭")
                    Button("稍后再设置") { finish(installSelected: false) }.buttonStyle(TextButtonStyle())
                        .padding(.leading, 24)
                }
                .foregroundStyle(theme.ink2)
                .padding(.top, 38)

                HStack(spacing: geometry.size.width > 1_050 ? 64 : 32) {
                    OnboardingConstellation(step: current)
                        .frame(width: min(430, geometry.size.width * 0.42))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 24) {
                        Text(["你好，很高兴遇见你。", "少一点，刚刚好。", "现在，听见更大的世界。"][current])
                            .font(LLFont.label).tracking(2).foregroundStyle(theme.ink3)
                        Text(["让每一句话，\n都离你近一点。", "你的 LiveLearn，\n由你来选择。", "准备好，\n从一句话开始。"][current])
                            .font(.system(size: 34, weight: .regular, design: .serif))
                            .lineSpacing(8).foregroundStyle(theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($headingFocused)
                        content
                    }
                    .frame(maxWidth: 430, alignment: .leading)
                    .id(current)
                    .transition(LLMotion.pageTransition(reduceMotion))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                FadingRule(ends: .both)
                HStack(alignment: .center) {
                    HStack(spacing: 20) {
                        ForEach(0..<3) { index in
                            HStack(spacing: 7) {
                                Circle().fill(index == current ? theme.accent : theme.ink3.opacity(0.35)).frame(width: 4, height: 4)
                                Text(["相遇", "选择", "出发"][index]).font(LLFont.label)
                                    .foregroundStyle(index == current ? theme.ink : theme.ink3)
                            }.accessibilityLabel("第 \(index + 1) 步，\(["相遇", "选择", "出发"][index])")
                                .accessibilityAddTraits(index == current ? .isSelected : [])
                        }
                    }
                    Spacer()
                    if current > 0 {
                        Button("上一步") { advance(-1) }.buttonStyle(TextButtonStyle())
                            .padding(.trailing, 20)
                    }
                    Button(current == 2 ? (selected.isEmpty ? "进入 LiveLearn" : "安装所选，开始使用") : current == 0 ? "认识一下" : "就这样，继续") {
                        if current == 2 { finish(installSelected: true) } else { advance(1) }
                    }
                    .buttonStyle(CompactCapsuleButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }.padding(.vertical, 28)
            }
            .padding(.horizontal, geometry.size.width > 1_050 ? 64 : 40)
        }
        .frame(minWidth: LLMetrics.minWindow.width, minHeight: LLMetrics.minWindow.height)
        .background(theme.ground)
        .onDisappear { sound.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in sound.stop() }
    }

    @ViewBuilder private var content: some View {
        switch current {
        case 0:
            Text("一堂课、一段访谈，或一次跨越语言的对话。\n让字幕轻轻跟上，把注意力留给内容。")
                .font(.system(size: 15)).lineSpacing(8).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "captions.bubble")
                Text("实时翻译，已经随应用带来。")
            }.font(LLFont.body).foregroundStyle(theme.accent).padding(.top, 8)
        case 1:
            Text("只用实时翻译也很好。下面这些，想用时再加。")
                .font(LLFont.body).foregroundStyle(theme.ink2)
            VStack(spacing: 0) {
                ForEach(OptionalModule.allCases) { module in
                    Button {
                        if selected.contains(module) { selected.remove(module) } else { selected.insert(module) }
                    } label: {
                        HStack(spacing: 15) {
                            Image(systemName: module.symbol).font(.system(size: 19, weight: .light)).frame(width: 26)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(module.title).font(.system(size: 15))
                                Text(module.detail).font(LLFont.label).foregroundStyle(theme.ink3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: selected.contains(module) ? "checkmark" : "plus")
                                .font(.system(size: 12)).frame(width: 22, height: 28)
                        }
                        .foregroundStyle(selected.contains(module) ? theme.accent : theme.ink2)
                        .padding(.vertical, 14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(module.title)
                    .accessibilityValue(selected.contains(module) ? "已勾选" : "未勾选")
                    .accessibilityHint("可选模块；勾选后在完成引导时下载")
                    if module != .browserExtension { FadingRule() }
                }
            }
            Text("所有扩展默认不选 · 以后可在设置中安装与卸载")
                .font(LLFont.label).foregroundStyle(theme.ink3)
        default:
            VStack(alignment: .leading, spacing: 18) {
                instruction("01", "选择想听的声音", "电脑声音、一个应用，或你的麦克风。")
                instruction("02", "选好语言与引擎", "本机模型需先下载；云端服务使用你自己的账户。")
                instruction("03", "按下开始，让字幕跟上", "需要权限时，macOS 才会询问你。")
            }
            Text(selected.isEmpty ? "轻装出发。没有额外模块需要下载。" : "所选模块将在后台安装，进度可在功能管理中查看。")
                .font(LLFont.label).foregroundStyle(theme.accent).padding(.top, 8)
        }
    }

    private func instruction(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.accent).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 15)).foregroundStyle(theme.ink)
                Text(detail).font(LLFont.body).foregroundStyle(theme.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func advance(_ amount: Int) {
        withAnimation(LLMotion.enter(reduceMotion, 0.32)) { step = min(2, max(0, step + amount)) }
        headingFocused = true
        if model.settings.onboardingSound && !staticRender { sound.play() }
    }

    private func finish(installSelected: Bool) {
        sound.stop()
        if installSelected { for module in selected { model.settings.modules.install(module) } }
        model.settings.onboardingCompleted = true
        if installSelected && !selected.isEmpty {
            model.settings.requestedSettingsTab = .modules
            UnifiedSettingsPresentation.shared.open()
        }
    }
}

private struct OnboardingConstellation: View {
    let step: Int
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LuminousMotion(active: true, rate: 24) { time in
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2 - 20)
                    for index in 0..<360 {
                        let seed = Double(index)
                        let angle = seed * 2.39996 + time * 0.035
                        let radius = 52 + sqrt(seed / 360) * 124
                        let flutter = sin(seed * 1.71 + time * 0.3) * 6
                        let point = CGPoint(x: center.x + cos(angle) * (radius + flutter),
                                            y: center.y + sin(angle) * (radius * 0.73 + flutter))
                        let alpha = 0.13 + (sin(seed * 3.17 + time * 0.4) + 1) * 0.22
                        let diameter = index % 23 == 0 ? 2.1 : 0.85
                        context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: diameter, height: diameter)),
                                     with: .color(theme.accent.opacity(alpha)))
                    }
                }
                VStack(spacing: 14) {
                    Image(systemName: step == 1 ? "sparkle" : "waveform")
                        .font(.system(size: 24, weight: .ultraLight)).foregroundStyle(theme.accent)
                    Text(step == 1 ? "留一点空间，\n给真正重要的事。" : step == 2 ? "世界很大。\n一句一句，慢慢来。" : "There is a world\nwaiting to be heard.")
                        .font(.system(size: 23, weight: .regular, design: .serif))
                        .lineSpacing(6).multilineTextAlignment(.center).foregroundStyle(theme.ink)
                    if step == 0 {
                        Text("有一个世界，等你听见。")
                            .font(LLFont.body).foregroundStyle(theme.ink2)
                    }
                }.offset(y: -20)
                VStack {
                    Spacer()
                    Text(step == 0 ? "字幕示意 · 尚未采集声音" : "轻一点，也能走得很远。")
                        .font(LLFont.label).foregroundStyle(theme.ink3).padding(.bottom, 42)
                }
            }
        }
        .frame(height: 420)
    }
}
