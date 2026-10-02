import SwiftUI

/// 设置 › 主题: two scene previews side by side, each a picture with its name under it. The
/// picture is the one place in Settings that keeps an edge (0.6 pt hairline at radius 10):
/// the stellar preview's ground is the modal's own black, so without it the picture would
/// have no bounds. No card, fill or accent stroke around the pair; the chosen theme is marked
/// by a stamped point of light before its name, which is then written in `ink` (the other in
/// `ink2`), and a quiet "使用中" — no colour anywhere (it was the page's one sky-blue word).
///
/// The edge is drawn the same way on both pictures (round 12): the stellar picture's is the
/// light hairline, and on the pale wilds picture — where that hairline vanished, so the two
/// cards read as one outlined and one not — the same line is laid in the wilds ink
/// (`paleEdge`), so both pictures end on a line of equal weight.
struct ExplorationThemeSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.interfaceScale) private var interfaceScale
    @State private var creditsShown = false

    var body: some View {
        @Bindable var settings = model.settings
        SettingsPage(title: "主题", note: "选择应用外观，字幕配色保持独立。") {
            HStack(alignment: .top, spacing: 14) {
                ForEach(ExperienceTheme.allCases) { item in
                    let selected = model.settings.experienceTheme == item
                    Button { model.settings.experienceTheme = item } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            ThemeScenePreview(item: item).frame(height: 144)
                                .clipShape(RoundedRectangle(cornerRadius: LLMetrics.Radius.card, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: LLMetrics.Radius.card, style: .continuous)
                                        .strokeBorder(edge(for: item, selected: selected),
                                                      lineWidth: contrast == .increased && selected ? 1 : 0.6)
                                }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    ZStack { if selected { SettingsStarPoint(dark: theme.isDark) } }.frame(width: 8, height: 8)
                                    Text(item.shortTitle).font(LLFont.heading).foregroundStyle(selected ? theme.ink : theme.ink2)
                                    Spacer()
                                    Text(selected ? "使用中" : "选择").font(LLFont.label)
                                        .foregroundStyle(selected ? theme.ink2 : theme.ink3)
                                }
                                Text(item == .stellar ? "深色 · 流动星空" : "浅色 · 柔和纸色")
                                    .font(LLFont.label).foregroundStyle(theme.ink3)
                                    .padding(.leading, 14)
                            }.padding(.top, 10)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDimStyle(dim: 0.88))
                    .accessibilityLabel("使用\(item.title)主题")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            // The same word choice as every other one-of-many (a stamped star under the chosen
            // word); it was a hand-made row with a filled chip under 自动.
            SettingsGroup("显示") {
                SettingRow("界面大小", note: interfaceSizeTitle) {
                    TextSegment(options: InterfaceSize.allCases.map { ($0, $0 == .automatic ? "自动" : $0.title) },
                                selection: $settings.interfaceSize, label: "界面大小")
                }
                SheetDivider()
                SettingRow("背景场景", note: "空闲时在首页显示场景插画。") {
                    Toggle("背景场景", isOn: $settings.showBackgroundScene)
                        .labelsHidden().toggleStyle(QuietSwitchStyle())
                }
            }

            // The app's one disclosure row (语音输入 uses it too), not the system triangle.
            DictationFold(title: "素材来源", summary: "Solar System Scope · Kenney", expanded: $creditsShown) {
                VStack(alignment: .leading, spacing: 10) {
                    Link("行星材质 · Solar System Scope", destination: URL(string: "https://www.solarsystemscope.com/textures/")!)
                    Link("自然与建筑 · Kenney", destination: URL(string: "https://kenney.nl/assets")!)
                }
                .font(LLFont.label).tint(theme.ink2)
            }
        }
    }

    /// The pale picture's edge: the wilds ink in both app themes, because the picture is always
    /// pale, at the strength the black picture's hairline has on it (#D8DFEB @ 17 % × 70 %).
    private static let paleEdge = LLTheme.wilds.ink.opacity(0.17 * 0.7)

    /// Both pictures end on the same line: the light hairline shows on the black picture, and
    /// `paleEdge` does the same work on the pale one.
    private func edge(for item: ExperienceTheme, selected: Bool) -> Color {
        if contrast == .increased && selected { return theme.ink2 }
        return item == .stellar ? theme.hairline.opacity(0.7) : Self.paleEdge
    }

    private var interfaceSizeTitle: String {
        let size = model.settings.interfaceSize
        let percent = Int((interfaceScale * 100).rounded())
        if size == .automatic { return "自动适配 · \(percent)%" }
        if abs((size.factor ?? 1) - interfaceScale) > 0.01 { return "\(size.title) · 当前 \(percent)%" }
        return size.title
    }
}

/// A frozen miniature of each world: the 95-star canvas and the stardust core are drawn once
/// (the live core is on Home, visible through the blur behind the modal).
private struct ThemeScenePreview: View {
    let item: ExperienceTheme

    var body: some View {
        LuminousMotion(active: false, frozenTime: 2) { time in
            GeometryReader { geometry in
                ZStack {
                    if item == .stellar {
                        Color(hex: 0x030405)
                        Canvas { context, size in
                            for index in 0..<95 {
                                let x = LexiconConstellation.fraction("theme-star-\(index)") * size.width
                                let y = LexiconConstellation.fraction("theme-star-y-\(index)") * size.height
                                let radius = index % 9 == 0 ? 0.65 : 0.36
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                                             with: .color(Color(hex: 0xC9E0ED).opacity(0.24 + sin(time * 0.8 + Double(index)) * 0.12)))
                            }
                        }
                        StardustOrganism(time: time, miniature: true).environment(\.theme, LLTheme.stellar)
                            .frame(width: 112, height: 112).offset(y: -5)
                    } else {
                        Color(hex: 0xF4F0DF)
                        Canvas { context, size in
                            let w = size.width, h = size.height
                            var far = Path()
                            far.move(to: CGPoint(x: 0, y: h * 0.68))
                            far.addCurve(to: CGPoint(x: w, y: h * 0.67), control1: CGPoint(x: w * 0.36, y: h * 0.12), control2: CGPoint(x: w * 0.55, y: h * 0.72))
                            far.addLine(to: CGPoint(x: w, y: h)); far.addLine(to: CGPoint(x: 0, y: h)); far.closeSubpath()
                            context.fill(far, with: .color(Color(hex: 0xBAC8AE).opacity(0.70)))
                            var near = Path()
                            near.move(to: CGPoint(x: 0, y: h * 0.81))
                            near.addCurve(to: CGPoint(x: w, y: h * 0.63), control1: CGPoint(x: w * 0.29, y: h * 1.13), control2: CGPoint(x: w * 0.65, y: h * 0.39))
                            near.addLine(to: CGPoint(x: w, y: h)); near.addLine(to: CGPoint(x: 0, y: h)); near.closeSubpath()
                            context.fill(near, with: .color(Color(hex: 0x738E77).opacity(0.66)))
                            context.fill(Path(ellipseIn: CGRect(x: w * 0.71, y: h * 0.22, width: 20, height: 20)), with: .color(Color(hex: 0xE2C788).opacity(0.75)))
                        }
                    }
                    VStack {
                        Spacer()
                        Capsule().fill(item == .stellar ? Color.white.opacity(0.20) : Color(hex: 0x365846).opacity(0.28))
                            .frame(width: 64, height: 4)
                    }.padding(.bottom, 15)
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
